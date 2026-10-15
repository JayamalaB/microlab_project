// Builds real, validly-signed JWTs matching the exact payload shapes
// authController.js actually issues (confirmed by reading its two
// jwt.sign() call sites, not guessed) — technician tokens use `userId`,
// customer tokens use `user_id`.
//
// middleware/auth.js is session-aware: after verifying the signature, it
// queries ip_users for the CURRENT user_auth_token and rejects if the
// presented token doesn't match. So any test hitting a protected route
// needs BOTH a signed token from here AND the mocked db primed (via
// primeAuthCheck below) to say this token is the current one — otherwise
// every protected-route test fails in the middleware, before the
// controller under test ever runs.
const jwt = require('jsonwebtoken');

function technicianToken({ id = 17, userId = 501, mobile = '9000000001', branchId = 3 } = {}) {
  return jwt.sign(
    { id, userId, mobile, role: 'technician', branchId },
    process.env.JWT_SECRET,
    { expiresIn: '30d' }
  );
}

function customerToken({ id = 7001, userId = 4001, clientId = 2001, mobile = '9000000002' } = {}) {
  return jwt.sign(
    { id, user_id: userId, client_id: clientId, mobile, role: 'customer', user_type: 'patient_user' },
    process.env.JWT_SECRET,
    { expiresIn: '30d' }
  );
}

// Queues the mocked db.execute response for middleware/auth.js's own
// session-validity check (`SELECT user_auth_token FROM ip_users WHERE
// user_id = ?`). MUST be queued before whatever the controller itself will
// query, since this is always the first db call made on a protected route.
function primeAuthCheck(db, token) {
  db.execute.mockResolvedValueOnce([[{ user_auth_token: token }]]);
}

module.exports = { technicianToken, customerToken, primeAuthCheck };
