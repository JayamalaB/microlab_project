'use strict';
const auth     = require('./auth');
const settings = require('../config/settings');

// Login check for routes the current app still calls without a token.
//
// A request with a token always goes through the full session check. A request
// without one is rejected only once ip_settings 'api_auth_required' is true;
// until then it is let through and logged, so an app version already in
// customers' hands keeps working while the new build rolls out. Those log lines
// also show what still calls without a token before the setting is turned on:
//   grep AUTH_ROLLOUT ~/server.out
module.exports = function rolloutAuth(req, res, next) {
  if (req.headers['authorization']?.startsWith('Bearer ')) return auth(req, res, next);

  if (settings.getBool('api_auth_required', false)) {
    return res.status(401).json({ success: false, message: 'Unauthorized' });
  }
  console.warn(`[AUTH_ROLLOUT] no token — ${req.method} ${req.originalUrl} ip=${req.ip}`);
  next();
};
