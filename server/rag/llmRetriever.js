'use strict';

const db             = require('../db/database');
const llmService     = require('../services/llmService');
const cache          = require('../services/cacheService');
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

// Intents that expose personal data — require a verified patientId and are never
// served from (or written to) the question-text keyed answer cache.
const PERSONAL_INTENTS = new Set(['sample_status_query', 'patient_profile_query', 'client_account_query']);
const PERSONAL_QUESTION_PATTERN = /\b(my sample|my report|my result|track my|sample status|where is my|my famil|family member|my patients?|patient profile|my profile|my subscription|my account|blood group)\b/i;

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

        // ── 1. LLM answer cache — skip for personal (patient/account-specific) queries,
        //      since the cache is keyed by question text only and would otherwise leak
        //      one patient's data to another patient asking the same phrasing.
        const isPersonalQuestion = PERSONAL_QUESTION_PATTERN.test(question);
        if (!isPronoun && !isPersonalQuestion) {
            const hit = await cache.getLLMAnswer(question);
            if (hit) {
                console.log(`🎯 Cache HIT: "${question}"`);
                this._updateSession(sessionId, hit.context_used.intent, hit.context_used.entities || {});
                return { ...hit, context_used: { ...hit.context_used, from_cache: true } };
            }
        }

        // ── 2. Parse intent ────────────────────────────────────────────────────
        const intentData = !isPronoun ? await llmService.parseIntent(question) : null;
        const DB_INTENTS = new Set(['test_query', 'branch_query', 'sample_status_query', 'patient_profile_query', 'client_account_query']);
        const isDBIntent = intentData && DB_INTENTS.has(intentData.intent);

        // ── 3. Quick return for general greeting/chitchat ─────────────────────
        if (intentData?.intent === 'general' && intentData.general_response) {
            return {
                question,
                answer: intentData.general_response,
                context_used: { intent: 'general', used_llm: true, is_general: true, from_cache: false }
            };
        }

        // ── 4. Knowledge base (static QA + website) — skipped for DB intents ─
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

        if (intent === 'general') {
            if (/\b(my sample|my report|my result|track my|sample status|where is my (report|result|sample))\b/i.test(question)) {
                intent = 'sample_status_query';
            } else if (/\b(family member|my patients?|patients? (on|under|in) my account|my profile|patient profile|my (blood group|dob|date of birth)|my (mother|father|spouse|wife|husband|child|children|son|daughter|sister|brother)'?s?\b)\b/i.test(question)) {
                intent = 'patient_profile_query';
            } else if (/\b(my subscription|subscription (tier|plan)|my (account status|membership)|is my account active|client account)\b/i.test(question)) {
                intent = 'client_account_query';
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
            };
            return {
                question,
                answer: messages[intent],
                context_used: { intent, error: 'no_patient_id', from_cache: false, session_id: sessionId }
            };
        }

        const sql = intent === 'branch_query'
            ? this.buildBranchQuery(entities)
            : intent === 'sample_status_query'
                ? this.buildSampleQuery(entities, patientId)
                : intent === 'patient_profile_query'
                    ? this.buildPatientProfileQuery(entities, patientId)
                    : intent === 'client_account_query'
                        ? this.buildClientAccountQuery(patientId)
                        : this.buildTestQuery(entities);
        const queryType = intent;

        let data  = [];
        let error = null;

        if (sql) {
            const cachedRows = await cache.getQueryResult(sql);
            if (cachedRows) {
                data = cachedRows;
                console.log(`🎯 Query cache HIT (${data.length} rows)`);
            } else {
                try {
                    console.log(`🔍 SQL: ${sql}`);
                    const [rows] = await db.pool.execute(sql);
                    data = rows;
                    console.log(`✅ ${data.length} results`);
                    await cache.setQueryResult(sql, rows);
                } catch (err) {
                    error = err.message;
                    console.error('Query error:', err);
                }
            }
        }

        // Personal-data intents get dedicated formatters — no LLM needed, keeps PII out of
        // the general-purpose prompt and avoids noisy/inconsistent formatting.
        const formattedResponse = (intent === 'sample_status_query')
            ? this.formatSampleStatus(data, error)
            : (intent === 'patient_profile_query')
                ? this.formatPatientProfile(data, error)
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

        // Only cache successful, non-personal answers — never cache "not found" responses
        // so bad results don't get served to the same question on retry, and never cache
        // personal data so a different patient asking the same phrasing can't reuse it.
        if (!isPronoun && !isPersonalQuestion && data.length > 0 && !error) await cache.setLLMAnswer(question, result);
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

    // Resolves the logged-in patient's client_id via a self-join, then returns every
    // (non-deleted) patient row under that same client_id — i.e. the account holder
    // plus any family members they registered. Never exposes another client's patients.
    buildPatientProfileQuery(entities, patientId) {
        if (!patientId) return null;
        const pid  = String(patientId).replace(/'/g, "''");
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

    formatPatientProfile(data, error) {
        if (error) return `⚠️ Could not fetch patient information. Please try again or call 0422 4354242.`;
        if (!data || data.length === 0) {
            return `🔍 No patient records found for your account. Please contact us at 0422 4354242.`;
        }

        const lines = data.map((row, i) => {
            const name = [row.patient_name, row.patient_surname].filter(Boolean).join(' ') || 'Unnamed';
            let line = `${i + 1}. ${name}${row.patient_relation ? ` (${row.patient_relation})` : ''}`;
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

        return `👨‍👩‍👧‍👦 Patients on your account:\n\n${lines.join('\n\n')}`;
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
   