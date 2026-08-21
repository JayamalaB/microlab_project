'use strict';
const crypto = require('crypto');

// Simple shared-secret guard for admin REST endpoints that are not JWT-protected.
// Caller must send:  X-Admin-Secret: <value of ADMIN_WEBHOOK_SECRET in .env>

module.exports = function adminSecret(req, res, next) {
  const secret = process.env.ADMIN_WEBHOOK_SECRET;
  if (!secret) {
    console.error('[adminSecret] ADMIN_WEBHOOK_SECRET not set in .env');
    return res.status(500).json({ success: false, message: 'Server misconfiguration' });
  }

  const provided = req.headers['x-admin-secret'];
  if (!provided) {
    console.warn(`[adminSecret] REJECTED — missing X-Admin-Secret header  path=${req.path}  ip=${req.ip}`);
    return res.status(403).json({ success: false, message: 'Admin secret missing' });
  }

  // Timing-safe compare to prevent length/timing side-channel leaks
  let match = false;
  try {
    match = crypto.timingSafeEqual(
      Buffer.from(provided, 'utf8'),
      Buffer.from(secret,   'utf8'),
    );
  } catch {
    match = false;
  }

  if (!match) {
    console.warn(`[adminSecret] REJECTED — wrong secret  path=${req.path}  ip=${req.ip}`);
    return res.status(403).json({ success: false, message: 'Invalid admin secret' });
  }

  next();
};
