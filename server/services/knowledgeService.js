'use strict';

const path   = require('path');
const fs     = require('fs');
const OpenAI = require('openai');
require('dotenv').config();

const { getLiveContent } = require('../rag/websiteReader');

const QA_PATH       = path.resolve(__dirname, '../data/defaultQA.json');
const MAX_CTX_CHARS = 4000;

let defaultQA = null;

function loadQA() {
    try {
        delete require.cache[require.resolve(QA_PATH)];
        defaultQA = JSON.parse(fs.readFileSync(QA_PATH, 'utf-8'));
        console.log(`📚 Loaded ${defaultQA.faqs?.length || 0} default Q&A entries`);
    } catch (err) {
        console.warn('⚠️  defaultQA.json error:', err.message);
        defaultQA = { faqs: [] };
    }
}

function matchDefaultQA(question) {
    if (!defaultQA?.faqs?.length) return null;
    const q = question.toLowerCase().trim();
    for (const entry of defaultQA.faqs) {
        for (const phrase of (entry.questions || [])) {
            if (q.includes(phrase.toLowerCase())) {
                console.log(`✅ Default QA match: [${entry.id}]`);
                return entry.answer;
            }
        }
    }
    return null;
}

// Keywords that indicate a question belongs to the DB pipeline — skip website layer
const DB_KEYWORDS = [
    'product', 'price', 'stock', 'customer', 'order', 'warehouse', 'inventory',
    'laptop', 'monitor', 'keyboard', 'mouse', 'cable', 'electronics', 'accessories',
    'shipped', 'membership', 'gold', 'silver', 'platinum', 'purchase', 'bought',
    'in stock', 'out of stock', 'order status', 'track order', 'my order',
    'invoice', 'receipt', 'cart', 'total spent', 'spending', 'spent',
    'maximum', 'minimum', 'most orders', 'least orders', 'how many orders',
    'all customers', 'list customers', 'show customers', 'customer list',
    'customer info', 'customer details', 'customer information',
    // MicroLab-specific DB terms
    'booking', 'bookings', 'my booking', 'test result', 'lab result',
    'report ready', 'sample collected', 'my report', 'test status',
    // Patient/account terms (ip_patients / ip_clients)
    'family member', 'my patients', 'patient profile', 'my profile', 'my subscription',
    'subscription tier', 'subscription plan', 'my account', 'account status', 'blood group',
];

const SITE_TERMS = [
    'microlab', 'diagnostics', 'full stack', 'mobile app', 'data science',
    'machine learning', 'embedded', 'software', 'development', 'iot', 'services',
    'training', 'internship', 'contact', 'about', 'branch', 'location'
];

function looksLikePersonName(question) {
    const lower   = question.toLowerCase().trim();
    const cleaned = lower.replace(/['']s\b/g, '').replace(/\b(information|details|info|data|profile|history|records?)\b/g, '').trim();
    const words   = cleaned.split(/\s+/).filter(Boolean);

    if (words.length > 5) return false;
    if (SITE_TERMS.some(t => lower.includes(t))) return false;
    if (DB_KEYWORDS.some(kw => lower.includes(kw))) return false;

    const nameWords = words.filter(w => /^[a-zA-Z]{2,12}$/.test(w));
    if (nameWords.length >= 2) {
        console.log(`👤 Name pattern detected: "${question}" → routing to DB`);
        return true;
    }

    return false;
}

function isDBQuestion(question) {
    const q = question.toLowerCase();
    if (DB_KEYWORDS.some(kw => q.includes(kw))) return true;
    if (looksLikePersonName(question)) return true;
    return false;
}

async function answerFromWebsite(question) {
    const pages = await getLiveContent(question);

    if (!pages || pages.length === 0) {
        console.log('ℹ️  No live content retrieved');
        return null;
    }

    const context = pages
        .map(p => `=== ${p.url} ===\n${p.text}`)
        .join('\n\n')
        .slice(0, MAX_CTX_CHARS);

    if (context.trim().length < 50) {
        console.log('ℹ️  Fetched content too thin to answer from');
        return null;
    }

    try {
        const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

        const res = await openai.chat.completions.create({
            model: 'gpt-3.5-turbo',
            messages: [
                {
                    role: 'system',
                    content: `You are a helpful assistant for MicroLab Diagnostics.

Answer the user's question using ONLY the website content provided below.

STRICT RULES:
1. Use only what is in the provided content. No outside knowledge.
2. If the content does not contain a clear answer, respond with:
   "I don't have specific information about that. Please call us at our toll-free number or visit the nearest MicroLab branch."
3. Be concise and natural — 2 to 5 sentences, or a short bullet list when listing items.
4. Never mention "context", "chunk", "source", "the provided content" or any internal terms.
5. Never discuss store products, inventory, or warehouse data — those are handled separately.
6. Sound like a knowledgeable MicroLab team member.

LIVE WEBSITE CONTENT:
${context}`
                },
                { role: 'user', content: question }
            ],
            temperature: 0.3,
            max_tokens: 400
        });

        return res.choices[0].message.content.trim();

    } catch (err) {
        console.error('❌ GPT synthesis error:', err.message);
        return null;
    }
}

async function resolveKnowledge(question) {
    const qaAnswer = matchDefaultQA(question);
    if (qaAnswer) return { answer: qaAnswer, source: 'default_qa' };

    if (isDBQuestion(question)) {
        console.log(`🗄️  DB question — skipping website: "${question}"`);
        return null;
    }

    const webAnswer = await answerFromWebsite(question);
    if (webAnswer) return { answer: webAnswer, source: 'website_live' };

    return null;
}

async function init() {
    loadQA();
    console.log('✅ Knowledge service ready');
}

function reloadQA() {
    loadQA();
    return { reloaded: true, count: defaultQA?.faqs?.length || 0 };
}

module.exports = { init, resolveKnowledge, reloadQA, matchDefaultQA, isDBQuestion };
