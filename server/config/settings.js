// Runtime settings with DB-backed overrides (falls back to defaults if table absent)
const db = require('./db');

let _cache = {};
let _loaded = false;

async function init() {
  try {
    const [rows] = await db.execute('SELECT setting_key, setting_value FROM ip_settings');
    rows.forEach(r => { _cache[r.setting_key] = r.setting_value; });
    _loaded = true;
    console.log(`[settings] loaded ${rows.length} setting(s) from DB`);
  } catch (_) {
    // Table may not exist yet — use defaults silently
    _loaded = true;
  }
}

function get(key, defaultValue = null) {
  return _cache.hasOwnProperty(key) ? _cache[key] : defaultValue;
}

function getBool(key, defaultValue = false) {
  if (!_cache.hasOwnProperty(key)) return defaultValue;
  const v = _cache[key];
  return v === true || v === 1 || v === '1' || v === 'true';
}

function getList(key, defaultValue = []) {
  if (!_cache.hasOwnProperty(key)) return defaultValue;
  try { return JSON.parse(_cache[key]); } catch (_) { return defaultValue; }
}

module.exports = { init, get, getBool, getList };
