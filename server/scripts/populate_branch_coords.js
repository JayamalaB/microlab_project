/**
 * One-time script — extracts lat/lng from each branch's business_url
 * and writes the coordinates into branches.latitude / branches.longitude.
 *
 * Usage (run once from the server/scripts folder):
 *   node populate_branch_coords.js
 *
 * Requires no extra npm packages — uses Node's built-in https/http.
 */

const https = require('https');
const http  = require('http');
require('dotenv').config({ path: require('path').join(__dirname, '../.env') });
const db = require('../config/db');

// Follow up to maxHops redirects and return the final URL
function followRedirects(url, maxHops = 12) {
  return new Promise((resolve, reject) => {
    let hops = 0;

    function fetch(currentUrl) {
      if (hops++ >= maxHops) return reject(new Error('Too many redirects'));

      const mod = currentUrl.startsWith('https') ? https : http;
      const req = mod.get(
        currentUrl,
        { headers: { 'User-Agent': 'Mozilla/5.0 (compatible; microlab-coord-bot/1.0)' } },
        (res) => {
          if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
            const next = res.headers.location.startsWith('http')
              ? res.headers.location
              : new URL(res.headers.location, currentUrl).toString();
            res.resume(); // drain so the socket is released
            return fetch(next);
          }
          // Not a redirect — this is the final URL
          res.resume();
          resolve(currentUrl);
        }
      );
      req.on('error', reject);
      req.setTimeout(12000, () => { req.destroy(); reject(new Error('Request timeout')); });
    }

    fetch(url);
  });
}

// Parse @lat,lng from a Google Maps URL
function parseCoords(url) {
  const match = url.match(/@(-?\d+\.\d+),(-?\d+\.\d+)/);
  if (!match) return null;
  return { lat: parseFloat(match[1]), lng: parseFloat(match[2]) };
}

async function run() {
  console.log('\n📍 Branch Coordinate Extractor');
  console.log('══════════════════════════════════════\n');

  const [branches] = await db.execute(
    `SELECT branch_id, name, business_url
     FROM branches
     WHERE business_url IS NOT NULL
       AND (latitude IS NULL OR longitude IS NULL)
     ORDER BY branch_id ASC`
  );

  if (branches.length === 0) {
    console.log('✅  All branches already have coordinates. Nothing to do.');
    process.exit(0);
  }

  console.log(`Found ${branches.length} branch(es) with missing coordinates.\n`);

  let successCount = 0;
  let failCount    = 0;

  for (const branch of branches) {
    process.stdout.write(`[${branch.branch_id}] ${branch.name}\n    URL: ${branch.business_url}\n    → `);

    try {
      const finalUrl = await followRedirects(branch.business_url);
      const coords   = parseCoords(finalUrl);

      if (coords) {
        await db.execute(
          `UPDATE branches SET latitude = ?, longitude = ? WHERE branch_id = ?`,
          [coords.lat, coords.lng, branch.branch_id]
        );
        console.log(`✅  lat=${coords.lat}  lng=${coords.lng}`);
        successCount++;
      } else {
        console.log(`⚠️   coordinates not found in final URL:`);
        console.log(`    ${finalUrl}`);
        console.log(`    → Enter manually in phpMyAdmin for this branch.`);
        failCount++;
      }
    } catch (err) {
      console.log(`❌  ${err.message}`);
      failCount++;
    }

    console.log('');
    // Small delay between requests to avoid rate-limiting by Google
    await new Promise(r => setTimeout(r, 600));
  }

  console.log('══════════════════════════════════════');
  console.log(`Done — ✅ ${successCount} populated  ⚠️/❌ ${failCount} need manual entry`);
  process.exit(0);
}

run().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});
