const db = require('./db');

let _cache = {};

async function refresh() {
  try {
    const [rows] = await db.execute('SELECT setting_key, setting_value FROM ip_settings');
    const next = {};
    for (const row of rows) next[row.setting_key] = row.setting_value;
    _cache = next;
    console.log(`[settings] refreshed — ${rows.length} key(s)`);
  } catch (err) {
    console.error('[settings] refresh FAILED:', err.message);
  }
}

function get(key, defaultValue = null) {
  return key in _cache ? _cache[key] : defaultValue;
}

function getBool(key, defaultValue = false) {
  const val = get(key);
  if (val === null) return defaultValue;
  return val === 'true' || val === '1';
}

function getList(key, defaultValue = []) {
  const val = get(key);
  if (val === null || val === undefined) return defaultValue;
  return val.split(',').map(s => s.trim()).filter(Boolean);
}

async function init(intervalMs = 5 * 60 * 1000) {
  await refresh();
  setInterval(refresh, intervalMs);
}

module.exports = { init, refresh, get, getBool, getList };
