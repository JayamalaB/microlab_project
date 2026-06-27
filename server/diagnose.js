/**
 * diagnose.js — run this ONCE on your server to see exactly what
 * Playwright extracts from each neuralarc.com page.
 *
 * Run: node diagnose.js
 *
 * This tells us:
 *  1. What raw text each page actually renders
 *  2. Whether numbers like "0+" are hardcoded or loaded dynamically
 *  3. Which pages have enough content to answer questions
 */

const { chromium } = require('playwright');

const PAGES = [
    { id: 'home',     url: 'https://neuralarc.com' },
    { id: 'about',    url: 'https://neuralarc.com/about' },
    { id: 'services', url: 'https://neuralarc.com/Services' },
    { id: 'iot',      url: 'https://neuralarc.com/services/iot' },
    { id: 'ai',       url: 'https://neuralarc.com/services/AI,%20ML%20&%20Data%20Science' },
    { id: 'embedded', url: 'https://neuralarc.com/services/Embedded%20Software%20Development' },
    { id: 'fullstack',url: 'https://neuralarc.com/services/Full%20Stack%20Development' },
    { id: 'mobile',   url: 'https://neuralarc.com/services/app-development' },
    { id: 'training', url: 'https://neuralarc.com/services/training' },
    { id: 'contact',  url: 'https://neuralarc.com/contact' },
];

const WAIT_EXTRA_MS = 3000; // increase if site is slow to hydrate

(async () => {
    const browser = await chromium.launch({
        headless: true,
        args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage']
    });

    for (const { id, url } of PAGES) {
        const page = await browser.newPage({
            userAgent: 'Mozilla/5.0 (compatible; Diagnostic/1.0)'
        });
        try {
            console.log(`\n${'='.repeat(60)}`);
            console.log(`PAGE: ${id}  |  ${url}`);
            console.log('='.repeat(60));

            await page.goto(url, { waitUntil: 'networkidle', timeout: 30000 });
            await page.waitForTimeout(WAIT_EXTRA_MS);

            // Full raw innerText (no elements removed) — shows everything
            const rawText = await page.evaluate(() =>
                (document.body?.innerText || '').replace(/\s{3,}/g, '\n').trim()
            );

            // Clean text (nav/footer/scripts removed)
            const cleanText = await page.evaluate(() => {
                ['script','style','noscript','nav','footer','header','iframe','svg','button']
                    .forEach(t => document.querySelectorAll(t).forEach(el => el.remove()));
                return (document.body?.innerText || '').replace(/\s{3,}/g, '\n').trim();
            });

            console.log(`RAW length:   ${rawText.length} chars`);
            console.log(`CLEAN length: ${cleanText.length} chars`);
            console.log(`\n--- FULL CLEAN TEXT ---`);
            console.log(cleanText || '(empty)');

        } catch (err) {
            console.log(`ERROR: ${err.message}`);
        } finally {
            await page.close();
        }
    }

    await browser.close();
    console.log('\n✅ Diagnosis complete');
})();