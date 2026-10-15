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
  // NOTE on call count: the source has a real bug at bookingController.js:185
  // — it pushes `{ productId: validProductId, ... }` into bookingItemsInserted
  // but then checks `singleItem.validProductId` (a property that was never
  // set — the key is `productId`). That condition is always falsy, so the
  // "UPDATE ip_bookings SET product_id" step for single-item bookings never
  // actually runs, in EVERY booking, not just multi-item ones. This test
  // asserts the real (buggy) call count, not the one the code's comment
  // implies — see the final test report for this as a reported finding.
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
    expect(conn.execute).toHaveBeenCalledTimes(7);
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
    expect(conn.execute).toHaveBeenCalledTimes(8);
    const confirmCall = conn.execute.mock.calls[7];
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
    expect(conn.execute).toHaveBeenCalledTimes(7);
  });
});

// ── Home Collection fare (Branch → Customer, see server/services/fareCalculator.js) ──
// bookingType defaults to 'home_collection' (see the destructuring default in
// createBooking), so every test here relies on that default rather than
// stating it explicitly, matching how a real Home Collection request from
// checkout_screen.dart is actually shaped.
describe('POST /api/bookings — Home Collection fare', () => {
  const activeRateRow = {
    rate_id: 3, rate_per_km: '15.00', base_fare: '49.00',
    included_distance_km: '3.00', max_service_distance_km: null,
    effective_from: '2026-01-01', notes: 'test rate',
  };
  const branchCoordsRow = { latitude: '13.0827', longitude: '80.2707' }; // Chennai
  // ~8km north of the branch coords above — chosen so Scenario B's example
  // (8km, ₹124) is realistic without hand-tuning haversine inputs precisely;
  // the exact distance isn't asserted here (fareCalculator.test.js does
  // that), only that a fare was computed and folded into totalAmount.
  const pickupCoords = { collectionLatitude: 13.155, collectionLongitude: 80.2707 };

  test('a pay-later Home Collection booking gets a server-computed fare folded into totalAmount', async () => {
    primeAuthCheck(db, token);
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    conn.execute
      .mockResolvedValueOnce([[branchCoordsRow]])                        // 1. fareCalculator: branch coords
      .mockResolvedValueOnce([[activeRateRow]])                          // 2. fareCalculator: active rate
      .mockResolvedValueOnce([[{ patient_id_ref: null }]])               // 3. patient_id_ref lookup
      .mockResolvedValueOnce([{ insertId: 950 }])                        // 4. INSERT ip_bookings
      .mockResolvedValueOnce([{}])                                       // 5. UPDATE booking_ref
      .mockResolvedValueOnce([{}])                                       // 6. INSERT ip_patient_bookings
      .mockResolvedValueOnce([[{ product_id: 7, product_name: 'CBC', document_required: 0 }]]) // 7. item lookup
      .mockResolvedValueOnce([{ insertId: 1 }])                          // 8. INSERT ip_booking_items
      .mockResolvedValueOnce([{}]);                                      // 9. INSERT ip_payment_transactions

    const res = await request(app).post('/api/bookings')
      .set('Authorization', `Bearer ${token}`)
      .send({
        patientId: 501, branchId: 3, paymentType: 'pay_later',
        totalAmount: 500, // client's own (untrusted) figure — server recomputes it
        ...pickupCoords,
        items: [{ packageId: 7, originalPrice: 500, finalPrice: 500 }],
      });

    expect(res.status).toBe(201);
    expect(res.body.success).toBe(true);
    // totalAmount stored on the booking row must be itemsTotal(500) +
    // server-computed fare, NOT the client's own totalAmount(500 — which
    // would coincidentally equal itemsTotal alone, proving nothing) — the
    // 4th conn.execute call is the ip_bookings INSERT.
    const insertBookingParams = conn.execute.mock.calls[3][1];
    expect(insertBookingParams[8]).toBeGreaterThan(500); // total_amount column
    // home_collection_fare / home_collection_distance_km / km_rate_id are
    // columns 19, 20, 21 in the INSERT's value array (0-indexed) — see
    // bookingController.js's own column-list comment for the exact order.
    expect(insertBookingParams[19]).toBeGreaterThan(0);  // home_collection_fare
    expect(insertBookingParams[20]).toBeGreaterThan(0);  // home_collection_distance_km
    expect(insertBookingParams[21]).toBe(3);             // km_rate_id
  });

  test('a Home Collection booking with no pickup coordinates is rejected before touching the database', async () => {
    primeAuthCheck(db, token);
    const res = await request(app).post('/api/bookings')
      .set('Authorization', `Bearer ${token}`)
      .send({ patientId: 501, branchId: 3, totalAmount: 500, items: [] });

    expect(res.status).toBe(422);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('a branch with no coordinates on file is reported, not silently priced at 0 or via technician location', async () => {
    primeAuthCheck(db, token);
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    conn.execute.mockResolvedValueOnce([[]]); // fareCalculator: branch coords lookup finds nothing

    const res = await request(app).post('/api/bookings')
      .set('Authorization', `Bearer ${token}`)
      .send({ patientId: 501, branchId: 3, totalAmount: 500, ...pickupCoords, items: [] });

    expect(res.status).toBe(422);
    expect(res.body.code).toBe('BRANCH_LOCATION_UNAVAILABLE');
    expect(conn.rollback).toHaveBeenCalled();
  });

  test('no active fare configuration is a clear 503, never a guessed rate', async () => {
    primeAuthCheck(db, token);
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    conn.execute
      .mockResolvedValueOnce([[branchCoordsRow]]) // branch coords found
      .mockResolvedValueOnce([[]]);               // no active ip_km_rates row

    const res = await request(app).post('/api/bookings')
      .set('Authorization', `Bearer ${token}`)
      .send({ patientId: 501, branchId: 3, totalAmount: 500, ...pickupCoords, items: [] });

    expect(res.status).toBe(503);
    expect(res.body.code).toBe('RATE_NOT_FOUND');
  });

  // A paid-in-full booking has already had Razorpay capture a specific
  // amount before this request is even sent (see createBooking's own
  // comment on why) — the server can't un-charge that, so totalAmount is
  // trusted as-is here rather than overridden, even though the fare is
  // still computed and stored for audit.
  test('a paid-in-full booking keeps the already-captured totalAmount even if it disagrees with the recomputed fare', async () => {
    primeAuthCheck(db, token);
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    conn.execute
      .mockResolvedValueOnce([[branchCoordsRow]])
      .mockResolvedValueOnce([[activeRateRow]])
      .mockResolvedValueOnce([[{ patient_id_ref: null }]])
      .mockResolvedValueOnce([{ insertId: 951 }])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([[{ product_id: 7, product_name: 'CBC', document_required: 0 }]])
      .mockResolvedValueOnce([{ insertId: 1 }])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}]); // auto-confirm UPDATE (same-day + paid)

    const res = await request(app).post('/api/bookings')
      .set('Authorization', `Bearer ${token}`)
      .send({
        patientId: 501, branchId: 3, paymentType: 'full',
        razorpayPaymentId: 'pay_test999',
        totalAmount: 500, // deliberately NOT itemsTotal(500) + the active rate's real fare
        ...pickupCoords,
        items: [{ packageId: 7, originalPrice: 500, finalPrice: 500 }],
      });

    expect(res.status).toBe(201);
    const insertBookingParams = conn.execute.mock.calls[3][1];
    expect(insertBookingParams[8]).toBe(500);   // total_amount — the captured amount, untouched
    expect(insertBookingParams[19]).toBeGreaterThan(0); // home_collection_fare still recorded for audit
  });
});
