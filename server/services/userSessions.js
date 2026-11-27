'use strict';
// One login session per user PER ROLE (customer / technician), so one mobile
// number can use both the customer app and the technician app, each with its
// own token and push token. Still one device per number: a login while the
// other app is logged in on another device gets "Already logged in on another
// device as a technician/customer" and "Log out & continue", which ends that
// other login (authController.verifyOtp).
//
// Stored in ip_user_sessions (migrations/create_user_sessions.sql). The old
// single-session columns on ip_users (user_auth_token, is_logged_in,
// user_notification_token) are still written by authController as a mirror of
// the latest login, but are only READ here while ip_user_sessions doesn't
// exist yet. In that "legacy" mode everything behaves exactly as before:
// one session per number, technician numbers can't log in as customer.
//
// The table check is lazy: the first query that finds the table missing
// switches to legacy mode, and the table is looked for again after
// RECHECK_MS, so running the migration on a live server takes effect without
// a restart.

const db = require('../config/db');

const RECHECK_MS = 5 * 60 * 1000;
let legacyUntil = 0; // while Date.now() < legacyUntil, the table is treated as missing

const ROLES = ['customer', 'technician'];

/** 'technician' stays 'technician'; anything else is the customer app. */
function roleOf(role) {
  return role === 'technician' ? 'technician' : 'customer';
}

/** Role inside a decoded JWT. Technician tokens carry `userId`, customer tokens `user_id`. */
function roleOfToken(decoded) {
  if (decoded?.role) return roleOf(decoded.role);
  return decoded?.userId != null ? 'technician' : 'customer';
}

function isMissingSchema(err) {
  return !!err && (err.code === 'ER_NO_SUCH_TABLE' || err.errno === 1146
    || err.code === 'ER_BAD_FIELD_ERROR' || err.errno === 1054);
}

/** true once ip_user_sessions is in use (both roles can be logged in at once). */
function dualRoleEnabled() {
  return Date.now() >= legacyUntil;
}

function _markLegacy(err) {
  if (legacyUntil <= Date.now()) {
    console.warn(`[userSessions] ip_user_sessions not available (${err.code ?? err.message}) — `
      + 'using the single-session columns on ip_users until migrations/create_user_sessions.sql is run');
  }
  legacyUntil = Date.now() + RECHECK_MS;
}

// Runs `sql` against ip_user_sessions; when the table is missing, runs
// `legacySql` (or returns `legacyValue`) instead. `method` is 'execute' or
// 'query' so callers keep using the same db method they always did.
async function _run(exec, method, sql, params, legacySql, legacyParams, legacyValue) {
  if (dualRoleEnabled()) {
    try {
      return await exec[method](sql, params);
    } catch (err) {
      if (!isMissingSchema(err)) throw err;
      _markLegacy(err);
    }
  }
  if (legacySql) return exec[method](legacySql, legacyParams);
  return legacyValue;
}

/**
 * The "already logged in" message. It must start with "Already logged in on
 * another device" — the app looks for that text to offer "Log out & continue"
 * (client login_screen.dart / otp_screen.dart).
 */
function alreadyLoggedInMessage(otherAppRole = null) {
  const where = otherAppRole === 'technician' ? ' as a technician'
    : otherAppRole === 'customer' ? ' as a customer' : '';
  return `Already logged in on another device${where}. Tap "Log out & continue" to sign in here instead.`;
}

/** The other app's role: customer ↔ technician. */
function otherRoleOf(role) {
  return roleOf(role) === 'technician' ? 'customer' : 'technician';
}

/**
 * Whether a session row (or the other_* columns of one) is a live login.
 * Same OR rule the login guard has always used.
 */
function isActive(loggedIn, token) {
  return !!(loggedIn || token);
}

/**
 * The ip_users row for a login on [mobile], with the session columns for
 * [role] (is_logged_in, user_auth_token, user_token_expiry, role_closed_at)
 * and for the other app (other_is_logged_in, other_auth_token).
 * Same column names as the old ip_users-only SELECT.
 */
async function findUserForLogin(mobile, role, exec = db) {
  const r = roleOf(role);
  return _run(exec, 'query',
    `SELECT u.user_id, u.client_id, u.user_microlab_type, u.deleted_at,
            s.auth_token AS user_auth_token, s.token_expiry AS user_token_expiry,
            s.is_logged_in, s.closed_at AS role_closed_at,
            o.is_logged_in AS other_is_logged_in, o.auth_token AS other_auth_token
     FROM ip_users u
     LEFT JOIN ip_user_sessions s ON s.user_id = u.user_id AND s.role = ?
     LEFT JOIN ip_user_sessions o ON o.user_id = u.user_id AND o.role = ?
     WHERE u.user_mobile_no = ?`,
    [r, otherRoleOf(r), mobile],
    'SELECT user_id, client_id, user_microlab_type, user_auth_token, user_token_expiry, is_logged_in, deleted_at FROM ip_users WHERE user_mobile_no = ?',
    [mobile]);
}

/**
 * { is_logged_in, user_auth_token, closed_at } of [role]'s session, plus
 * { other_is_logged_in, other_auth_token } of the other app's, or undefined.
 */
async function sessionState(userId, role, exec = db) {
  const r = roleOf(role);
  const [[row]] = await _run(exec, 'query',
    `SELECT s.is_logged_in, s.auth_token AS user_auth_token, s.closed_at,
            o.is_logged_in AS other_is_logged_in, o.auth_token AS other_auth_token
     FROM ip_users u
     LEFT JOIN ip_user_sessions s ON s.user_id = u.user_id AND s.role = ?
     LEFT JOIN ip_user_sessions o ON o.user_id = u.user_id AND o.role = ?
     WHERE u.user_id = ? LIMIT 1`,
    [r, otherRoleOf(r), userId],
    'SELECT is_logged_in, user_auth_token FROM ip_users WHERE user_id = ? LIMIT 1',
    [userId]);
  return row;
}

/**
 * Whether [token] is still the current login for this user and role — the
 * check middleware/auth.js and socket/socketAuth.js make on every request.
 */
async function isCurrentToken(decoded, token, exec = db) {
  const userId = decoded.userId ?? decoded.user_id;
  const [[row]] = await _run(exec, 'execute',
    `SELECT auth_token AS user_auth_token
     FROM ip_user_sessions WHERE user_id = ? AND role = ? LIMIT 1`,
    [userId, roleOfToken(decoded)],
    'SELECT user_auth_token FROM ip_users WHERE user_id = ? LIMIT 1',
    [userId]);
  if (row) return row.user_auth_token === token;

  // No session row for this role (e.g. a login made in the moments between
  // deploying and running the migration): fall back to the ip_users column.
  if (!dualRoleEnabled()) return false;
  const [[legacy]] = await exec.execute(
    'SELECT user_auth_token FROM ip_users WHERE user_id = ? LIMIT 1', [userId]);
  return !!legacy && legacy.user_auth_token === token;
}

/** Stores a new login for [role]. ip_users is updated separately by the caller. */
async function saveLogin(userId, role, token, expiry, exec = db) {
  await _run(exec, 'query',
    `INSERT INTO ip_user_sessions (user_id, role, auth_token, token_expiry, is_logged_in)
     VALUES (?, ?, ?, ?, 1)
     ON DUPLICATE KEY UPDATE auth_token = VALUES(auth_token),
                             token_expiry = VALUES(token_expiry),
                             is_logged_in = 1`,
    [userId, roleOf(role), token, expiry]);
}

/** Ends [role]'s login only — the other app stays logged in. */
async function clearLogin(userId, role, exec = db) {
  if (userId == null) return;
  await _run(exec, 'query',
    `UPDATE ip_user_sessions
     SET auth_token = NULL, token_expiry = NULL, is_logged_in = 0
     WHERE user_id = ? AND role = ?`,
    [userId, roleOf(role)]);
}

/** Ends the technician login for [technicianId] (admin / technician logout routes). */
async function clearTechnicianLogin(technicianId, exec = db) {
  await _run(exec, 'query',
    `UPDATE ip_user_sessions s
     JOIN ip_technicians t ON t.user_id = s.user_id
     SET s.auth_token = NULL, s.token_expiry = NULL, s.is_logged_in = 0
     WHERE t.technician_id = ? AND s.role = 'technician'`,
    [technicianId]);
}

/** Saves this app's push token against [role]. */
async function saveFcmToken(userId, role, fcmToken, exec = db) {
  await _run(exec, 'query',
    `INSERT INTO ip_user_sessions (user_id, role, fcm_token)
     VALUES (?, ?, ?)
     ON DUPLICATE KEY UPDATE fcm_token = VALUES(fcm_token)`,
    [userId, roleOf(role), fcmToken]);
}

/**
 * Closes the customer side of an account that is also a technician: the
 * customer login ends and the number can't log in to the customer app again,
 * while the technician login keeps working. Returns false in legacy mode
 * (the caller then deletes the whole account, as before).
 */
async function closeCustomerSide(userId, exec = db) {
  if (!dualRoleEnabled()) return false;
  try {
    await exec.query(
      `INSERT INTO ip_user_sessions (user_id, role, is_logged_in, closed_at)
       VALUES (?, 'customer', 0, NOW())
       ON DUPLICATE KEY UPDATE auth_token = NULL, token_expiry = NULL,
                               is_logged_in = 0, fcm_token = NULL, closed_at = NOW()`,
      [userId]);
    return true;
  } catch (err) {
    if (!isMissingSchema(err)) throw err;
    _markLegacy(err);
    return false;
  }
}

/**
 * Runs `sql`; if it fails because a column/table from a not-yet-run migration
 * is missing, runs `legacySql` instead. For queries outside this module that
 * join ip_user_sessions or use a new column.
 */
async function withSchemaFallback(exec, method, sql, params, legacySql, legacyParams = params) {
  try {
    return await exec[method](sql, params);
  } catch (err) {
    if (!isMissingSchema(err)) throw err;
    return exec[method](legacySql, legacyParams);
  }
}

// ── Push token SQL ───────────────────────────────────────────────────────────
// For queries that already join ip_users as `u`. Each app's own token from
// ip_user_sessions first; then the old ip_users column, unless that column
// holds the OTHER app's token (last app to register wins there). Use with
// withSchemaFallback, keeping the old SQL as the legacy query.
const PUSH_TOKEN_JOINS = `
       LEFT JOIN ip_user_sessions us_t ON us_t.user_id = u.user_id AND us_t.role = 'technician'
       LEFT JOIN ip_user_sessions us_c ON us_c.user_id = u.user_id AND us_c.role = 'customer'`;
const TECHNICIAN_PUSH_TOKEN = `COALESCE(us_t.fcm_token,
         CASE WHEN us_c.fcm_token IS NULL OR us_c.fcm_token <> u.user_notification_token
              THEN u.user_notification_token END)`;
const CUSTOMER_PUSH_TOKEN = `COALESCE(us_c.fcm_token,
         CASE WHEN us_t.fcm_token IS NULL OR us_t.fcm_token <> u.user_notification_token
              THEN u.user_notification_token END)`;

module.exports = {
  PUSH_TOKEN_JOINS,
  TECHNICIAN_PUSH_TOKEN,
  CUSTOMER_PUSH_TOKEN,
  ROLES,
  roleOf,
  otherRoleOf,
  isActive,
  alreadyLoggedInMessage,
  roleOfToken,
  dualRoleEnabled,
  isMissingSchema,
  findUserForLogin,
  sessionState,
  isCurrentToken,
  saveLogin,
  clearLogin,
  clearTechnicianLogin,
  saveFcmToken,
  closeCustomerSide,
  withSchemaFallback,
  _resetForTests: () => { legacyUntil = 0; },
};
