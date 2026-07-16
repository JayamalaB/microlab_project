'use strict';

const db             = require('../db/database');
const llmService     = require('../services/llmService');
const { resolveKnowledge } = require('../services/knowledgeService');

const PRONOUN_PATTERN = /\b(he|she|his|her|their|they|this (branch|test)|that (branch|test))\b/i;
const SESSION_TTL_MS  = 30 * 60 * 1000;

// Only these tables and their allowed columns are ever queried.
const TEST_COLS    = 'product_name, product_description, product_price, pre_instructions';
const BRANCH_COLS  = 'branch_name, branch_address, branch_city, branch_state, branch_pincode, branch_mobile, branch_email';
// ip_patients / ip_clients — always scoped to the authenticated patient's own client_id (see
// buildPatientProfileQuery / buildClientAccountQuery). Never selected without a patientId.
const PATIENT_COLS = [
    'patient_name', 'patient_surname', 'patient_gender', 'patient_dob', 'patient_age',
    'patient_blood_group', 'patient_relation', 'patient_email', 'patient_mobile',
    'patient_address', 'patient_city', 'health_conditions',
];
const CLIENT_COLS = ['client_name', 'client_mobile_no', 'subscription_tier', 'client_account_status'];

// Intents that expose personal data — require a verified patientId.
const PERSONAL_INTENTS = new Set(['sample_status_query', 'patient_profile_query', 'client_account_query', 'booking_query', 'technician_info_query']);
const RELATION_WORDS = 'mother|father|spouse|wife|husband|child|children|son|daughter|sister|brother';
// Generic nouns patients use instead of the word "profile" — "my information", "my
// data", "my details", "my record(s)". Requires "my" directly before the word so it
// doesn't hijack unrelated phrases like "my booking information".
const INFO_WORDS = 'info|information|data|details|records?';
const PATIENT_PROFILE_PATTERN = new RegExp(
    `\\b(family members?|my patients?|patients? (on|under|in) my account|my profile|patient profile|` +
    `my (${INFO_WORDS})|my (blood group|dob|date of birth)|my (${RELATION_WORDS})'?s?|` +
    `my family|family (${INFO_WORDS}))\\b`, 'i'
);
const CLIENT_ACCOUNT_PATTERN  = /\b(my subscription|subscription (tier|plan)|my (account status|membership)|is my account active|client account)\b/i;
// Narrower subset of PATIENT_PROFILE_PATTERN — questions that ask about someone OTHER
// than (or in addition to) the logged-in patient. Anything not matching this (e.g. plain
// "my profile", "my data", "my blood group") is scoped to the logged-in patient's own row.
const FAMILY_SCOPE_PATTERN = new RegExp(
    `\\b(family members?|patients? (on|under|in) my account|who(?:'s| is| are) (on|in|under) my account|` +
    `my (${RELATION_WORDS})'?s?|my family|family (${INFO_WORDS}))\\b`, 'i'
);
// Matches a message that is essentially ONLY a relation word ("sister", "mother?") or
// "family" — a natural short follow-up after the bot lists family members with their
// relation labels (e.g. "2. rajesh (Daughter)"). Anchored to the whole message so it
// can't hijack unrelated sentences that merely contain a relation word, e.g. "child
// health checkup".
const BARE_RELATION_PATTERN = new RegExp(`^\\s*(${RELATION_WORDS}|family)'?s?\\s*[?.!]?\\s*$`, 'i');
// "my sister" or bare "sister" — used to extract which relation was asked about.
const RELATION_PATTERN = new RegExp(`\\b(?:my\\s+)?(${RELATION_WORDS})'?s?\\b`, 'i');

// Booking questions — "my booking(s)", "booking details/info/status", "latest/recent
// booking(s)", "last/past/previous [N] bookings", "track my booking". Deliberately
// excludes bare "book" / "book a test" so it doesn't collide with the Book Test flow.
const COUNT_WORD = '\\d+|one|two|three|four|five|six|seven|eight|nine|ten|couple(?: of)?|few';
const BOOKING_QUERY_PATTERN = new RegExp(
    `\\b(my bookings?|bookings?\\s*(details|info(rmation)?|status|history)|` +
    `(latest|recent)\\s*bookings?|(last|past|previous)\\s*(${COUNT_WORD})?\\s*bookings?|` +
    `track my booking|booking ref(erence)?|(all|show|list)\\s*(my\\s*)?bookings)\\b`, 'i'
);
// Subset of BOOKING_QUERY_PATTERN meaning "show more than just the latest one" — either
// an explicit request for everything, or any "last/past/previous/recent bookings" phrasing
// (with or without an explicit count, which is separately extracted below).
const BOOKING_HISTORY_PATTERN = new RegExp(
    `\\b(booking history|all (my )?bookings|past bookings|previous bookings|list (my )?bookings|` +
    `show (all )?(my )?bookings|(latest|recent) bookings|(last|past|previous)\\s*(${COUNT_WORD})?\\s*bookings)\\b`, 'i'
);
// Extracts an explicit count from "last two bookings" / "past 3 bookings" / "last couple
// of bookings" etc., so we return exactly that many rather than defaulting to 20.
const BOOKING_LIMIT_PATTERN = new RegExp(`\\b(?:last|latest|past|previous|recent)\\s+(${COUNT_WORD})\\s+bookings?\\b`, 'i');
const BOOKING_NUMBER_WORDS = {
    one: 1, two: 2, three: 3, four: 4, five: 5,
    six: 6, seven: 7, eight: 8, nine: 9, ten: 10,
    couple: 2, few: 3,
};

// ip_technicians — the technician assigned to one of the patient's own bookings, joined
// via ip_bookings.technician_id. Never selected without a patientId, and always scoped to
// a booking that belongs to that patient (see answerTechnicianQuery).
const TECHNICIAN_COLS = [
    'technician_code', 'specialization', 'certifications', 'tech_age',
    'tech_city', 'is_available', 'technician_active',
];
// "technician info", "who is my technician", "which technician", "assigned technician".
const TECHNICIAN_QUERY_PATTERN = /\b(technician\s*(info(rmation)?|details|name|contact|status)|who(?:'s| is) my technician|which technician|assigned technician|my technician)\b/i;
// A booking reference ("BK1783658584549", "BK-2026-101") mentioned in the question — used
// to scope a technician (or booking) lookup to that specific booking instead of the latest.
const BOOKING_REF_PATTERN = /\bBK[-A-Z0-9]*\d+\b/i;
// A bare booking id mentioned as "booking 87" / "booking id 101" / "booking #101".
const BOOKING_ID_MENTION_PATTERN = /\bbooking\s*(?:id|#)?\s*[:#]?\s*(\d+)\b/i;

class LLMRetriever {
    constructor() {
        this.sessions = new Map();
        setInterval(() => this._pruneExpiredSessions(), 10 * 60 * 1000);
    }

    _getSession(sessionId) {
        if (!this.sessions.has(sessionId)) {
            this.sessions.set(sessionId, {
                lastProductName: null,
                lastBranchName:  null,
                lastCity:        null,
                lastIntent:      null,
                lastActive:      Date.now()
            });
            console.log(`🆕 New session: ${sessionId}`);
        }
        const s = this.sessions.get(sessionId);
        s.lastActive = Date.now();
        return s;
    }

    _updateSession(sessionId, intent, entities) {
        const s = this._getSession(sessionId);
        s.lastIntent = intent;
        if (entities.product_name) s.lastProductName = entities.product_name;
        if (entities.branch_name)  s.lastBranchName  = entities.branch_name;
        if (entities.city)         s.lastCity        = entities.city;
    }

    _resolveContext(sessionId, question, entities) {
        const resolved = { ...entities };
        if (!PRONOUN_PATTERN.test(question)) return resolved;
        const s = this._getSession(sessionId);
        if (!resolved.product_name && s.lastProductName) {
            resolved.product_name = s.lastProductName;
            console.log(`🔗 [${sessionId}] Pronoun → product: "${resolved.product_name}"`);
        }
        if (!resolved.city && s.lastCity) {
            resolved.city = s.lastCity;
            console.log(`🔗 [${sessionId}] Pronoun → city: "${resolved.city}"`);
        }
        return resolved;
    }

    _pruneExpiredSessions() {
        const now = Date.now();
        let pruned = 0;
        for (const [id, s] of this.sessions.entries()) {
            if (now - s.lastActive > SESSION_TTL_MS) { this.sessions.delete(id); pruned++; }
        }
        if (pruned > 0) console.log(`🧹 Pruned ${pruned} expired session(s)`);
    }

    async answerWithLLM(question, sessionId, opts = {}) {
        console.log(`🤖 [${sessionId}] Processing: "${question}"`);
        const isPronoun     = PRONOUN_PATTERN.test(question);
        const skipKnowledge = opts.skipKnowledge === true;
        const patientId     = opts.patientId || null;

        // ── 1. Parse intent ────────────────────────────────────────────────────
        const intentData = !isPronoun ? await llmService.parseIntent(question) : null;
        const DB_INTENTS = new Set(['test_query', 'branch_query', 'sample_status_query', 'patient_profile_query', 'client_account_query', 'booking_query', 'technician_info_query']);
        const isDBIntent = intentData && DB_INTENTS.has(intentData.intent);

        // ── 2. Quick return for general greeting/chitchat ─────────────────────
        if (intentData?.intent === 'general' && intentData.general_response) {
            return {
                question,
                answer: intentData.general_response,
                context_used: { intent: 'general', used_llm: true, is_general: true, from_cache: false }
            };
        }

        // ── 3. Knowledge base (static QA + website) — skipped for DB intents ─
        if (!isPronoun && !skipKnowledge && !isDBIntent) {
            const knowledge = await resolveKnowledge(question);
            if (knowledge) {
                console.log(`📖 [${sessionId}] Answered from ${knowledge.source}`);
                return {
                    question,
                    answer: knowledge.answer,
                    context_used: {
                        intent: knowledge.source, used_llm: knowledge.source === 'general_knowledge',
                        is_general: true, from_cache: false, source: knowledge.source, session_id: sessionId
                    }
                };
            }
        }

        const entities  = this._resolveContext(sessionId, question, intentData?.entities || {});

        // ── Intent safety-nets ─────────────────────────────────────────────────
        const qLow   = question.toLowerCase();
        let intent   = intentData?.intent || 'test_query';

        // Personal-data phrasing always overrides the LLM's guess, regardless of what
        // it classified the question as. GPT-3.5 was found to misclassify these newer
        // intents as test_query outright (not just 'general'), so gating this behind
        // `intent === 'general'` let questions like "show my profile" fall through to
        // buildTestQuery and return a random test list instead of the patient's data.
        if (PATIENT_PROFILE_PATTERN.test(question) || BARE_RELATION_PATTERN.test(question)) {
            intent = 'patient_profile_query';
        } else if (CLIENT_ACCOUNT_PATTERN.test(question)) {
            intent = 'client_account_query';
        } else if (TECHNICIAN_QUERY_PATTERN.test(question)) {
            intent = 'technician_info_query';
        } else if (BOOKING_QUERY_PATTERN.test(question)) {
            intent = 'booking_query';
        } else if (intent === 'general') {
            if (/\b(my sample|my report|my result|track my|sample status|where is my (report|result|sample))\b/i.test(question)) {
                intent = 'sample_status_query';
            } else if (/\b(package[s]?|test[s]?|panel|checkup|health screen)\b/.test(qLow)) {
                intent = 'test_query';
            } else if (/\b(branch|location|centre|center|address|coimbatore|trichy)\b/.test(qLow)) {
                intent = 'branch_query';
            }
        }

        // Generic-listing safety-net: clear bad keywords like "available tests", "show all"
        const GENERIC_LIST_TESTS = /\b(show|list|display|what|all)\b.*\b(tests?|packages?|available)\b|\b(tests?|packages?)\b.*(available|all)\b/i;
        const BAD_KEYWORDS       = /^(available\s*tests?|all\s*tests?|show\s*all|list\s*all|tests?|packages?)$/i;
        if (intent === 'test_query' && entities.keyword && BAD_KEYWORDS.test(entities.keyword.trim())) {
            entities.keyword = null;
        }
        if (intent === 'test_query' && GENERIC_LIST_TESTS.test(question) && !entities.product_name) {
            entities.keyword = null;
        }

        // Personal-data intents require a verified patient — reject without patientId
        if (PERSONAL_INTENTS.has(intent) && !patientId) {
            const messages = {
                sample_status_query:   '🔐 To check your sample status, please make sure you are logged in. Your patient account is needed to retrieve personal test results.',
                patient_profile_query: '🔐 To view patient/family profile details, please make sure you are logged in.',
                client_account_query:  '🔐 To view your account/subscription details, please make sure you are logged in.',
                booking_query:         '🔐 To view your booking details, please make sure you are logged in.',
                technician_info_query: '🔐 To view technician details, please make sure you are logged in.',
            };
            return {
                question,
                answer: messages[intent],
                context_used: { intent, error: 'no_patient_id', from_cache: false, session_id: sessionId }
            };
        }

        // Bookings span 3 tables (ip_bookings + ip_available_slots for the exact slot
        // time, ip_booking_items, ip_booking_documents) and need multiple queries, so it
        // gets its own handler instead of the single-SQL build/execute/format pipeline
        // used below for the other intents.
        if (intent === 'booking_query') {
            const explicitLimit = this._extractBookingLimit(question);
            const isHistory = !!explicitLimit || BOOKING_HISTORY_PATTERN.test(question) || entities.booking_history === true;
            const { answer, dataFound } = await this.answerBookingQuery(patientId, isHistory, explicitLimit);
            this._updateSession(sessionId, intent, entities);
            llmService.saveToMemory(sessionId, question, answer);
            return {
                question,
                answer,
                context_used: {
                    intent, entities: { booking_history: isHistory }, data_found: dataFound,
                    used_llm: false, is_general: false, from_cache: false, session_id: sessionId
                }
            };
        }

        // Technician info joins ip_bookings (to find/verify the booking + its
        // technician_id, scoped to this patient) with ip_technicians (the actual profile)
        // — a second table the generic single-SQL pipeline below doesn't support.
        if (intent === 'technician_info_query') {
            const bookingRef = question.match(BOOKING_REF_PATTERN)?.[0] || null;
            const bookingIdMention = bookingRef ? null : (question.match(BOOKING_ID_MENTION_PATTERN)?.[1] || null);
            const { answer, dataFound } = await this.answerTechnicianQuery(patientId, bookingRef, bookingIdMention);
            this._updateSession(sessionId, intent, entities);
            llmService.saveToMemory(sessionId, question, answer);
            return {
                question,
                answer,
                context_used: {
                    intent, entities: { booking_ref: bookingRef, booking_id: bookingIdMention }, data_found: dataFound,
                    used_llm: false, is_general: false, from_cache: false, session_id: sessionId
                }
            };
        }

        // "my profile" / "my blood group" → the logged-in patient's own row only.
        // "family members" / "my mother's ..." → join across client_id to include
        // everyone registered under the same account. GPT's entity extraction for
        // relation/person_name isn't reliable enough alone, so fall back to a regex.
        if (intent === 'patient_profile_query' && !entities.relation) {
            const relMatch = question.match(RELATION_PATTERN);
            if (relMatch) entities.relation = relMatch[1];
        }
        const isFamilyScope = intent === 'patient_profile_query' &&
            (FAMILY_SCOPE_PATTERN.test(question) || !!entities.relation || !!entities.person_name);

        const sql = intent === 'branch_query'
            ? this.buildBranchQuery(entities)
            : intent === 'sample_status_query'
                ? this.buildSampleQuery(entities, patientId)
                : intent === 'patient_profile_query'
                    ? this.buildPatientProfileQuery(entities, patientId, isFamilyScope)
                    : intent === 'client_account_query'
                        ? this.buildClientAccountQuery(patientId)
                        : this.buildTestQuery(entities);
        const queryType = intent;

        let data  = [];
        let error = null;

        if (sql) {
            try {
                console.log(`🔍 SQL: ${sql}`);
                const [rows] = await db.pool.execute(sql);
                data = rows;
                console.log(`✅ ${data.length} results`);
            } catch (err) {
                error = err.message;
                console.error('Query error:', err);
            }
        }

        // Personal-data intents get dedicated formatters — no LLM needed, keeps PII out of
        // the general-purpose prompt and avoids noisy/inconsistent formatting.
        const formattedResponse = (intent === 'sample_status_query')
            ? this.formatSampleStatus(data, error)
            : (intent === 'patient_profile_query')
                ? this.formatPatientProfile(data, error, isFamilyScope)
                : (intent === 'client_account_query')
                    ? this.formatClientAccount(data, error)
                    : await llmService.formatResponse(question, intent, entities, data, error);

        this._updateSession(sessionId, intent, entities);
        llmService.saveToMemory(sessionId, question, formattedResponse);

        const result = {
            question,
            answer: formattedResponse,
            context_used: {
                intent, entities, data_found: data.length,
                used_llm: true, is_general: false, from_cache: false,
                context_resolved: isPronoun, session_id: sessionId
            }
        };

        return result;
    }

    // ── Query builders ─────────────────────────────────────────────────────────

    buildTestQuery(entities) {
        const conditions = [];

        if (entities.product_name) {
            conditions.push(`LOWER(product_name) LIKE '%${entities.product_name.toLowerCase().replace(/'/g, "''")}%'`);
        }
        if (entities.keyword) {
            conditions.push(`(LOWER(product_name) LIKE '%${entities.keyword.toLowerCase().replace(/'/g, "''")}%' OR LOWER(product_description) LIKE '%${entities.keyword.toLowerCase().replace(/'/g, "''")}%')`);
        }
        if (entities.fasting_query) {
            // Return tests that have pre_instructions (fasting/preparation info)
            return `SELECT ${TEST_COLS} FROM ip_products WHERE pre_instructions IS NOT NULL AND pre_instructions != '' AND product_active = 1 LIMIT 20`;
        }
        if (entities.price_query && conditions.length === 0) {
            return `SELECT ${TEST_COLS} FROM ip_products WHERE product_active = 1 ORDER BY product_price ASC LIMIT 20`;
        }
        if (conditions.length === 0) {
            return `SELECT ${TEST_COLS} FROM ip_products WHERE product_active = 1 LIMIT 20`;
        }
        return `SELECT ${TEST_COLS} FROM ip_products WHERE (${conditions.join(' OR ')}) AND product_active = 1`;
    }

    buildBranchQuery(entities) {
        if (entities.city) {
            return `SELECT ${BRANCH_COLS} FROM ip_branches WHERE LOWER(branch_city) LIKE '%${entities.city.toLowerCase().replace(/'/g, "''")}%' AND branch_active = 1`;
        }
        if (entities.branch_name) {
            return `SELECT ${BRANCH_COLS} FROM ip_branches WHERE LOWER(branch_name) LIKE '%${entities.branch_name.toLowerCase().replace(/'/g, "''")}%' AND branch_active = 1`;
        }
        return `SELECT ${BRANCH_COLS} FROM ip_branches WHERE branch_active = 1 ORDER BY branch_name`;
    }

    buildSampleQuery(entities, patientId) {
        if (!patientId) return null;
        const pid  = String(patientId).replace(/'/g, "''");
        const cols = 'sample_id, sample_barcode, booking_id, sample_type, sample_status, ' +
                     'collected_at, submitted_at, received_at, processing_at, ' +
                     'results_ready_at, reported_at, notes';

        if (entities.booking_id) {
            const bid = String(entities.booking_id).replace(/'/g, "''");
            return `SELECT ${cols} FROM ip_sample_tracking WHERE patient_id = '${pid}' AND booking_id = '${bid}' ORDER BY collected_at DESC LIMIT 5`;
        }
        return `SELECT ${cols} FROM ip_sample_tracking WHERE patient_id = '${pid}' ORDER BY collected_at DESC LIMIT 10`;
    }

    // "my profile" (familyScope=false) → just the logged-in patient's own row.
    // "family members" / "my mother's ..." (familyScope=true) → resolves the client_id
    // via a self-join and returns every (non-deleted) patient row under that same
    // client_id — i.e. the account holder plus any family members they registered.
    // Never exposes another client's patients either way.
    buildPatientProfileQuery(entities, patientId, familyScope) {
        if (!patientId) return null;
        const pid = String(patientId).replace(/'/g, "''");

        if (!familyScope) {
            const cols = PATIENT_COLS.map(c => `p.${c}`).join(', ');
            return `SELECT ${cols} FROM ip_patients p WHERE p.patient_id = '${pid}' AND p.deleted_at IS NULL LIMIT 1`;
        }

        const cols = PATIENT_COLS.map(c => `p2.${c}`).join(', ');
        const conditions = [`p1.patient_id = '${pid}'`, 'p2.deleted_at IS NULL'];

        if (entities.relation) {
            conditions.push(`LOWER(p2.patient_relation) LIKE '%${entities.relation.toLowerCase().replace(/'/g, "''")}%'`);
        }
        if (entities.person_name) {
            const n = entities.person_name.toLowerCase().replace(/'/g, "''");
            conditions.push(`(LOWER(p2.patient_name) LIKE '%${n}%' OR LOWER(p2.patient_surname) LIKE '%${n}%')`);
        }

        return `SELECT ${cols} FROM ip_patients p1 ` +
               `JOIN ip_patients p2 ON p2.client_id = p1.client_id ` +
               `WHERE ${conditions.join(' AND ')} LIMIT 20`;
    }

    // Resolves the client account (subscription/status) tied to the logged-in patient.
    buildClientAccountQuery(patientId) {
        if (!patientId) return null;
        const pid  = String(patientId).replace(/'/g, "''");
        const cols = CLIENT_COLS.map(c => `c.${c}`).join(', ');
        return `SELECT ${cols} FROM ip_clients c ` +
               `JOIN ip_patients p ON p.client_id = c.client_id ` +
               `WHERE p.patient_id = '${pid}' LIMIT 1`;
    }

    // Parses an explicit count out of "last two bookings" / "past 3 bookings" / "last
    // couple of bookings" — returns null if the question didn't name a specific count
    // (caller then falls back to 1 for the latest, or 20 for a full history).
    _extractBookingLimit(question) {
        const m = question.match(BOOKING_LIMIT_PATTERN);
        if (!m) return null;
        const raw = m[1].toLowerCase().replace(/\s+of$/, '');
        const n = /^\d+$/.test(raw) ? parseInt(raw, 10) : BOOKING_NUMBER_WORDS[raw];
        return (n && n > 0) ? Math.min(n, 20) : null;
    }

    // Bookings, scoped strictly to this patient_id (not the whole family/client_id —
    // per spec, only the particular patient's own bookings). Resolves the exact
    // appointment slot via ip_available_slots (ip_bookings only stores the slot id),
    // then pulls the line items and a document count for each booking found. Runs as
    // several queries rather than one big join so item/document rows never duplicate
    // the booking row (and so "no items" doesn't silently drop a booking via INNER JOIN).
    async answerBookingQuery(patientId, isHistory, explicitLimit) {
        if (!patientId) return { answer: '🔐 To view your booking details, please make sure you are logged in.', dataFound: 0 };
        const pid = String(patientId).replace(/'/g, "''");
        const limit = explicitLimit || (isHistory ? 20 : 1);

        const bookingCols = 'b.booking_id, b.booking_ref, b.booking_date, b.booking_type, b.status, ' +
            'b.payment_status, b.amount_paid, b.amount_due, b.total_amount, b.discount_amount, ' +
            'b.discount_reason, b.city, b.postal_code, b.technician_id, b.technician_name, ' +
            'avs.slot_date, avs.slot_time';
        // booking_date alone is not a reliable "latest" key — multiple bookings can share
        // the same booking_date, and MySQL's tie-break order for equal ORDER BY values is
        // undefined, so LIMIT 1 could return any of them. created_at is the actual
        // insertion timestamp; booking_id (auto-increment PK) is a secondary tie-break for
        // the rare case two rows share the same created_at.
        const bookingSql = `SELECT ${bookingCols} FROM ip_bookings b ` +
            `LEFT JOIN ip_available_slots avs ON avs.available_slot_id = b.available_slot_id ` +
            `WHERE b.patient_id = '${pid}' AND b.deleted_at IS NULL ` +
            `ORDER BY b.created_at DESC, b.booking_id DESC LIMIT ${limit}`;

        let bookings = [];
        try {
            console.log(`🔍 SQL: ${bookingSql}`);
            const [rows] = await db.pool.execute(bookingSql);
            bookings = rows;
        } catch (err) {
            console.error('Booking query error:', err);
            return { answer: `⚠️ Could not fetch booking information. Please try again or call 0422 4354242.`, dataFound: 0 };
        }

        if (bookings.length === 0) {
            return { answer: `🔍 No booking found for your account. Please contact us at 0422 4354242.`, dataFound: 0 };
        }

        const idList = bookings.map(b => `'${String(b.booking_id).replace(/'/g, "''")}'`).join(',');
        const itemsByBooking = new Map();
        const docCountByBooking = new Map();

        try {
            const itemsSql = 'SELECT booking_id, product_name_snapshot, quantity ' +
                `FROM ip_booking_items WHERE booking_id IN (${idList}) AND patient_id = '${pid}' ` +
                'ORDER BY booking_id, booking_item_id';
            console.log(`🔍 SQL: ${itemsSql}`);
            const [itemRows] = await db.pool.execute(itemsSql);
            for (const it of itemRows) {
                if (!itemsByBooking.has(it.booking_id)) itemsByBooking.set(it.booking_id, []);
                itemsByBooking.get(it.booking_id).push(it);
            }
        } catch (err) {
            console.error('Booking items query error:', err);
        }

        try {
            const docsSql = 'SELECT booking_id, COUNT(*) AS doc_count FROM ip_booking_documents ' +
                `WHERE booking_id IN (${idList}) AND patient_id = '${pid}' GROUP BY booking_id`;
            console.log(`🔍 SQL: ${docsSql}`);
            const [docRows] = await db.pool.execute(docsSql);
            for (const d of docRows) docCountByBooking.set(d.booking_id, Number(d.doc_count) || 0);
        } catch (err) {
            console.error('Booking documents query error:', err);
        }

        const reportsByBooking = new Map();
        try {
            const reportsSql = 'SELECT booking_id, test_name, report_url, result_status ' +
                `FROM ip_test_results WHERE booking_id IN (${idList}) AND patient_id = '${pid}' ` +
                "AND report_url IS NOT NULL AND report_url != '' " +
                'ORDER BY booking_id, result_id';
            console.log(`🔍 SQL: ${reportsSql}`);
            const [reportRows] = await db.pool.execute(reportsSql);
            for (const rr of reportRows) {
                if (!reportsByBooking.has(rr.booking_id)) reportsByBooking.set(rr.booking_id, []);
                reportsByBooking.get(rr.booking_id).push(rr);
            }
        } catch (err) {
            console.error('Test results query error:', err);
        }

        return {
            answer: this.formatBookingDetails(bookings, itemsByBooking, docCountByBooking, reportsByBooking, isHistory),
            dataFound: bookings.length,
        };
    }

    _renderBooking(b, itemsByBooking, docCountByBooking, reportsByBooking, numbered) {
        const items    = itemsByBooking.get(b.booking_id) || [];
        const docCount = docCountByBooking.get(b.booking_id) || 0;
        const reports  = reportsByBooking.get(b.booking_id) || [];
        const label    = b.booking_ref || `#${b.booking_id}`;

        const lines = [numbered ? `${numbered}. Booking ${label}` : `🧾 Booking ${label}`];
        lines.push(`   • Status: ${b.status || 'N/A'}`);
        if (b.payment_status) lines.push(`   • Payment Status: ${b.payment_status}`);
        if (b.booking_type) lines.push(`   • Type: ${b.booking_type}`);
        if (b.slot_date || b.slot_time) {
            lines.push(`   • Scheduled: ${[this._fmtDateOnly(b.slot_date), b.slot_time].filter(Boolean).join(' ')}`);
        }
        if (b.booking_date) lines.push(`   • Booked on: ${this._fmtDateOnly(b.booking_date)}`);
        lines.push(`   • Technician: ${b.technician_name || 'Nil'}`);
        if (b.city) lines.push(`   • Location: ${b.city}${b.postal_code ? ` - ${b.postal_code}` : ''}`);
        if (b.total_amount != null) {
            let amtLine = `   • Amount: ₹${b.total_amount}`;
            if (b.discount_amount) amtLine += ` (Discount: ₹${b.discount_amount}${b.discount_reason ? ` — ${b.discount_reason}` : ''})`;
            lines.push(amtLine);
        }
        if (b.amount_paid != null || b.amount_due != null) {
            lines.push(`   • Paid: ₹${b.amount_paid || 0} | Due: ₹${b.amount_due || 0}`);
        }
        if (items.length > 0) {
            lines.push('   • Tests/Items:');
            for (const it of items) {
                const name = `${it.product_name_snapshot || 'Item'}${it.quantity > 1 ? ` x${it.quantity}` : ''}`;
                lines.push(`      - ${name}`);
            }
        }
        if (docCount > 0) lines.push(`   • 📎 Documents: ${docCount} uploaded`);
        if (reports.length === 0) {
            lines.push('   • 📄 Report: Nil');
        } else {
            const uniqueUrls = [...new Set(reports.map(r => r.report_url))];
            if (uniqueUrls.length === 1) {
                lines.push(`   • 📄 Report: ${uniqueUrls[0]}`);
            } else {
                lines.push('   • 📄 Reports:');
                for (const rr of reports) {
                    lines.push(`      - ${rr.test_name || 'Test'}: ${rr.report_url}`);
                }
            }
        }
        return lines.join('\n');
    }

    formatBookingDetails(bookings, itemsByBooking, docCountByBooking, reportsByBooking, isHistory) {
        if (!bookings || bookings.length === 0) {
            return `🔍 No booking found for your account. Please contact us at 0422 4354242.`;
        }
        if (!isHistory) {
            return `🧾 Your latest booking:\n\n${this._renderBooking(bookings[0], itemsByBooking, docCountByBooking, reportsByBooking, null)}`;
        }
        const rendered = bookings.map((b, i) => this._renderBooking(b, itemsByBooking, docCountByBooking, reportsByBooking, i + 1));
        return `📋 Your booking history:\n\n${rendered.join('\n\n')}`;
    }

    // Technician assigned to one of the patient's bookings — defaults to the latest
    // booking, or a specific one if the patient names a booking_ref ("BK...") or a bare
    // booking id ("booking 87"). Always re-verifies the booking belongs to this patient_id
    // before joining ip_technicians, so a booking_ref can't be used to probe another
    // patient's technician.
    async answerTechnicianQuery(patientId, bookingRef, bookingIdMention) {
        if (!patientId) return { answer: '🔐 To view technician details, please make sure you are logged in.', dataFound: 0 };
        const pid = String(patientId).replace(/'/g, "''");

        const conditions = [`b.patient_id = '${pid}'`, 'b.deleted_at IS NULL'];
        if (bookingRef) {
            conditions.push(`b.booking_ref = '${bookingRef.replace(/'/g, "''")}'`);
        } else if (bookingIdMention) {
            conditions.push(`b.booking_id = '${String(bookingIdMention).replace(/'/g, "''")}'`);
        }

        const techCols = TECHNICIAN_COLS.map(c => `t.${c}`).join(', ');
        const sql = `SELECT b.booking_id, b.booking_ref, b.technician_id, b.technician_name, ${techCols} ` +
            `FROM ip_bookings b LEFT JOIN ip_technicians t ON t.technician_id = b.technician_id ` +
            `WHERE ${conditions.join(' AND ')} ` +
            `ORDER BY b.created_at DESC, b.booking_id DESC LIMIT 1`;

        let rows = [];
        try {
            console.log(`🔍 SQL: ${sql}`);
            [rows] = await db.pool.execute(sql);
        } catch (err) {
            console.error('Technician query error:', err);
            return { answer: `⚠️ Could not fetch technician information. Please try again or call 0422 4354242.`, dataFound: 0 };
        }

        if (rows.length === 0) {
            const scope = bookingRef ? `booking ${bookingRef}` : bookingIdMention ? `booking #${bookingIdMention}` : 'your account';
            return { answer: `🔍 No booking found for ${scope}. Please contact us at 0422 4354242.`, dataFound: 0 };
        }

        return { answer: this.formatTechnicianInfo(rows[0]), dataFound: 1 };
    }

    formatTechnicianInfo(row) {
        const label = row.booking_ref || `#${row.booking_id}`;
        if (!row.technician_id) {
            return `🔍 No technician has been assigned yet for booking ${label}.`;
        }

        const lines = [`👷 Technician for booking ${label}:`];
        lines.push(`   • Name: ${row.technician_name || 'Nil'}`);
        if (row.technician_code)   lines.push(`   • Technician Code: ${row.technician_code}`);
        if (row.specialization)    lines.push(`   • Specialization: ${row.specialization}`);
        if (row.certifications)    lines.push(`   • Certifications: ${row.certifications}`);
        if (row.tech_age != null)  lines.push(`   • Age: ${row.tech_age}`);
        if (row.tech_city)         lines.push(`   • Based in: ${row.tech_city}`);
        return lines.join('\n');
    }

    // Maps each sample_status to the date column that is most meaningful for it.
    // Only that date is shown to the patient — avoids dumping all timestamps.
    _statusDateField(status = '') {
        const s = status.toLowerCase();
        if (s.includes('report'))               return 'reported_at';
        if (s.includes('result') || s.includes('ready')) return 'results_ready_at';
        if (s.includes('process'))              return 'processing_at';
        if (s.includes('receiv'))               return 'received_at';
        if (s.includes('submit'))               return 'submitted_at';
        return null; // "Collected" and unknown → no extra date needed
    }

    _fmtDate(val) {
        if (!val) return null;
        const d = new Date(val);
        if (isNaN(d)) return null;
        return d.toLocaleString('en-IN', {
            day: '2-digit', month: 'short', year: 'numeric',
            hour: '2-digit', minute: '2-digit', hour12: true
        });
    }

    formatSampleStatus(data, error) {
        if (error) return `⚠️ Could not fetch sample status. Please try again or call 0422 4354242.`;
        if (!data || data.length === 0) {
            return `🔍 No sample records found for your account. If you recently gave a sample, please check again in a few hours or contact us at 0422 4354242.`;
        }

        const lines = data.map((row, i) => {
            const status      = row.sample_status || 'Unknown';
            const dateField   = this._statusDateField(status);
            const statusDate  = dateField ? this._fmtDate(row[dateField]) : null;
            const collectedOn = this._fmtDate(row.collected_at);

            let line = `Sample ${i + 1}`;
            line += `\n• Type: ${row.sample_type || 'N/A'}`;
            line += `\n• Status: ${status}`;
            if (collectedOn)  line += `\n• Collected: ${collectedOn}`;
            if (statusDate)   line += `\n• ${this._statusLabel(status)}: ${statusDate}`;
            if (row.notes)    line += `\n• Note: ${row.notes}`;
            return line;
        });

        return `🧪 Your sample status:\n\n${lines.join('\n\n')}`;
    }

    _statusLabel(status = '') {
        const s = status.toLowerCase();
        if (s.includes('report'))               return 'Reported on';
        if (s.includes('result') || s.includes('ready')) return 'Results ready at';
        if (s.includes('process'))              return 'Processing started';
        if (s.includes('receiv'))               return 'Received at lab';
        if (s.includes('submit'))               return 'Submitted on';
        return 'Updated on';
    }

    _fmtDateOnly(val) {
        if (!val) return null;
        const d = new Date(val);
        if (isNaN(d)) return null;
        return d.toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' });
    }

    formatPatientProfile(data, error, familyScope) {
        if (error) return `⚠️ Could not fetch patient information. Please try again or call 0422 4354242.`;
        if (!data || data.length === 0) {
            return `🔍 No patient record found${familyScope ? ' for your account' : ''}. Please contact us at 0422 4354242.`;
        }

        const lines = data.map((row, i) => {
            const name = [row.patient_name, row.patient_surname].filter(Boolean).join(' ') || 'Unnamed';
            let line = familyScope
                ? `${i + 1}. ${name}${row.patient_relation ? ` (${row.patient_relation})` : ''}`
                : name;
            if (row.patient_gender)      line += `\n   • Gender: ${row.patient_gender}`;
            if (row.patient_age != null) line += `\n   • Age: ${row.patient_age}`;
            if (row.patient_dob)         line += `\n   • DOB: ${this._fmtDateOnly(row.patient_dob)}`;
            if (row.patient_blood_group) line += `\n   • Blood Group: ${row.patient_blood_group}`;
            if (row.patient_mobile)      line += `\n   • Mobile: ${row.patient_mobile}`;
            if (row.patient_email)       line += `\n   • Email: ${row.patient_email}`;
            if (row.patient_city)        line += `\n   • City: ${row.patient_city}`;
            if (row.health_conditions)   line += `\n   • Health Conditions: ${row.health_conditions}`;
            return line;
        });

        const heading = familyScope ? '👨‍👩‍👧‍👦 Patients on your account:' : '👤 Your profile:';
        return `${heading}\n\n${lines.join('\n\n')}`;
    }

    formatClientAccount(data, error) {
        if (error) return `⚠️ Could not fetch your account details. Please try again or call 0422 4354242.`;
        if (!data || data.length === 0) {
            return `🔍 No account details found for your login. Please contact us at 0422 4354242.`;
        }

        const row = data[0];
        return `👤 Account: ${row.client_name || 'N/A'}\n` +
               `📱 Mobile: ${row.client_mobile_no || 'N/A'}\n` +
               `⭐ Subscription: ${row.subscription_tier || 'N/A'}\n` +
               `✅ Status: ${row.client_account_status || 'N/A'}`;
    }
}

module.exports = new LLMRetriever();
   