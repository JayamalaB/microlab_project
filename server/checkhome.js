/**
 * checkHome.js — paste the full home page text so we can see
 * exactly what's being captured and fix the counter issue.
 *
 * Run: node checkHome.js
 */
const { chromium } = require('playwright');

(async () => {
    const browser = await chromium.launch({
        headless: true,
        args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage']
    });
    const page = await browser.newPage();
    await page.goto('https://neuralarc.com', { waitUntil: 'networkidle', timeout: 30000 });

    // Try different wait times and show what changes
    for (const ms of [500, 2000, 4000, 6000]) {
        await page.waitForTimeout(ms === 500 ? 500 : 2000);
        const text = await page.evaluate(() => {
            ['script','style','noscript','nav','footer','header','iframe','svg']
                .forEach(t => document.querySelectorAll(t).forEach(el => el.remove()));
            return (document.body?.innerText || '').replace(/\s{3,}/g, '\n').trim();
        });
        console.log(`\n===== AFTER ${ms}ms =====`);
        console.log('LENGTH:', text.length);
        console.log(text);
    }

    // Also dump the raw HTML of any element containing "client" or numbers
    const counters = await page.evaluate(() => {
        const all = document.querySelectorAll('*');
        const hits = [];
        for (const el of all) {
            const t = el.innerText || '';
            if (/\d+\+|\bclient|\bproject|\byear/.test(t) && el.children.length === 0) {
                hits.push({ tag: el.tagName, class: el.className, text: t.trim() });
            }
        }
        return hits.slice(0, 30);
    });
    console.log('\n===== COUNTER ELEMENTS =====');
    console.log(JSON.stringify(counters, null, 2));

    await browser.close();
})();