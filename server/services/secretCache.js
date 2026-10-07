const db = require('../config/db');

// In-memory cache — seeded from .env on cold start, refreshed from DB on
// server launch and on every ASMX signature failure (auto-recovery).
let _secret = process.env.CLIENT_SERVER_SECRET || null;

async function refreshSecret() {
  try {
    const [[row]] = await db.execute(
      `SELECT new_secret FROM ip_key_rotations
       WHERE status = 'confirmed'
       ORDER BY rotation_id DESC LIMIT 1`
    );
    if (row?.new_secret) {
      _secret = row.new_secret;
      console.log('[secretCache] ✅ secret refreshed from ip_key_rotations');
    } else {
      console.warn('[secretCache] ⚠️  no confirmed key in ip_key_rotations — keeping current');
    }
  } catch (err) {
    console.error('[secretCache] ❌ refresh failed:', err.message);
  }
  return _secret;
}

// Returns cached secret; fetches from DB first time if cache is empty.
async function getSecret() {
  if (!_secret) await refreshSecret();
  return _secret;
}

module.exports = { getSecret, refreshSecret };
