const jwt = require('jsonwebtoken');
const db  = require('../config/db');
const sessions = require('../services/userSessions');

// Session-aware: a valid JWT signature alone is not enough — the token must
// also still be the one currently on file in ip_users.user_auth_token. This
// is what makes logout (or losing a single-active-session conflict at login,
// see authController.js: verifyOtp) actually invalidate a token immediately,
// instead of it staying usable for the rest of its 30-day signature validity.
//
// Technician tokens embed the ip_users row as `userId`; customer tokens embed
// it as `user_id` — confirmed directly from authController.js's two
// jwt.sign() call sites, not assumed.
module.exports = async (req, res, next) => {
  const authHeader = req.headers['authorization'];
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ success: false, message: 'Unauthorized' });
  }
  const token = authHeader.split(' ')[1];

  let decoded;
  try {
    decoded = jwt.verify(token, process.env.JWT_SECRET);
  } catch {
    return res.status(401).json({ success: false, message: 'Invalid token' });
  }

  // Compared with the session of the token's own role (services/userSessions),
  // so a customer login never invalidates the same person's technician login.
  try {
    if (!(await sessions.isCurrentToken(decoded, token, db))) {
      return res.status(401).json({ success: false, message: 'Session expired or logged in elsewhere. Please log in again.' });
    }
  } catch (err) {
    console.error('[auth middleware] session check failed:', err.message);
    return res.status(500).json({ success: false, message: 'Server error' });
  }

  req.user = decoded;
  next();
};
