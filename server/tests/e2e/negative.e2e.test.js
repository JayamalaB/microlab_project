// Negative integration scenarios not already covered elsewhere in this
// suite. Many of the brief's negative cases ARE already covered by other
// e2e/unit files — see the final test report for the full cross-reference
// (wrong/expired OTP, duplicate acceptance, invalid auth, logged-out-token
// reuse, missing-field validation, etc.). This file adds the ones that
// specifically need the real server + real Socket.IO wire and aren't
// exercised anywhere else: a technician disconnecting mid-job, and an
// expired JWT reaching a protected route.
jest.mock('../../config/db');
jest.mock('../../config/firebase', () => ({ messaging: null }));
const db  = require('../../config/db');
const jwt = require('jsonwebtoken');
const { startRealServer } = require('../helpers/realServer');
const { connectClient, waitForEvent } = require('../helpers/socketServer');

let server;
beforeAll(async () => { server = await startRealServer(); });
afterAll(async () => { await server.close(); });

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
});

// Technician offline / network disconnected mid-job — the app should fail
// safely (patient told immediately) rather than leaving the customer
// waiting indefinitely on a technician who silently vanished.
test('a technician disconnecting mid-job notifies the customer immediately, without a crash', async () => {
  const bookingId = 80101;
  const tech    = await connectClient(server.url);
  const patient = await connectClient(server.url);
  try {
    tech.emit('technician_online', { technicianId: 501, technicianName: 'Suresh' });
    await waitForEvent(tech, 'session_started');

    // _notifyPatient broadcasts to io.to(String(bookingId)) — the patient
    // must actually be in that room to receive anything, same as every
    // other e2e test that listens for a patient-facing event.
    patient.emit('join_tracking', { trackingId: bookingId });
    await new Promise(r => setTimeout(r, 30));

    // Put this booking into technicianActiveBookings the same way a real
    // acceptance would (booking_accepted's own effect) — proven separately
    // in dispatch.e2e.test.js; here we only need the disconnect side effect,
    // so drive it the same real way: accept, then abruptly disconnect.
    const acceptedAtCustomer = waitForEvent(patient, 'booking_accepted');
    tech.emit('booking_accepted', { bookingId, technicianId: 501, technicianName: 'Suresh' });
    await acceptedAtCustomer;

    const cancelledAtCustomer = waitForEvent(patient, 'booking_cancelled');
    tech.disconnect(); // simulates network loss / app killed mid-job

    const cancelPayload = await cancelledAtCustomer;
    expect(cancelPayload).toMatchObject({ bookingId, reason: 'technician_disconnected' });
  } finally {
    patient.disconnect();
  }
});

// Expired authentication — a token that is syntactically valid but past its
// own expiry must be rejected the same as no token at all, on a real
// protected route over the real wire.
test('an expired JWT is rejected on a protected route', async () => {
  const expiredToken = jwt.sign(
    { id: 501, user_id: 501, client_id: 10, mobile: '9876543210', role: 'customer', user_type: 'patient_user' },
    process.env.JWT_SECRET, { expiresIn: '-1h' } // already expired
  );
  const res = await fetch(`${server.url}/api/bookings/mine`, {
    headers: { Authorization: `Bearer ${expiredToken}` },
  });
  expect(res.status).toBe(401);
  expect(db.execute).not.toHaveBeenCalled(); // rejected by JWT verification, before ever touching the session-check DB call
});

// Logged-out technician attempting a protected action — reusing a token
// whose session was already cleared (covered for the customer role in
// auth.logout.test.js; this proves the same guard for the technician role
// over the real wire).
test('a logged-out technician cannot generate a booking OTP with their old token', async () => {
  const techToken = jwt.sign(
    { id: 17, userId: 501, mobile: '9000000001', role: 'technician', branchId: 3 },
    process.env.JWT_SECRET, { expiresIn: '30d' }
  );
  db.execute.mockResolvedValueOnce([[{ user_auth_token: null }]]); // session already cleared by logout
  const res = await fetch(`${server.url}/api/technicians/booking-otp/generate`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${techToken}` },
    body: JSON.stringify({ bookingId: 900 }),
  });
  expect(res.status).toBe(401);
});
