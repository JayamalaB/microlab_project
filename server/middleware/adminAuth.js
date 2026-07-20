'use strict';
const crypto = require('crypto');

// Verifies that a request came from the CodeIgniter admin portal.
// Each request must include:
//   X-Admin-Signature : HMAC-SHA256( bookingId + "|" + timestamp, ADMIN_PORTAL_SECRET )
//   X-Admin-Timestamp : unix timestamp (seconds)
//
// The 5-minute window blocks replay attacks — a captured request cannot be
// reused after the window expires.

module.exports = function adminAuth(req, res, next) {
  const secret = process.env.ADMIN_PORTAL_SECRET;
  if (!secret) {
    console.error('[adminAuth] ADMIN_PORTAL_SECRET not set in .env');
    return res.status(500).json({ success: false, message: 'Server misconfiguration' });
  }

  const signature = req.headers['x-admin-signature'];
  const timestamp = req.headers['x-admin-timestamp'];

  if (!signature || !timestamp) {
    return res.status(403).json({ success: false, message: 'Admin credentials missing' });
  }

  // Reject requests outside a 5-minute window
  const now = Math.floor(Date.now() / 1000);
  const ts  = parseInt(timestamp, 10);
  if (isNaN(ts) || Math.abs(now - ts) > 300) {
    return res.status(403).json({ success: false, message: 'Request timestamp expired' });
  }

  // Recompute expected signature: HMAC-SHA256( bookingId|timestamp , ADMIN_PORTAL_SECRET )
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
    return res.status(403).json({ success: false, message: 'Invalid admin signature' });
  }

  next();
};
