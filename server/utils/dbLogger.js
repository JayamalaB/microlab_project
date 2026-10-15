// dbLogger.js
//
// Additive database copies of 7 existing .log files. Every existing logger
// function (dlog/clog/otpLog/tlog/writeLog in bookingSocket.js,
// technicianController.js, authController.js, clientSync.js, customerPush.js)
// keeps writing to its .log file exactly as before — this module is called
// ONE extra time, alongside that unchanged file write, never instead of it.
//
// Design:
//   - ip_dispatch_logs / ip_collection_logs (hot-path, see bookingSocket.js's
//     dispatchAttempt/_handleBookingRequest and the 3-handler technician
//     journey) are BUFFERED: rows are held in memory and flushed as one
//     multi-row INSERT every FLUSH_INTERVAL_MS or FLUSH_SIZE rows, whichever
//     comes first. The connection pool (config/db.js) is only
//     connectionLimit: 10, shared with every real booking/payment/auth
//     query — inserting once per log line on the dispatch hot path would add
//     real contention to that same pool during exactly the traffic this
//     session's dispatch fix was protecting.
//   - The other 5 tables use a direct, fire-and-forget insert (same
//     fire-and-forget shape as bookingSocket.js's own dbRun()) — one request
//     produces a handful of lines, not a retry loop, so there's no hot-path
//     risk to buffer against.
//
// None of this ever throws into the caller — every entry point is wrapped so
// a logging failure (bad regex match, DB error, pool exhaustion) can never
// break the application flow that triggered the log line.
const db = require('../config/db');

// ── ID / field extraction — best effort only ──────────────────────────────
// None of the 7 existing logger functions receive structured fields (they
// all just take a single pre-formatted message string) — these regexes pull
// booking_id/technician_id/etc. back out of that text. A miss just leaves
// the column NULL; the full message is always stored regardless, so no data
// is ever lost, only a secondary index.
function extractId(text, keys) {
  if (!text) return null;
  const s = String(text);
  for (const key of keys) {
    const re = new RegExp(`\\b${key}\\s*[:=]\\s*"?(\\d+)`, 'i');
    const m = s.match(re);
    if (m) return parseInt(m[1], 10);
  }
  return null;
}
const BOOKING_KEYS = ['booking_id', 'bookingId', 'booking'];
const TECH_KEYS    = ['technician_id', 'technicianId', 'tech_id', 'techId'];
const USER_KEYS    = ['user_id', 'userId'];

function extractBookingId(text)    { return extractId(text, BOOKING_KEYS); }
function extractTechnicianId(text) { return extractId(text, TECH_KEYS); }
function extractUserId(text)       { return extractId(text, USER_KEYS); }

// First [BRACKETED] tag at the start of a message, e.g. "[GENERATE] ..." → "GENERATE"
function extractBracketTag(text) {
  if (!text) return null;
  const m = String(text).match(/^\[(\w+)\]/);
  return m ? m[1] : null;
}

function inferLevel(text) {
  if (!text) return 'info';
  if (/❌|ERROR|FAILED/i.test(text)) return 'error';
  if (/⚠️|WARNING|WARN|GUARD FAILED/i.test(text)) return 'warn';
  return 'info';
}

// ── Mobile masking ──────────────────────────────────────────────────────
// Indian 10-digit mobile numbers (6-9 leading digit). Any raw mobile found
// inside a message is masked in-place before the message is ever stored —
// not just pulled into a separate column — so the stored text itself never
// carries a usable raw number, regardless of which of the 90+ existing call
// sites produced it.
const MOBILE_RE = /\b([6-9]\d{9})\b/;
const MOBILE_RE_G = /\b([6-9]\d{9})\b/g;

function maskMobile(mobile) {
  if (!mobile) return null;
  const s = String(mobile);
  return s.length >= 10 ? `${'*'.repeat(6)}${s.slice(-4)}` : '****';
}
function extractMaskedMobile(text) {
  if (!text) return null;
  const m = String(text).match(MOBILE_RE);
  return m ? maskMobile(m[1]) : null;
}
function maskMobilesInText(text) {
  if (!text) return text;
  return String(text).replace(MOBILE_RE_G, (raw) => maskMobile(raw));
}

// ── Test-environment guard ─────────────────────────────────────────────────
// Every one of the 7 integration points (dlog/clog/otpLog/tlog/writeLog) is
// exercised by dozens of existing e2e/unit tests that mock config/db and
// drive it with db.execute.mockResolvedValueOnce(...) sequences tailored to
// the business-logic calls those tests already make. If dbLogger's own
// fire-and-forget db.execute() calls shared that exact same mock, they would
// silently consume slots from those queues and shift every later mocked
// response out of sequence — breaking existing, unrelated tests in ways
// that have nothing to do with logging. Jest sets NODE_ENV=test
// automatically (confirmed for this project's own `npm test`), so real DB
// log writes are skipped there by default; dbLogger's own dedicated tests
// explicitly re-enable this via _setEnabledForTesting(true) in an isolated
// test file that sets up its own db.execute mock just for that purpose.
let dbLoggingEnabled = process.env.NODE_ENV !== 'test';
function _setEnabledForTesting(enabled) { dbLoggingEnabled = enabled; }

// ── Direct, fire-and-forget insert (the 5 low/medium-frequency tables) ───
function insertLog(table, columns, values) {
  if (!dbLoggingEnabled) return;
  try {
    const placeholders = columns.map(() => '?').join(',');
    db.execute(
      `INSERT INTO ${table} (${columns.join(',')}) VALUES (${placeholders})`,
      values
    ).catch(e => console.error(`[dbLogger] INSERT ${table} failed: ${e.message}`));
  } catch (e) {
    console.error(`[dbLogger] insertLog(${table}) threw: ${e.message}`);
  }
}

// ── Buffered writer (ip_dispatch_logs, ip_collection_logs) ───────────────
const FLUSH_INTERVAL_MS = 2000;
const FLUSH_SIZE        = 200;
const buffers = new Map(); // table -> { columns, rows: [][] }

function bufferLog(table, columns, values) {
  if (!dbLoggingEnabled) return;
  try {
    if (!buffers.has(table)) buffers.set(table, { columns, rows: [] });
    const buf = buffers.get(table);
    buf.rows.push(values);
    if (buf.rows.length >= FLUSH_SIZE) flushTable(table);
  } catch (e) {
    console.error(`[dbLogger] bufferLog(${table}) threw: ${e.message}`);
  }
}

function flushTable(table) {
  const buf = buffers.get(table);
  if (!buf || buf.rows.length === 0) return;
  const rows = buf.rows.splice(0, buf.rows.length);
  try {
    const rowPlaceholder = `(${buf.columns.map(() => '?').join(',')})`;
    const placeholders    = rows.map(() => rowPlaceholder).join(',');
    const flatValues      = rows.flat();
    db.execute(
      `INSERT INTO ${table} (${buf.columns.join(',')}) VALUES ${placeholders}`,
      flatValues
    ).catch(e => console.error(`[dbLogger] BATCH INSERT ${table} failed (${rows.length} rows): ${e.message}`));
  } catch (e) {
    console.error(`[dbLogger] flushTable(${table}) threw: ${e.message}`);
  }
}

function flushAll() {
  for (const table of buffers.keys()) flushTable(table);
}

const flushTimer = setInterval(flushAll, FLUSH_INTERVAL_MS);
flushTimer.unref(); // never keep the process alive just for this timer

process.on('SIGTERM', flushAll);
process.on('SIGINT', flushAll);

// ── Per-table entry points ────────────────────────────────────────────────
// One dedicated function per log, called from exactly one place: the
// existing logger function it mirrors. Each assembles that table's real
// columns from the already-formatted message text.

// bookingSocket.js dlog(bookingId, tag, details) — bookingId/tag are already
// reliable parameters there, passed straight through (no extraction needed).
function logDispatchEvent(bookingId, tag, details) {
  try {
    bufferLog('ip_dispatch_logs',
      ['booking_id', 'tag', 'details'],
      [bookingId ?? null, String(tag).slice(0, 30), maskMobilesInText(details) ?? null]);
  } catch (_) {}
}

function logCollectionEvent(message) {
  try {
    const safe = maskMobilesInText(message);
    bufferLog('ip_collection_logs',
      ['booking_id', 'technician_id', 'event', 'level', 'message'],
      [extractBookingId(message), extractTechnicianId(message),
       extractBracketTag(message), inferLevel(message), safe]);
  } catch (_) {}
}

function logOtpInfoEvent(message) {
  try {
    const safe = maskMobilesInText(message);
    insertLog('ip_otpinfo_logs',
      ['booking_id', 'technician_id', 'event', 'mobile_masked', 'level', 'message'],
      [extractBookingId(message), extractTechnicianId(message),
       extractBracketTag(message), extractMaskedMobile(message), inferLevel(message), safe]);
  } catch (_) {}
}

function logTechnicianEvent(message) {
  try {
    const safe = maskMobilesInText(message);
    insertLog('ip_technician_logs',
      ['technician_id', 'booking_id', 'event', 'level', 'message'],
      [extractTechnicianId(message), extractBookingId(message),
       extractBracketTag(message), inferLevel(message), safe]);
  } catch (_) {}
}

// authController.js writeLog() — the OTP value itself must never reach this
// function in the first place (the one call site that used to embed it has
// been edited separately to stop doing so); this function additionally
// never assumes that and masks every mobile found regardless.
function logOtpEvent(message) {
  try {
    const safe = maskMobilesInText(message);
    const bracketTag = extractBracketTag(message); // "[sendOtp]" / "[verifyOtp]"
    // ip_login_otp_logs, not ip_otp_logs — this schema already has an
    // unrelated, pre-existing ip_otp_logs table; see
    // migrations/create_log_tables.sql for the full explanation.
    insertLog('ip_login_otp_logs',
      ['user_id', 'mobile_masked', 'event', 'level', 'message'],
      [extractUserId(message), extractMaskedMobile(message), bracketTag, inferLevel(message), safe]);
  } catch (_) {}
}

function logClientSyncEvent(message) {
  try {
    const safe = maskMobilesInText(message);
    const typeMatch   = String(message).match(/\btype=(\w+)/i);
    const actionMatch = String(message).match(/\baction=(\w+)/i);
    insertLog('ip_client_sync_logs',
      ['booking_id', 'technician_id', 'initiator_type', 'action', 'level', 'message'],
      [extractBookingId(message), extractTechnicianId(message),
       typeMatch ? typeMatch[1] : null, actionMatch ? actionMatch[1] : null,
       inferLevel(message), safe]);
  } catch (_) {}
}

function logCustomerPushEvent(message) {
  try {
    const safe = maskMobilesInText(message);
    const titleMatch = String(message).match(/title="([^"]+)"/);
    let status = null;
    if (/✅|sent/i.test(message)) status = 'sent';
    else if (/❌|failed/i.test(message)) status = 'failed';
    else if (/skipped/i.test(message)) status = 'skipped';
    insertLog('ip_customer_push_logs',
      ['booking_id', 'mobile_masked', 'title', 'status', 'message'],
      [extractBookingId(message), extractMaskedMobile(message),
       titleMatch ? titleMatch[1].slice(0, 100) : null, status, safe]);
  } catch (_) {}
}

module.exports = {
  // per-table entry points — what the 7 logger functions call
  logDispatchEvent, logCollectionEvent, logOtpInfoEvent, logTechnicianEvent,
  logOtpEvent, logClientSyncEvent, logCustomerPushEvent,
  // exposed for tests / retention sweep / shutdown handling
  insertLog, bufferLog, flushTable, flushAll, _setEnabledForTesting,
  maskMobile, maskMobilesInText, extractBookingId, extractTechnicianId,
};
