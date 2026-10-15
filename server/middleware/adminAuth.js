'use strict';
const crypto = require('crypto');
const { getActiveEncryptedValue } = require('../services/dynamicKeyService');

// Verifies that a request came from the CodeIgniter admin portal.
// Each request must include:
//   X-Admin-Signature : HMAC-SHA256( bookingId + "|" + timestamp, <active encrypted_value> )
//   X-Admin-Timestamp : unix timestamp (seconds)
//
// The 5-minute window blocks replay attacks — a captured request cannot be
// reused after the window expires.
//
// The HMAC secret is the active ADMIN_PORTAL_SECRET row's encrypted_value in
// ip_dynamic_keys, used exactly as stored — no decryption, no master key. The
// Admin Panel reads the same column and signs with the same string. Read on
// every request, after the cheap header/timestamp checks. It lives only in
// this function's scope — never logged, returned, or stored elsewhere.

module.exports = async function adminAuth(req, res, next) {
  const signature = req.headers['x-admin-signature'];
  const timestamp = req.headers['x-admin-timestamp'];

  if (!signature || !timestamp) {
    console.warn(`[adminAuth] REJECTED — missing headers  bookingId=${req.params.bookingId ?? '?'}  ip=${req.ip}`);
    return res.status(403).json({ success: false, message: 'Admin credentials missing' });
  }

  // Reject requests outside a 5-minute window
  const now = Math.floor(Date.now() / 1000);
  const ts  = parseInt(timestamp, 10);
  if (isNaN(ts) || Math.abs(now - ts) > 300) {
    console.warn(`[adminAuth] REJECTED — timestamp expired  bookingId=${req.params.bookingId ?? '?'}  ts=${timestamp}  diff=${now - ts}s  ip=${req.ip}`);
    return res.status(403).json({ success: false, message: 'Request timestamp expired' });
  }

  // Missing/expired/inactive row and DB errors all collapse to the same
  // external 500 (fail closed). Name/code only — never err.message, which
  // can carry query details.
  let secret;
  try {
    secret = await getActiveEncryptedValue('ADMIN_PORTAL_SECRET');
  } catch (err) {
    console.error(`[adminAuth] ADMIN_PORTAL_SECRET unavailable  error=${err.name}${err.code ? ` code=${err.code}` : ''}`);
    return res.status(500).json({ success: false, message: 'Server misconfiguration' });
  }

  // Recompute expected signature: HMAC-SHA256( bookingId|timestamp , encrypted_value )
  const bookingId = req.params.bookingId ?? '';
  const expected  = crypto
    .createHmac('sha256', secret)
    .update(`${bookingId}|${timestamp}`)
    .digest('hex');

  // Timing-safe comparison prevents side-channel timing attacks
  let match = false;
  try {
    match = crypto.timingSafeEqual(
      Buffer.from(signature, 'hex'),
      Buffer.from(expected,  'hex'),
    );
  } catch {
    match = false; // buffers differ in length → not equal
  }

  if (!match) {
    console.warn(`[adminAuth] REJECTED — signature mismatch  bookingId=${bookingId}  payload="${bookingId}|${timestamp}"  ip=${req.ip}`);
    return res.status(403).json({ success: false, message: 'Invalid admin signature' });
  }

  console.log(`[adminAuth] OK  bookingId=${bookingId}  ip=${req.ip}`);
  next();
};
