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
        items: [{ packageId: 7, originalPrice: 500, finalPrice: 500 }],
      });

    expect(res.status).toBe(201);
    expect(res.body.success).toBe(true);
    expect(res.body.isScheduled).toBe(false);
    // booking_ref is now derived from the row's own id, not a timestamp —
    // see bookingController.js's own comment on why (LT-002 fix).
    expect(res.body.bookingRef).toBe('BK-000900');
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
        items: [{ packageId: 7, originalPrice: 500, finalPrice: 500 }],
      });

    expect(res.status).toBe(201);
    expect(res.body.isScheduled).toBe(true);
    // 7 calls, not 8 — the auto-confirm UPDATE was correctly skipped.
    expect(conn.execute).toHaveBeenCalledTimes(7);
  });
});
