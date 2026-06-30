const express = require('express');
const router = express.Router();
const llmRetriever = require('../rag/llmRetriever');
const db = require('../db/database');
const { resolveKnowledge, matchDefaultQA, isDBQuestion } = require('../services/knowledgeService');
const { getLiveContent } = require('../rag/websiteReader');
const OpenAI = require('openai');

const VALID_LAYERS = new Set(['all', 'static', 'db', 'web']);

/**
 * POST /api/chat/ask
 * Body: { question, session_id?, layer? }
 * layer: 'all' (default) | 'static' | 'db' | 'web'
 */
router.post('/ask', async (req, res) => {
    try {
        const { question, session_id, layer = 'all', patient_id } = req.body;

        if (!question) {
            return res.status(400).json({ error: 'Question is required' });
        }

        const sessionId   = session_id || req.ip || 'default';
        const searchLayer = VALID_LAYERS.has(layer) ? layer : 'all';
        const patientId   = patient_id || null;

        console.log(`🤖 [${sessionId}] Layer: "${searchLayer}" | Patient: ${patientId || 'guest'} | Q: "${question}"`);

        let result;

        if (searchLayer === 'static') {
            const answer = matchDefaultQA(question);
            result = answer
                ? { question, answer, context_used: { intent: 'default_qa', source: 'default_qa', from_cache: false, session_id: sessionId } }
                : { question, answer: "ℹ️ No static Q&A match found. Try a different question or call 1800-XXX-XXXX.", context_used: { intent: 'no_match', source: 'default_qa', session_id: sessionId } };

        } else if (searchLayer === 'db') {
            result = await llmRetriever.answerWithLLM(question, sessionId, { skipKnowledge: true, patientId });

        } else if (searchLayer === 'web') {
            result = await handleWebsiteOnlyQuery(question, sessionId);

        } else {
            result = await llmRetriever.answerWithLLM(question, sessionId, { patientId });
        }

        res.json({ success: true, data: result, layer: searchLayer });

    } catch (error) {
        console.error('Chat error:', error);
        res.status(500).json({ success: false, error: 'Internal server error', details: error.message });
    }
});

async function handleWebsiteOnlyQuery(question, sessionId) {
    const pages = await getLiveContent(question);

    if (!pages || pages.length === 0) {
        return {
            question,
            answer: "🌐 Couldn't retrieve relevant content from the website. Please call 1800-XXX-XXXX for live support.",
            context_used: { intent: 'website_live', source: 'website_live', data_found: 0, session_id: sessionId }
        };
    }

    const MAX_CTX = 4000;
    const context = pages.map(p => `=== ${p.url} ===\n${p.text}`).join('\n\n').slice(0, MAX_CTX);

    try {
        const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
        const apiRes = await openai.chat.completions.create({
            model: 'gpt-3.5-turbo',
            messages: [
                {
                    role: 'system',
                    content: `You are a helpful assistant for MicroLab Diagnostics.
Answer the user's question using ONLY the website content provided below.
STRICT RULES:
1. Use only what is in the provided content. No outside knowledge.
2. If the content does not contain a clear answer, say:
   "I don't have specific information about that. Please visit our website or call 1800-XXX-XXXX."
3. Be concise and natural — 2 to 5 sentences or a short bullet list.
4. Never mention "context", "chunk", "source", or internal terms.
5. Sound like a knowledgeable MicroLab team member.

LIVE WEBSITE CONTENT:
${context}`
                },
                { role: 'user', content: question }
            ],
            temperature: 0.3,
            max_tokens: 400
        });

        return {
            question,
            answer: apiRes.choices[0].message.content.trim(),
            context_used: { intent: 'website_live', source: 'website_live', data_found: pages.length, used_llm: true, session_id: sessionId }
        };

    } catch (err) {
        console.error('Website-only GPT error:', err.message);
        return {
            question,
            answer: "⚠️ Failed to synthesise a website answer. Please try again.",
            context_used: { intent: 'website_live', source: 'website_live', error: err.message, session_id: sessionId }
        };
    }
}

/**
 * POST /api/chat/verify-patient
 * Verifies patient credentials before exposing personal sample-tracking data.
 * Body: { patient_id, password }
 *
 * NOTE: Update the table name (ip_patients) and column names below to match
 *       your actual adminmicro schema. Common alternatives:
 *       - table:    ip_user, ip_patients, ip_accounts
 *       - id col:   patient_id, user_id, id
 *       - pwd col:  password, patient_password, mobile (if mobile is used as pwd)
 */
router.post('/verify-patient', async (req, res) => {
    try {
        const { patient_id, password } = req.body;
        if (!patient_id || !password) {
            return res.status(400).json({ success: false, error: 'Patient ID and password are required.' });
        }

        const [rows] = await db.pool.execute(
            `SELECT patient_id FROM ip_patients
             WHERE patient_id = ? AND patient_mobile = ? LIMIT 1`,
            [patient_id, password]
        );

        if (rows.length > 0) {
            console.log(`✅ Patient verified: ${patient_id}`);
            return res.json({ success: true, patient_id: rows[0].patient_id.toString() });
        }

        console.log(`❌ Patient verify failed for id: ${patient_id}`);
        res.status(401).json({ success: false, error: 'Invalid Patient ID or password. Please try again.' });

    } catch (error) {
        console.error('Patient verify error:', error.message);
        res.status(500).json({ success: false, error: 'Verification failed. Please try again later.' });
    }
});

router.get('/products', async (req, res) => {
    try {
        const [rows] = await db.pool.execute(
            'SELECT product_name FROM ip_products WHERE product_active = 1 ORDER BY product_name ASC'
        );
        res.json({ success: true, data: rows.map(r => r.product_name) });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

router.post('/book-test', async (req, res) => {
    try {
        const { name, age, phone, package: pkg } = req.body;

        if (!name || !age || !phone || !pkg) {
            return res.status(400).json({ success: false, error: 'All fields are required' });
        }

        const result = await db.saveTestBooking(name, age, phone, pkg);

        if (result.success) {
            res.json({ success: true, data: { id: result.id, message: 'Booking confirmed' } });
        } else {
            res.status(500).json({ success: false, error: result.error || 'Booking failed' });
        }
    } catch (error) {
        console.error('Book test error:', error);
        res.status(500).json({ success: false, error: error.message });
    }
});

router.get('/history', async (req, res) => {
    try {
        const [history] = await db.pool.execute(
            'SELECT * FROM conversation_history ORDER BY created_at DESC LIMIT 50'
        );
        res.json({ success: true, data: history });
    } catch (error) {
        res.status(500).json({ success: false, error: error.message });
    }
});

module.exports = router;
