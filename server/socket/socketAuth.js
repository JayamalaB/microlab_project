'use strict';
const jwt      = require('jsonwebtoken');
const db       = require('../config/db');
const settings = require('../config/settings');

// Login check for socket connections, the socket side of middleware/auth.js:
// a valid signature, and still the token on file for that user.
//
// Same rollout as middleware/rolloutAuth.js. Until ip_settings
// 'api_auth_required' is true, a connection with no valid token is allowed and
// logged, because the app already in people's hands sends none. Once it is
// true, such a connection is refused.

const authRequired = () => settings.getBool('api_auth_required', false);

async function _userFromToken(token) {
  if (!token) return null;
  try {
    const decoded = jwt.verify(token, process.env.JWT_SECRET);
    const [[row]] = await db.execute(
      'SELECT user_auth_token FROM ip_users WHERE user_id = ? LIMIT 1',
      [decoded.userId ?? decoded.user_id]
    );
    return row && row.user_auth_token === token ? decoded : null;
  } catch {
    return null;
  }
}

async function socketAuth(socket, next) {
  const user = await _userFromToken(socket.handshake.auth?.token);
  if (user) {
    socket.data.user = user;
    return next();
  }
  if (authRequired()) return next(new Error('unauthorized'));
  console.warn(`[AUTH_ROLLOUT] socket without a valid token — ip=${socket.handshake.address}`);
  next();
}

// Sent by the technician app. A customer's socket may never send these.
const TECHNICIAN_EVENTS = new Set([
  'technician_online', 'technician_heartbeat', 'technician_offline', 'update_technician_location',
  'booking_accepted', 'booking_rejected', 'check_pending_booking',
  'technician_en_route', 'technician_arrived', 'collection_started', 'collection_completed',
  'sample_collected', 'handed_to_lab',
]);

// Sent by the customer app for a booking on their own account.
const CUSTOMER_BOOKING_EVENTS = new Set(['booking_request', 'patient_cancel_search']);

async function _ownsBooking(user, bookingId) {
  const [rows] = await db.execute(
    'SELECT 1 FROM ip_bookings WHERE booking_id = ? AND client_id = ? LIMIT 1',
    [bookingId, user.client_id ?? null]
  );
  return rows.length > 0;
}

// Why this event must not run, or null when it may. A ride booking has its own
// ids, not ip_bookings rows, so only lab bookings are looked up.
async function _denyReason(user, event, data = {}) {
  const isTechnician = user.role === 'technician';

  if (event === 'register_user_socket') {
    return Number(data.userId) === Number(user.userId ?? user.user_id) ? null : 'another user';
  }
  if (TECHNICIAN_EVENTS.has(event)) {
    if (!isTechnician) return 'not a technician';
    if (data.technicianId != null && Number(data.technicianId) !== Number(user.id)) return 'another technician';
    return null;
  }
  if (CUSTOMER_BOOKING_EVENTS.has(event) && !isTechnician && data.bookingType !== 'transport') {
    return (await _ownsBooking(user, data.bookingId)) ? null : 'not their booking';
  }
  return null;
}

// Runs before every event handler on this socket. A refused event is dropped.
function guardEvents(socket) {
  socket.use(async ([event, data], next) => {
    const user = socket.data.user;
    if (!user) {
      if (!authRequired()) next();
      return;
    }
    try {
      const reason = await _denyReason(user, event, data ?? {});
      if (!reason) return next();
      console.warn(`[socketAuth] DROPPED ${event} — ${reason} (user=${user.userId ?? user.user_id})`);
    } catch (err) {
      console.error(`[socketAuth] check failed for ${event}: ${err.message}`);
    }
  });
}

module.exports = { socketAuth, guardEvents };
