'use strict';
const crypto = require('crypto');
const { getActiveEncryptedValue } = require('../services/dynamicKeyService');
const db = require('../config/db');

async function _logCall(req, authResult, httpStatus) {
  const { bill_id, report_status } = req.body ?? {};
  try {
    await db.execute(
      `INSERT INTO ip_report_status_log
         (bill_id, report_status, ip_address, auth_result, http_status)
       VALUES (?, ?, ?, ?, ?)`,
      [bill_id ?? null, report_status ?? null, req.ip ?? null, authResult, httpStatus]
    );
  } catch (e) {
    console.error('[adminBodyAuth] log insert failed:', e.message);
  }
}

// Verifies that a request came from the CodeIgniter admin portal.
// Used for endpoints whose signing payload lives in the request body
// (not req.params) — e.g. POST /api/bookings/report-status where bill_id
// is in the body, not the URL.
//
// Each request must include:
//   X-Admin-Signature : HMAC-SHA256( <bodyField> + "|" + timestamp, <active encrypted_value> )
//   X-Admin-Timestamp : unix timestamp (seconds)
//
// bodyField is the name of the req.body key used as the signing payload
// (e.g. 'bill_id'). Pass it when mounting the middleware:
//   router.post('/report-status', adminBodyAuth('bill_id'), handler)

module.exports = function adminBodyAuth(bodyField) {
  return async function (req, res, next) {
    const signature = req.headers['x-admin-signature'];
    const timestamp = req.headers['x-admin-timestamp'];

    if (!signature || !timestamp) {
      console.warn(`[adminBodyAuth] REJECTED — missing headers  path=${req.path}  ip=${req.ip}`);
      await _logCall(req, 'missing_headers', 403);
      return res.status(403).json({ success: false, message: 'Admin credentials missing' });
    }

    const now = Math.floor(Date.now() / 1000);
    const ts  = parseInt(timestamp, 10);
    if (isNaN(ts) || Math.abs(now - ts) > 300) {
      console.warn(`[adminBodyAuth] REJECTED — timestamp expired  path=${req.path}  ts=${timestamp}  diff=${now - ts}s  ip=${req.ip}`);
      await _logCall(req, 'timestamp_expired', 403);
      return res.status(403).json({ success: false, message: 'Request timestamp expired' });
    }

    let secret;
    try {
      secret = await getActiveEncryptedValue('ADMIN_PORTAL_SECRET');
    } catch (err) {
      console.error(`[adminBodyAuth] ADMIN_PORTAL_SECRET unavailable  error=${err.name}${err.code ? ` code=${err.code}` : ''}`);
      await _logCall(req, 'secret_unavailable', 500);
      return res.status(500).json({ success: false, message: 'Server misconfiguration' });
    }

    const fieldValue = req.body?.[bodyField] ?? '';
    const expected   = crypto
      .createHmac('sha256', secret)
      .update(`${fieldValue}|${timestamp}`)
      .digest('hex');

    let match = false;
    try {
      match = crypto.timingSafeEqual(
        Buffer.from(signature, 'hex'),
        Buffer.from(expected,  'hex'),
      );
    } catch {
      match = false;
    }

    if (!match) {
      console.warn(`[adminBodyAuth] REJECTED — signature mismatch  ${bodyField}=${fieldValue}  payload="${fieldValue}|${timestamp}"  ip=${req.ip}`);
      await _logCall(req, 'signature_mismatch', 403);
      return res.status(403).json({ success: false, message: 'Invalid admin signature' });
    }

    console.log(`[adminBodyAuth] OK  ${bodyField}=${fieldValue}  ip=${req.ip}`);
    next();
  };
};
