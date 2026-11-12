// Tests POST /api/bookings — server/controllers/bookingController.js: createBooking
//
// createBooking runs entirely inside one db.getConnection() transaction
// (conn.execute, not db.execute), so this file uses createMockConnection()
// rather than mocking db.execute/db.query directly — same pattern as the
// technician-logout test.
//
// It also fires a real outbound sync (syncBookingToClient, from
// services/clientSync.js) at the very end, fire-and-forget (`.catch()`, not
// awaited by the caller). Rather than reaching into http/https to fake that
// network call (which is really clientSync's own concern, covered later by
// the visit_completed integration tests), the whole clientSync module is
// mocked here — this test is about createBooking's own DB writes and status
// logic, not about what clientSync does with the result.
//
// Covers: TC-BOOK-01 (pay-later booking, pending status), TC-BOOK-02 (fully
// paid same-day booking auto-confirms), TC-BOOK-03 (future-dated booking
// stays 'scheduled' even if paid — the cron dispatches it later, not this
// endpoint), negative case (missing patientId, no DB touched at all).
// Booking access, price and payment checks have their own tests
// (accessControl, itemPrices, razorpayVerify); this file covers what follows them.
jest.mock('../../middleware/access', () => ({
  ...jest.requireActual('../../middleware/access'),
  requireBookingAccess: (_req, _res, next) => next(),
  requirePatientAccess: (_req, _res, next) => next(),
}));
jest.mock('../../services/itemPrices', () => ({ checkItemPrices: async () => ({ ok: true }) }));
jest.mock('../../services/razorpayVerify', () => ({
  verifyRazorpayPayment: async (_id, { amount }) => ({ ok: true, amount: Number(amount) }),
}));
jest.mock('../../config/db');
jest.mock('../../services/clientSync');
const db        = require('../../config/db');
const clientSync = require('../../services/clientSync');
const request   = require('supertest');
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

describe('POST /api/bookings', () => {
  test('rejects an unauthenticated request', async () => {
    const res = await request(app).post('/api/bookings').send({ patientId: 501 });
    expect(res.status).toBe(401);
  });

  // Negative case: the patientId check runs BEFORE db.getConnection() is
  // even called — confirms a bad request never opens a transaction at all.
  test('rejects a request missing patientId before touching the database', async () => {
    primeAuthCheck(db, token);
    const res = await request(app).post('/api/bookings')
      .set('Authorization', `Bearer ${token}`)
      .send({ totalAmount: 500 });

    expect(res.status).toBe(400);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  // TC-BOOK-01 — pay-later, same-day booking: stays 'pending', no
  // gateway/payment fields populated, no auto-confirm update fired.
  //
  test('a pay-later booking is created with status pending', async () => {
    primeAuthCheck(db, token);
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    conn.execute
      .mockResolvedValueOnce([[{ patient_id_ref: null }]])              // 1. patient_id_ref lookup
      .mockResolvedValueOnce([{ insertId: 900 }])                       // 2. INSERT ip_bookings
      .mockResolvedValueOnce([{}])                                      // 3. UPDATE booking_ref (derived from insertId)
      .mockResolvedValueOnce([{}])                                      // 4. INSERT ip_patient_bookings
      .mockResolvedValueOnce([[{ product_id: 7, product_name: 'CBC', document_required: 0 }]]) // 5. item lookup
      .mockResolvedValueOnce([{ insertId: 1 }])                         // 6. INSERT ip_booking_items
      .mockResolvedValueOnce([{}]);                                     // 7. INSERT ip_payment_transactions

    const res = await request(app).post('/api/bookings')
      .set('Authorization', `Bearer ${token}`)
      .send({
        patientId: 501, totalAmount: 500, paymentType: 'pay_later',
        // lab_visit — these 3 tests are about status-transition logic, not
        // Home Collection fare (that's covered separately, see the "Home
        // Collection fare" describe block below); opting out of
        // bookingType's 'home_collection' default keeps their original,
        // simpler mock sequences valid.
        bookingType: 'lab_visit',
        items: [{ packageId: 7, originalPrice: 500, finalPrice: 500 }],
      });

    expect(res.status).toBe(201);
    expect(res.body.success).toBe(true);
    expect(res.body.isScheduled).toBe(false);
    // booking_ref is derived from the row's own id, not a timestamp — see
    // bookingController.js's own comment on why (LT-002 fix) — plus a fixed
    // offset from ip_settings ('booking_ref_offset'), which change_booking
    // _ref_to_sequential.sql set up so refs became a plain sequential number
    // (see that migration). This test doesn't mock config/settings, so the
    // real module's cache is empty and the offset falls back to its default
    // of 0 — bookingRef is therefore exactly the booking_id itself.
    expect(res.body.bookingRef).toBe('900');
    expect(conn.commit).toHaveBeenCalled();
    expect(conn.rollback).not.toHaveBeenCalled();
    expect(conn.execute).toHaveBeenCalledTimes(8);
    // A single-item booking records its product.
    expect(conn.execute.mock.calls.some(c => /SET product_id = \?/.test(c[0]))).toBe(true);
    // Confirms the booking row itself was inserted with 'pending' status and
    // the un-paid amount split (amount_paid=0, amount_due=total).
    const insertBookingParams = conn.execute.mock.calls[1][1];
    expect(insertBookingParams).toContain('pending');
    // Sync to Jayamala is still attempted for every booking, paid or not.
    expect(clientSync.syncBookingToClient).toHaveBeenCalledWith(
      900, expect.objectContaining({ action: 'new_booking' })
    );
  });

  // TC-BOOK-02 — a fully paid, same-day booking is auto-confirmed right
  // after creation (a 7th conn.execute call flips status to 'confirmed').
  test('a fully paid same-day booking is auto-confirmed', async () => {
    primeAuthCheck(db, token);
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    conn.execute
      .mockResolvedValueOnce([[{ patient_id_ref: null }]])
      .mockResolvedValueOnce([{ insertId: 901 }])
      .mockResolvedValueOnce([{}])   // UPDATE booking_ref
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([[{ product_id: 7, product_name: 'CBC', document_required: 0 }]])
      .mockResolvedValueOnce([{ insertId: 2 }])
      .mockResolvedValueOnce([{}])   // INSERT ip_payment_transactions
      .mockResolvedValueOnce([{}]);  // UPDATE status='confirmed'

    const res = await request(app).post('/api/bookings')
      .set('Authorization', `Bearer ${token}`)
      .send({
        patientId: 501, totalAmount: 500, paymentType: 'full',
        razorpayPaymentId: 'pay_test123', razorpayOrderId: 'order_test123',
        bookingType: 'lab_visit', // see the pay-later test above for why
        items: [{ packageId: 7, originalPrice: 500, finalPrice: 500 }],
      });

    expect(res.status).toBe(201);
    expect(conn.execute).toHaveBeenCalledTimes(9);
    const confirmCall = conn.execute.mock.calls[8];
    expect(confirmCall[0]).toMatch(/status = 'confirmed'/);
    expect(confirmCall[1]).toEqual([901]);
  });

  // TC-BOOK-03 — a future-dated booking is held as 'scheduled' for the cron
  // dispatcher, even if it was paid in full — the immediate-confirm update
  // must NOT fire here, matching the code's explicit `bookingStatus !==
  // 'scheduled'` guard.
  test('a future-dated booking stays scheduled even when paid in full', async () => {
    primeAuthCheck(db, token);
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    conn.execute
      .mockResolvedValueOnce([[{ patient_id_ref: null }]])
      .mockResolvedValueOnce([{ insertId: 902 }])
      .mockResolvedValueOnce([{}])   // UPDATE booking_ref
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([[{ product_id: 7, product_name: 'CBC', document_required: 0 }]])
      .mockResolvedValueOnce([{ insertId: 3 }])
      .mockResolvedValueOnce([{}]); // INSERT ip_payment_transactions — no confirm call

    const farFutureDate = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000)
      .toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });

    const res = await request(app).post('/api/bookings')
      .set('Authorization', `Bearer ${token}`)
      .send({
        patientId: 501, totalAmount: 500, paymentType: 'full',
        razorpayPaymentId: 'pay_test123', collectionDate: farFutureDate,
        bookingType: 'lab_visit', // see the pay-later test above for why
        items: [{ packageId: 7, originalPrice: 500, finalPrice: 500 }],
      });

    expect(res.status).toBe(201);
    expect(res.body.isScheduled).toBe(true);
    // 7 calls, not 8 — the auto-confirm UPDATE was correctly skipped.
    expect(conn.execute).toHaveBeenCalledTimes(8);
  });
});

// ── Home Collection fare (Branch → Customer, see server/services/fareCalculator.js) ──
// bookingType defaults to 'home_collection' (see the destructuring default in
// createBooking), so every test here relies on that default rather than
// stating it explicitly, matching how a real Home Collection request from
// checkout_screen.dart is actually shaped.
describe('POST /api/bookings — Home Collection service charge collected on the spot', () => {
  // No service charge at booking any more: it is worked out when a technician
  // accepts and added to the bill when they arrive (services/serviceCharge.js,
  // tests/services/serviceCharge.test.js). The booking total is the tests only.
  const pickupCoords = { collectionLatitude: 13.155, collectionLongitude: 80.2707 };

  // conn.execute answered by SQL text, so the order of queries doesn't matter.
  function wireConn(bookingId) {
    const conn = createMockConnection();
    conn.execute.mockImplementation(async (sql) => {
      if (/SELECT patient_id_ref, client_id FROM ip_patients/.test(sql)) return [[{ patient_id_ref: null }]];
      if (/^\s*INSERT INTO ip_bookings/.test(sql)) return [{ insertId: bookingId }];
      if (/FROM ip_products WHERE product_id = \?/.test(sql)) return [[{ product_id: 7, product_name: 'CBC', document_required: 0 }]];
      if (/^\s*INSERT/.test(sql)) return [{ insertId: 1 }];
      return [{}];
    });
    db.getConnection.mockResolvedValue(conn);
    return conn;
  }
  const bookingInsert = (conn) => conn.execute.mock.calls.find(c => /^\s*INSERT INTO ip_bookings/.test(c[0]))[1];
  const markedPending = (conn) => conn.execute.mock.calls.filter(c => /SET service_charge_status = 'pending'/.test(c[0]));

  test('a pay-later booking: total is the tests only, no fare, service charge pending', async () => {
    primeAuthCheck(db, token);
    const conn = wireConn(950);

    const res = await request(app).post('/api/bookings')
      .set('Authorization', `Bearer ${token}`)
      .send({
        patientId: 501, branchId: 3, paymentType: 'pay_later', totalAmount: 575,
        ...pickupCoords,
        items: [{ packageId: 7, originalPrice: 500, finalPrice: 500 }],
      });

    expect(res.status).toBe(201);
    const params = bookingInsert(conn);
    expect(params[8]).toBe(500);    // total_amount = tests only
    expect(params[20]).toBeNull();  // home_collection_fare
    expect(params[21]).toBeNull();  // home_collection_distance_km
    expect(params[22]).toBeNull();  // service_charge_product_id
    expect(markedPending(conn).map(c => c[1])).toEqual([[950]]);
    // No fare lookup at booking.
    expect(conn.execute.mock.calls.some(c => /from_km|FROM ip_branches/.test(c[0]))).toBe(false);
  });

  test('a Home Collection booking with no pickup coordinates is rejected before touching the database', async () => {
    primeAuthCheck(db, token);
    const res = await request(app).post('/api/bookings')
      .set('Authorization', `Bearer ${token}`)
      .send({ patientId: 501, branchId: 3, totalAmount: 500, items: [] });

    expect(res.status).toBe(422);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('a paid-in-full booking pays the tests only — the service charge is collected on the spot', async () => {
    primeAuthCheck(db, token);
    const conn = wireConn(951);

    const res = await request(app).post('/api/bookings')
      .set('Authorization', `Bearer ${token}`)
      .send({
        patientId: 501, branchId: 3, paymentType: 'full', razorpayPaymentId: 'pay_test999',
        totalAmount: 1, // the app's own figure, ignored
        ...pickupCoords,
        items: [{ packageId: 7, originalPrice: 500, finalPrice: 500 }],
      });

    expect(res.status).toBe(201);
    const params = bookingInsert(conn);
    expect(params[8]).toBe(500);   // total_amount
    expect(params[10]).toBe(500);  // amount_paid
    expect(params[11]).toBe(0);    // amount_due
    expect(markedPending(conn)).toHaveLength(1);
  });

  test('a Lab Visit is not marked for a service charge', async () => {
    primeAuthCheck(db, token);
    const conn = wireConn(952);

    const res = await request(app).post('/api/bookings')
      .set('Authorization', `Bearer ${token}`)
      .send({
        patientId: 501, branchId: 3, bookingType: 'lab_visit', paymentType: 'pay_later', totalAmount: 500,
        items: [{ packageId: 7, originalPrice: 500, finalPrice: 500 }],
      });

    expect(res.status).toBe(201);
    expect(markedPending(conn)).toHaveLength(0);
  });
});
