'use strict';

const https = require('https');
const http  = require('http');
const cache = require('../services/cacheService');
require('dotenv').config();

const ROOT_URL = process.env.WEBSITE_URL || 'https://microlabdiagnostics.com';
const PAGE_CACHE_TTL = 60 * 60; // 1 hour

// microlabindia.com is a single-page app — all content is on the homepage.
// Playwright renders the full SPA; keyword matching picks the right context.
const SITE_MAP = [
    {
        id:       'home',
        url:      `${ROOT_URL}`,
        keywords: ['microlab', 'mbl', 'microbiological laboratory', 'about', 'company', 'who are',
                   'what is', 'what does', 'overview', 'introduction', 'founded', 'mission',
                   'vision', 'values', 'diagnostics', 'lab', 'career', 'job', 'accreditation',
                   'nabl', 'quality', 'services', 'doctors', 'team', 'director']
    },
    {
        id:       'capabilities',
        url:      `${ROOT_URL}`,
        keywords: ['capability', 'capabilities', 'department', 'molecular biology', 'cytogenetics',
                   'serology', 'microbiology', 'biochemistry', 'clinical pathology', 'dna', 'rna',
                   'chromosomal', 'culture', 'sensitivity', 'antigen', 'antibody', 'test panel',
                   'what tests', 'blood test', 'lab test', 'health package', 'full body', 'checkup']
    },
    {
        id:       'contact',
        url:      `${ROOT_URL}`,
        keywords: ['contact', 'reach', 'email', 'phone', 'address', 'location', 'office',
                   'get in touch', 'support', 'enquiry', 'inquiry', 'help', 'branch',
                   'coimbatore', 'trichy', 'centre', 'center', 'nearest', 'where', 'whatsapp']
    },
    {
        id:       'home_collection',
        url:      `${ROOT_URL}`,
        keywords: ['home collection', 'sample collection', 'home visit', 'phlebotomist',
                   'doorstep', 'at home', 'collect sample', 'fasting', 'report', 'result',
                   'when will', 'how long', 'turnaround', 'download report', 'patient portal',
                   'online report', 'frequently asked', 'faq', 'how does']
    }
];

function selectPages(question) {
    const q = question.toLowerCase();
    const scored = SITE_MAP.map(page => {
        const hits = page.keywords.filter(kw => q.includes(kw)).length;
        return { ...page, hits };
    }).filter(p => p.hits > 0)
      .sort((a, b) => b.hits - a.hits);

    if (scored.length === 0) return [SITE_MAP[0]];
    return scored.slice(0, 2);
}

function fetchPageSimple(url, redirectsLeft = 5) {
    return new Promise((resolve) => {
        if (redirectsLeft <= 0) { resolve(null); return; }
        const lib = url.startsWith('https') ? https : http;
        const options = {
            headers: {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
                'Accept-Language': 'en-US,en;q=0.5',
            },
            timeout: 15000,
            rejectUnauthorized: false,
        };
        const req = lib.get(url, options, (res) => {
            if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
                const next = res.headers.location.startsWith('http')
                    ? res.headers.location
                    : new URL(res.headers.location, url).href;
                res.resume();
                return fetchPageSimple(next, redirectsLeft - 1).then(resolve);
            }
            let raw = '';
            res.on('data', chunk => raw += chunk);
            res.on('end', () => {
                const text = raw
                    .replace(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi, '')
                    .replace(/<style\b[^<]*(?:(?!<\/style>)<[^<]*)*<\/style>/gi, '')
                    .replace(/<!--[\s\S]*?-->/g, '')
                    .replace(/<[^>]+>/g, ' ')
                    .replace(/&nbsp;/g, ' ')
                    .replace(/&amp;/g, '&')
                    .replace(/&lt;/g, '<')
                    .replace(/&gt;/g, '>')
                    .replace(/\s{3,}/g, '\n\n')
                    .trim();
                resolve(text.length > 100 ? text : null);
            });
        });
        req.on('error', (err) => { console.error(`❌ Simple fetch error ${url}:`, err.message); resolve(null); });
        req.on('timeout', () => { req.destroy(); resolve(null); });
    });
}

async function fetchPageLive(url) {
    let browser = null;
    try {
        const { chromium } = require('playwright');
        browser = await chromium.launch({
            headless: true,
            args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage']
        });
        const page = await browser.newPage({
            userAgent: 'Mozilla/5.0 (compatible; MicroLabBot/1.0)'
        });

        await page.goto(url, { waitUntil: 'load', timeout: 20000 });
        await page.waitForTimeout(500);

        const text = await page.evaluate(() => {
            ['script','style','noscript','nav','footer','header','iframe','svg']
                .forEach(tag => document.querySelectorAll(tag).forEach(el => el.remove()));

            return (document.body?.innerText || '')
                .replace(/\s{3,}/g, '\n\n')
                .replace(/\n{4,}/g, '\n\n\n')
                .trim();
        });

        return text || null;
    } catch (err) {
        console.warn(`⚠️  Playwright failed for ${url}: ${err.message} — trying simple fetch`);
        return fetchPageSimple(url);
    } finally {
        if (browser) await browser.close();
    }
}

async function getLiveContent(question) {
    const pages  = selectPages(question);
    const result = [];

    console.log(`🌐 Live pages selected for "${question}": ${pages.map(p => p.id).join(', ')}`);

    for (const pageDef of pages) {
        const cacheKey = `website_page:${pageDef.id}`;

        const cached = await cache.get(cacheKey);
        if (cached) {
            console.log(`🎯 Page cache HIT: ${pageDef.id}`);
            result.push({ url: pageDef.url, title: pageDef.id, text: cached });
            continue;
        }

        console.log(`🔗 Fetching live: ${pageDef.url}`);
        const text = await fetchPageLive(pageDef.url);

        if (text && text.length > 50) {
            await cache.set(cacheKey, text, PAGE_CACHE_TTL);
            console.log(`✅ Fetched & cached: ${pageDef.id} (${text.length} chars)`);
            result.push({ url: pageDef.url, title: pageDef.id, text });
        } else {
            console.warn(`⚠️  Thin or no content from ${pageDef.url}`);
        }
    }

    return result;
}

async function clearPageCache() {
    await cache.flush('website_page:*');
    console.log('🗑️  Website page cache cleared');
}

module.exports = { getLiveContent, clearPageCache, selectPages };
