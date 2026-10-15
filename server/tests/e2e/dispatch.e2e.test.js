// IT-T003 — Technician Receives Booking, IT-T004 — Technician Accepts
// Booking, IT-T005 — Concurrent Technician Acceptance.
//
// The real pipeline this proves, traced from actual source before writing
// anything here: the customer app creates a booking over REST (POST
// /api/bookings), then its own socket emits 'booking_request' directly
// (screens/customer/home_collection_booking_screen.dart:8, confirmed by
// reading it) — booking creation itself does NOT auto-dispatch. The server
// (_handleBookingRequest → dispatchAttempt in socket/bookingSocket.js) then
// pushes 'booking_request' to the nearest available online technician's own
// socket. Acceptance runs through the same acceptedBookings-Set race guard
// already proven in tests/socket/bookingDispatch.test.js — this file proves
// it end-to-end starting from a REAL REST-created booking instead of a bare
// socket event, and adds the DB-write assertions IT-T004 asks for.
//
// Given how many distinct queries the real dispatch pipeline makes (traced
// through _handleBookingRequest → dispatchAttempt), this file uses a SQL-
// pattern-matching mockImplementation for db.execute instead of a strict
// mockResolvedValueOnce() chain — the simpler style used elsewhere in this
// suite doesn't scale to a function with this many conditional branches
// without becoming unreadably fragile. Every pattern below is grounded in
// an actual query read from the source, not guessed.
jest.mock('../../config/db');
jest.mock('../../config/firebase', () => ({ messaging: null }));
jest.mock('../../services/clientSync');
const db         = require('../../config/db');
const clientSync = require('../../services/clientSync');
const jwt        = require('jsonwebtoken');
const { startRealServer } = require('../helpers/realServer');
const { createMockConnection } = require('../helpers/mockConnection');
const { connectClient, waitForEvent } = require('../helpers/socketServer');

let server;
beforeAll(async () => { server = await startRealServer(); });
afterAll(async () => { await server.close(); });

const custToken = jwt.sign(
  { id: 501, user_id: 501, client_id: 10, mobile: '9876543210', role: 'customer', user_type: 'patient_user' },
  process.env.JWT_SECRET, { expiresIn: '30d' }
);

// Smart default: answers every db.execute call by matching the query text
// against the real patterns _handleBookingRequest/dispatchAttempt use, so
// this file doesn't have to hand-sequence dozens of mockResolvedValueOnce
// calls across a deeply branching dispatch function.
function installDispatchDbDefaults() {
  db.execute.mockImplementation((sql) => {
    if (sql.includes('SELECT booking_date FROM ip_bookings')) {
      return Promise.resolve([[{ booking_date: new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }) }]]);
    }
    if (sql.includes('ip_patient_tracking_metadata')) return Promise.resolve([{}]);
    if (sql.includes('document_required')) return Promise.resolve([[{ doc_required: 0 }]]);
    return Promise.resolve([[], {}]);
  });
}

beforeEach(() => {
  db.execute.mockReset(); // must come before installDispatchDbDefaults sets the base impl
  db.query.mockReset().mockResolvedValue([[], {}]);
  db.getConnection.mockReset();
  clientSync.syncBookingToClient.mockReset().mockResolvedValue({ success: true });
  installDispatchDbDefaults();
});

async function createRealBooking(bookingId) {
  // Primed here, immediately before the actual REST call — not earlier in
  // the test — because db.execute is a single shared mock queue consumed in
  // real execution order. Anything that ran before this (e.g.
  // technician_online's own db.execute calls) would otherwise eat this
  // value first. See this file's own IT-T003 fix history.
  db.execute.mockResolvedValueOnce([[{ user_auth_token: custToken }]]);
  const conn = createMockConnection();
  db.getConnection.mockResolvedValue(conn);
  conn.execute
    .mockResolvedValueOnce([[{ patient_id_ref: null }]])
    .mockResolvedValueOnce([{ insertId: bookingId }])
    .mockResolvedValueOnce([{}])
    .mockResolvedValueOnce([[{ product_id: 7, product_name: 'CBC', document_required: 0 }]])
    .mockResolvedValueOnce([{ insertId: 1 }])
    .mockResolvedValueOnce([{}]);

  const res = await fetch(`${server.url}/api/bookings`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${custToken}` },
    body: JSON.stringify({
      patientId: 501, totalAmount: 878, paymentType: 'pay_later',
      // lab_visit — these dispatch tests are about technician
      // matching/acceptance, not Home Collection fare (see
      // bookings.createBooking.test.js's own "Home Collection fare" tests
      // for that); opting out of the 'home_collection' default keeps this
      // helper's original, simpler mock sequence valid.
      bookingType: 'lab_visit',
      collectionAddress: '12 MG Road', collectionLatitude: 13.05, collectionLongitude: 80.25,
      items: [{ packageId: 7, originalPrice: 878, finalPrice: 878 }],
    }),
  });
  expect(res.status).toBe(201);
  const body = await res.json();
  expect(body.bookingId).toBe(bookingId);
  return body;
}

describe('IT-T003 — Technician Receives Booking (real REST + real Socket.IO)', () => {
  test('a customer-created booking is pushed to the one online technician as booking_request', async () => {
    const tech = await connectClient(server.url);
    try {
      tech.emit('technician_online', { technicianId: 501, technicianName: 'Suresh', lat: 13.05, lng: 80.25 });
      await waitForEvent(tech, 'session_started');

      const booking = await createRealBooking(70101);

      const requestPromise = waitForEvent(tech, 'booking_request');
      // The customer app's own socket now emits booking_request directly
      // (not another REST call) — the exact pipeline read from
      // home_collection_booking_screen.dart + socket_service.dart.
      const patient = await connectClient(server.url);
      patient.emit('booking_request', {
        bookingId: booking.bookingId, patientId: 501, patientName: 'Ravi Kumar',
        patientMobile: '9876543210', patientAddress: '12 MG Road',
        patientLat: 13.05, patientLng: 80.25, hospital: 'Microlab Chennai',
      });

      const received = await requestPromise;
      expect(received.bookingId).toBe(booking.bookingId);
      expect(received.patientName).toBe('Ravi Kumar');
      expect(received.docRequired).toBe(false);
      patient.disconnect();
    } finally {
      tech.disconnect();
    }
  });

});

// IT-T006 — Business-rule change: a technician with an existing,
// time-overlapping committed booking must still receive a NEW booking
// request for an overlapping time — the exclusion was removed from
// bookingSocket.js (5 sites); the technician now decides via accept/reject
// instead of being silently skipped. Proven directly against
// technicianActiveSlots (the exact data _hasSlotConflict reads) rather than
// via a full prior accept-flow, since that Map is the one piece of state
// that actually represents "this technician already has a committed job".
describe('IT-T006 — Overlapping booking is still offered (business-rule change)', () => {
  const { technicianActiveSlots } = require('../../services/branchEligibility');

  afterEach(() => {
    technicianActiveSlots.delete(501); // this Map is a module-level singleton — don't leak into other tests
  });

  test('a technician with a 4:00 PM committed booking still receives a request for 4:30 PM', async () => {
    const todayIST = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });

    const tech = await connectClient(server.url);
    try {
      tech.emit('technician_online', { technicianId: 501, technicianName: 'Suresh', lat: 13.05, lng: 80.25 });
      await waitForEvent(tech, 'session_started');

      // Simulate Technician A already holding an accepted 4:00 PM–5:00 PM
      // booking (960–1020 minutes since midnight) — exactly the data
      // _hasSlotConflict would have used to exclude them before this change.
      technicianActiveSlots.set(501, new Map([
        [70199, { slotDate: todayIST, startMinutes: 960, endMinutes: 1020, slotId: 55 }],
      ]));

      const booking = await createRealBooking(70102);

      const requestPromise = waitForEvent(tech, 'booking_request');
      const patient = await connectClient(server.url);
      // New booking requested at 4:30 PM (990 min) — squarely inside the
      // 4:00–5:00 PM window seeded above.
      patient.emit('booking_request', {
        bookingId: booking.bookingId, patientId: 501, patientName: 'Ravi Kumar',
        patientMobile: '9876543210', patientAddress: '12 MG Road',
        patientLat: 13.05, patientLng: 80.25, hospital: 'Microlab Chennai',
        slotId: 56, appointmentTime: '16:30',
      });

      // Old behavior would have silently skipped Technician A here and the
      // booking would have timed out with nobody online to offer it to —
      // this resolving at all (not timing out) is the proof.
      const received = await requestPromise;
      expect(received.bookingId).toBe(booking.bookingId);
      expect(received.appointmentTime).toBe('16:30');
      patient.disconnect();
    } finally {
      tech.disconnect();
    }
  });
});

// The "nobody online" negative case lives in its own file
// (dispatch.noTechniciansOnline.e2e.test.js) — see that file's header for
// why: bookingSocket.js's onlineTechnicians/fcmOnlineTechnicians Maps are
// module-private state shared for this WHOLE FILE (Jest isolates module
// registries per test file, not per describe block or per
// startRealServer() call), and every other test here puts a technician
// online in that same shared module instance.

describe('IT-T004 — Technician Accepts Booking (real wire)', () => {
  test('accepting notifies the customer and writes the real assignment to the database', async () => {
    const tech    = await connectClient(server.url);
    const patient = await connectClient(server.url);
    try {
      tech.emit('technician_online', { technicianId: 501, technicianName: 'Suresh', lat: 13.05, lng: 80.25 });
      await waitForEvent(tech, 'session_started');

      const booking = await createRealBooking(70103);
      const bookingRequest = waitForEvent(tech, 'booking_request');
      patient.emit('booking_request', {
        bookingId: booking.bookingId, patientId: 501, patientName: 'Ravi Kumar',
        patientLat: 13.05, patientLng: 80.25, hospital: 'Microlab Chennai',
      });
      await bookingRequest;

      const acceptedAtCustomer = waitForEvent(patient, 'booking_accepted');
      tech.emit('booking_accepted', { bookingId: booking.bookingId, technicianId: 501, technicianName: 'Suresh' });
      const custPayload = await acceptedAtCustomer;

      // Customer UI result
      expect(custPayload.technicianId).toBe(501);
      // Database result: the booking is really assigned to this technician.
      const bookingsUpdate = db.execute.mock.calls.find(c =>
        c[0].includes('UPDATE ip_bookings') && c[0].includes("status = 'assigned'"));
      expect(bookingsUpdate).toBeDefined();
      expect(bookingsUpdate[1]).toEqual(expect.arrayContaining([501, 'Suresh', booking.bookingId]));
    } finally {
      tech.disconnect();
      patient.disconnect();
    }
  });
});

describe('IT-T005 — Concurrent Technician Acceptance (two real technicians)', () => {
  test('two technicians both try to accept the same booking — only one wins, verified end to end from a real booking', async () => {
    const techA   = await connectClient(server.url);
    const techB   = await connectClient(server.url);
    const patient = await connectClient(server.url);
    try {
      techA.emit('technician_online', { technicianId: 501, technicianName: 'Suresh', lat: 13.05, lng: 80.25 });
      await waitForEvent(techA, 'session_started');
      techB.emit('technician_online', { technicianId: 502, technicianName: 'Meena', lat: 13.06, lng: 80.26 });
      await waitForEvent(techB, 'session_started');

      const booking = await createRealBooking(70104);
      const requestAtA = waitForEvent(techA, 'booking_request'); // A is nearer — dispatched first
      patient.emit('booking_request', {
        bookingId: booking.bookingId, patientId: 501, patientName: 'Ravi Kumar',
        patientLat: 13.05, patientLng: 80.25, hospital: 'Microlab Chennai',
      });
      await requestAtA;

      const winnerNotified = waitForEvent(patient, 'booking_accepted');
      techA.emit('booking_accepted', { bookingId: booking.bookingId, technicianId: 501, technicianName: 'Suresh' });
      const winner = await winnerNotified;
      expect(winner.technicianId).toBe(501);

      // B never received a dispatch (queue only had A queued first — sequential
      // dispatch, not broadcast), but even if it HAD, the same acceptedBookings
      // guard proven in tests/socket/bookingDispatch.test.js blocks a second
      // accept for the same bookingId. Prove that directly here too, starting
      // from this real booking:
      let secondNotification = false;
      patient.once('booking_accepted', () => { secondNotification = true; });
      techB.emit('booking_accepted', { bookingId: booking.bookingId, technicianId: 502, technicianName: 'Meena' });
      await new Promise(r => setTimeout(r, 150));
      expect(secondNotification).toBe(false);

      // Final DB state: only one technician_id ends up written for this booking.
      const finalAssignCalls = db.execute.mock.calls.filter(c =>
        c[0].includes('UPDATE ip_bookings') && c[0].includes("status = 'assigned'"));
      expect(finalAssignCalls).toHaveLength(1);
      expect(finalAssignCalls[0][1]).toEqual(expect.arrayContaining([501]));
    } finally {
      techA.disconnect();
      techB.disconnect();
      patient.disconnect();
    }
  });
});

// IT-T007 — total_attempts bug fix: the attempt number persisted to
// ip_booking_requests must come from dispatch.attemptNum (the already-correct
// in-memory per-technician counter), not the old self-referential SQL IF(...)
// that silently never reset on a technician change (see bookingSocket.js's
// own comment on the INSERT/ON DUPLICATE KEY UPDATE for the exact MySQL
// evaluation-order bug this replaces).
//
// This proves the reset-on-technician-switch behavior — the part that was
// actually broken — using real reject events (fast, deterministic). It
// deliberately does NOT wait out a real same-technician timeout retry
// (TIMEOUT_MS=40s, RETRY_GAP_MS=3s, both hardcoded with no test seam, and
// out of scope to change here) to prove the increment case too; that part
// of dispatch.attemptNum's own logic is untouched by this fix (per explicit
// instruction) and was already correct before it — this test only needs to
// prove the value it already produces is now what actually gets persisted.
describe('IT-T007 — Attempt number resets per technician (total_attempts bug fix)', () => {
  test('three different technicians, in sequence, are each persisted as attempt 1 — never a running total', async () => {
    const techA   = await connectClient(server.url);
    const techB   = await connectClient(server.url);
    const techC   = await connectClient(server.url);
    const patient = await connectClient(server.url);
    try {
      techA.emit('technician_online', { technicianId: 501, technicianName: 'Suresh', lat: 13.05, lng: 80.25 });
      await waitForEvent(techA, 'session_started');
      techB.emit('technician_online', { technicianId: 502, technicianName: 'Meena', lat: 13.06, lng: 80.26 });
      await waitForEvent(techB, 'session_started');
      techC.emit('technician_online', { technicianId: 503, technicianName: 'Kumar', lat: 13.07, lng: 80.27 });
      await waitForEvent(techC, 'session_started');

      const booking = await createRealBooking(70105);

      // A — nearest, dispatched first.
      const requestAtA = waitForEvent(techA, 'booking_request');
      patient.emit('booking_request', {
        bookingId: booking.bookingId, patientId: 501, patientName: 'Ravi Kumar',
        patientLat: 13.05, patientLng: 80.25, hospital: 'Microlab Chennai',
      });
      await requestAtA;
      techA.emit('booking_rejected', { bookingId: booking.bookingId, technicianId: 501 });

      // B — next nearest, offered after A's rejection.
      const requestAtB = waitForEvent(techB, 'booking_request');
      await requestAtB;
      techB.emit('booking_rejected', { bookingId: booking.bookingId, technicianId: 502 });

      // C — offered after B's rejection too.
      const requestAtC = waitForEvent(techC, 'booking_request');
      await requestAtC;

      const acceptedAtCustomer = waitForEvent(patient, 'booking_accepted');
      techC.emit('booking_accepted', { bookingId: booking.bookingId, technicianId: 503, technicianName: 'Kumar' });
      await acceptedAtCustomer;

      // Every offer to a NEW technician must persist total_attempts=1 — old
      // buggy behavior would have shown 1, 2, 3 (a running total across the
      // whole booking) instead of resetting for each new technician.
      const requestInserts = db.execute.mock.calls.filter(c =>
        c[0].includes('INSERT INTO ip_booking_requests'));
      expect(requestInserts.length).toBeGreaterThanOrEqual(3);

      const forTech = (techId) => requestInserts.find(c => c[1][1] === techId);
      expect(forTech(501)[1]).toEqual([booking.bookingId, 501, 'Suresh', 1, 3]); // MAX_ATTEMPTS=3
      expect(forTech(502)[1]).toEqual([booking.bookingId, 502, 'Meena', 1, 3]);
      expect(forTech(503)[1]).toEqual([booking.bookingId, 503, 'Kumar', 1, 3]);
    } finally {
      techA.disconnect();
      techB.disconnect();
      techC.disconnect();
      patient.disconnect();
    }
  });
});

// IT-T008 — Duplicate-dispatch race-condition fix (booking #1226 incident).
// Root cause: dispatchQueues.has(bookingId) was checked, then awaited past
// (the slot hard-filter's own db.execute calls), before dispatchQueues.set()
// ever ran — a second booking_request for the same bookingId landing in that
// gap saw the same "not yet dispatching" state and started a second,
// competing dispatch cycle. The fix claims the bookingId in dispatchQueues
// synchronously, immediately after the existing check and before any await,
// so a second request lands after the claim and is turned away by that same
// pre-existing DUPLICATE_REQUEST branch instead of racing past it.
describe('IT-T008 — Duplicate booking_request for the same booking is ignored', () => {
  test('two back-to-back booking_request events for the same bookingId produce only one technician offer', async () => {
    const tech = await connectClient(server.url);
    const patient = await connectClient(server.url);
    try {
      tech.emit('technician_online', { technicianId: 501, technicianName: 'Suresh', lat: 13.05, lng: 80.25 });
      await waitForEvent(tech, 'session_started');

      const booking = await createRealBooking(70108);
      const payload = {
        bookingId: booking.bookingId, patientId: 501, patientName: 'Ravi Kumar',
        patientMobile: '9876543210', patientAddress: '12 MG Road',
        patientLat: 13.05, patientLng: 80.25, hospital: 'Microlab Chennai',
      };

      const requestPromise = waitForEvent(tech, 'booking_request');
      // Fired back-to-back, no await between them — the same shape as the
      // real duplicate that produced the #1226 incident (a second emit
      // landing before the first dispatch cycle had finished claiming state).
      patient.emit('booking_request', payload);
      patient.emit('booking_request', payload);

      const received = await requestPromise;
      expect(received.bookingId).toBe(booking.bookingId);

      // No second offer must ever reach the technician for this booking.
      let gotSecond = false;
      try {
        await waitForEvent(tech, 'booking_request', 400);
        gotSecond = true;
      } catch (_) { /* expected: times out — no second offer */ }
      expect(gotSecond).toBe(false);

      // Only one write to ip_booking_requests for this booking — not two
      // competing INSERTs from two independent dispatch cycles.
      const requestInserts = db.execute.mock.calls.filter(c =>
        c[0].includes('INSERT INTO ip_booking_requests') && c[1][0] === booking.bookingId);
      expect(requestInserts.length).toBe(1);
    } finally {
      patient.disconnect();
      tech.disconnect();
    }
  });
});
