// Tests the remaining customer-facing booking read/pay endpoints —
// bookingController.js: getMyBookings, getPatientBookings, getBooking, payBooking.
jest.mock('../../config/db');
jest.mock('../../services/clientSync');
const db         = require('../../config/db');
const clientSync = require('../../services/clientSync');
const request    = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { customerToken, primeAuthCheck } = require('../helpers/jwt');
const { createMockConnection } = require('../helpers/mockConnection');

const bookingRoutes = require('../../routes/bookings');
const app = buildTestApp('/api/bookings', bookingRoutes);
const token = customerToken({ id: 501, userId: 42, clientId: 10 });

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  db.getConnection.mockReset();
  clientSync.syncBookingToClient.mockReset().mockResolvedValue({ success: true });
});

// IMPORTANT: primeAuthCheck queues onto db.execute, the exact same mock the
// controller's own queries use for these plain (non-transaction) routes —
// and mocks are consumed in real EXECUTION order (auth middleware always
// runs first), not the order they're queued in source. So this must always
// be called BEFORE a test queues its own db.execute.mockResolvedValueOnce —
// never bundled into a helper invoked after the fact.
function authed(method, path) {
  return request(app)[method](path).set('Authorization', `Bearer ${token}`);
}

describe('GET /api/bookings/mine (booking history)', () => {
  test('rejects an unauthenticated request', async () => {
    const res = await request(app).get('/api/bookings/mine');
    expect(res.status).toBe(401);
  });

  // TC-HIST-01 — the reschedule-eligibility flag is computed server-side per
  // row from settings (default max=2 for both booking types) and appended to
  // the response; it is not something the DB query itself returns.
  test("returns the account's bookings with can_reschedule computed per row", async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[
      { booking_id_num: 900, booking_ref: 'BK900', booking_status: 'completed', booking_type: 'home_collection', reschedule_count: 1, total_amount: 500, items_total: 500 },
      { booking_id_num: 901, booking_ref: 'BK901', booking_status: 'completed', booking_type: 'home_collection', reschedule_count: 2, total_amount: 300, items_total: 300 },
    ]]);

    const res = await authed('get', '/api/bookings/mine');

    expect(res.status).toBe(200);
    expect(res.body.bookings).toHaveLength(2);
    expect(res.body.bookings[0].can_reschedule).toBe(true);  // 1 < default max 2
    expect(res.body.bookings[1].can_reschedule).toBe(false); // 2 >= default max 2
  });

  test('an account with no bookings gets an empty list, not an error', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[]]);
    const res = await authed('get', '/api/bookings/mine');
    expect(res.status).toBe(200);
    expect(res.body.bookings).toEqual([]);
  });
});

// FINDING: routes/bookings.js registers BOTH of the next two routes without
// the `auth` middleware that every other route in this file uses — confirmed
// by reading the route table directly (routes/bookings.js:18 and :21), and
// by this test file's own first draft: priming a JWT session check that no
// middleware ever consumes shifted the mocked DB responses by one position
// and produced a wrong result, which is exactly what exposed this. In the
// real app, anyone who can guess or increment a bookingId/patientId can read
// that patient's full booking + technician + address + phone details with NO
// authentication at all. Not fixed here (no API changes allowed by this
// task) — reported as a finding in the final test report.
describe('GET /api/bookings/patient/:patientId', () => {
  // TC-HIST-02 — a family member's own booking history, independent of
  // which account paid for/created it (joined via ip_patient_bookings, not
  // client_id) — this is what makes each family member's own history screen
  // show only their bookings.
  test("returns a specific patient's bookings (no Authorization header sent — there is no auth middleware on this route)", async () => {
    db.execute.mockResolvedValueOnce([[
      { booking_id: 901, booking_ref: 'BK901', patient_id: 502, status: 'completed' },
    ]]);
    const res = await request(app).get('/api/bookings/patient/502'); // deliberately no token
    expect(res.status).toBe(200);
    expect(res.body.bookings).toHaveLength(1);
    expect(db.execute.mock.calls[0][1]).toEqual(['502']);
  });
});

describe('GET /api/bookings/:bookingId (view booking)', () => {
  test('a booking that does not exist (or is soft-deleted) returns 404 — also with no auth required', async () => {
    db.execute.mockResolvedValueOnce([[]]);
    const res = await request(app).get('/api/bookings/999999'); // deliberately no token
    expect(res.status).toBe(404);
  });

  // FINDING (see block comment above): this succeeds with NO Authorization
  // header at all — any bookingId can be read by anyone.
  test('returns full booking detail including technician and test summary, unauthenticated', async () => {
    db.execute.mockResolvedValueOnce([[{
      booking_id: 900, booking_ref: 'BK900', status: 'assigned',
      tech_name: 'Suresh', test_names: 'CBC, Lipid Profile', items_total: 800,
    }]]);
    const res = await request(app).get('/api/bookings/900'); // deliberately no token
    expect(res.status).toBe(200);
    expect(res.body.booking.booking_ref).toBe('BK900');
    expect(res.body.booking.tech_name).toBe('Suresh');
  });
});

describe('POST /api/bookings/:bookingId/pay', () => {
  test('rejects a request missing razorpayPaymentId or amount', async () => {
    primeAuthCheck(db, token);
    const res = await authed('post', '/api/bookings/900/pay').send({ amount: 500 });
    expect(res.status).toBe(400);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('a booking not owned by this account is rejected and rolled back', async () => {
    primeAuthCheck(db, token);
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    conn.execute.mockResolvedValueOnce([[]]); // ownership lookup finds nothing

    const res = await authed('post', '/api/bookings/900/pay')
      .send({ razorpayPaymentId: 'pay_test1', amount: 500 });

    expect(res.status).toBe(404);
    expect(conn.rollback).toHaveBeenCalled();
  });

  // TC-PAY-CUST-01 — paying a still-pending booking both records the
  // transaction AND advances status to 'confirmed' in the same UPDATE.
  test('paying a pending booking confirms it and syncs to Jayamala', async () => {
    primeAuthCheck(db, token);
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    conn.execute
      .mockResolvedValueOnce([[{ booking_id: 900, patient_id: 501, total_amount: 500, status: 'pending' }]])
      .mockResolvedValueOnce([{}])   // INSERT ip_payment_transactions
      .mockResolvedValueOnce([{}]);  // UPDATE ip_bookings

    const res = await authed('post', '/api/bookings/900/pay')
      .send({ razorpayPaymentId: 'pay_test1', razorpayOrderId: 'order_test1', amount: 500 });

    expect(res.status).toBe(200);
    expect(conn.commit).toHaveBeenCalled();
    // Status advances to 'confirmed' only because it was 'pending'.
    expect(conn.execute.mock.calls[2][0]).toMatch(/status = 'confirmed'/);
    expect(clientSync.syncBookingToClient).toHaveBeenCalledWith(
      900, expect.objectContaining({ action: 'payment_update' })
    );
  });

  // TC-PAY-CUST-02 — a booking already past 'pending' (e.g. 'assigned', a
  // technician already accepted it) must NOT have its status silently
  // overwritten by a late/partial payment — only payment_status advances.
  test('paying a booking already past pending does not touch its status field', async () => {
    primeAuthCheck(db, token);
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    conn.execute
      .mockResolvedValueOnce([[{ booking_id: 900, patient_id: 501, total_amount: 500, status: 'assigned' }]])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}]);

    const res = await authed('post', '/api/bookings/900/pay')
      .send({ razorpayPaymentId: 'pay_test1', amount: 500 });

    expect(res.status).toBe(200);
    expect(conn.execute.mock.calls[2][0]).not.toMatch(/status = 'confirmed'/);
    expect(conn.execute.mock.calls[2][0]).toMatch(/payment_status = 'paid'/);
  });
});
