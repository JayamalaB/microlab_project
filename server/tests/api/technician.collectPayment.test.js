// Tests POST /api/technicians/collect-payment —
// server/controllers/technicianController.js: collectPayment
//
// Covers: TC-PAY-01 (full payment), TC-PAY-02 (partial payment),
// TC-PAY-03 (cash, no Razorpay id needed), TC-PAY-04 (booking not
// assigned to this technician), negative input validation.
jest.mock('../../config/db');
const db      = require('../../config/db');
const request = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { technicianToken, primeAuthCheck } = require('../helpers/jwt');

const technicianRoutes = require('../../routes/technicians');
const app = buildTestApp('/api/technicians', technicianRoutes);
const token = technicianToken({ id: 17 });

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
});

describe('POST /api/technicians/collect-payment', () => {
  test('rejects an unauthenticated request', async () => {
    const res = await request(app).post('/api/technicians/collect-payment').send({});
    expect(res.status).toBe(401);
  });

  test('rejects a request missing amount', async () => {
    primeAuthCheck(db, token);
    const res = await request(app).post('/api/technicians/collect-payment')
      .set('Authorization', `Bearer ${token}`)
      .send({ bookingId: 900 });
    expect(res.status).toBe(400);
  });

  test('rejects Razorpay method without a razorpayPaymentId', async () => {
    primeAuthCheck(db, token);
    const res = await request(app).post('/api/technicians/collect-payment')
      .set('Authorization', `Bearer ${token}`)
      .send({ bookingId: 900, amount: 500, paymentMethod: 'RAZORPAY' });
    expect(res.status).toBe(400);
    expect(res.body.message).toMatch(/razorpayPaymentId/);
  });

  test('a booking not assigned to this technician is rejected', async () => {
    // The auth middleware's own session check must be queued FIRST — it
    // runs before the controller ever touches the DB, so queuing order here
    // must mirror real execution order, not source-code order.
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[]]); // ownership lookup finds nothing

    const res = await request(app).post('/api/technicians/collect-payment')
      .set('Authorization', `Bearer ${token}`)
      .send({ bookingId: 900, amount: 500, paymentMethod: 'CASH' });
    expect(res.status).toBe(404);
  });

  // TC-PAY-01 — paying the exact remaining amount flips status to 'paid'.
  test('paying the full remaining amount marks the booking paid', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[{ booking_id: 900, patient_id: 55, total_amount: 878, amount_paid: 0 }]])
      .mockResolvedValueOnce([{ affectedRows: 1 }])   // UPDATE ip_bookings
      .mockResolvedValueOnce([{ insertId: 1 }]);       // INSERT ip_payment_transactions

    const res = await request(app).post('/api/technicians/collect-payment')
      .set('Authorization', `Bearer ${token}`)
      .send({ bookingId: 900, amount: 878, paymentMethod: 'CASH' });

    expect(res.status).toBe(200);
    expect(res.body.paymentStatus).toBe('paid');
    expect(res.body.amountDue).toBe(0);
    // Confirms the actual write matches the computed status, not a stale one.
    // calls[0] is the auth middleware's own check, so the controller's UPDATE is calls[2].
    expect(db.execute.mock.calls[2][1]).toEqual(['paid', 878, 0, 900]);
  });

  // TC-PAY-02 — paying less than the total leaves it 'partial', with the
  // remaining due amount correctly computed.
  test('paying less than the total leaves the booking partially paid', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[{ booking_id: 900, patient_id: 55, total_amount: 878, amount_paid: 0 }]])
      .mockResolvedValueOnce([{ affectedRows: 1 }])
      .mockResolvedValueOnce([{ insertId: 1 }]);

    const res = await request(app).post('/api/technicians/collect-payment')
      .set('Authorization', `Bearer ${token}`)
      .send({ bookingId: 900, amount: 300, paymentMethod: 'CASH' });

    expect(res.status).toBe(200);
    expect(res.body.paymentStatus).toBe('partial');
    expect(res.body.amountDue).toBe(578);
  });

  // TC-PAY-03 — cash doesn't need a Razorpay id, and the transaction row
  // records it as cash-collected, not a captured gateway payment.
  test('cash payment does not require razorpayPaymentId', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[{ booking_id: 900, patient_id: 55, total_amount: 500, amount_paid: 0 }]])
      .mockResolvedValueOnce([{ affectedRows: 1 }])
      .mockResolvedValueOnce([{ insertId: 1 }]);

    const res = await request(app).post('/api/technicians/collect-payment')
      .set('Authorization', `Bearer ${token}`)
      .send({ bookingId: 900, amount: 500, paymentMethod: 'CASH' });

    expect(res.status).toBe(200);
    // calls[0] is the auth check, calls[3] is the INSERT into ip_payment_transactions.
    const insertParams = db.execute.mock.calls[3][1];
    expect(insertParams).toContain('cash_collected');
  });

  // TC-PAY-05 — a single payment larger than what's left owed is rejected
  // outright, before any write happens (real defect found by load testing:
  // previously this was accepted and silently overpaid the booking).
  test('rejects a payment larger than the amount due', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[{ booking_id: 900, patient_id: 55, total_amount: 500, amount_paid: 0 }]]);

    const res = await request(app).post('/api/technicians/collect-payment')
      .set('Authorization', `Bearer ${token}`)
      .send({ bookingId: 900, amount: 800, paymentMethod: 'CASH' });

    expect(res.status).toBe(400);
    expect(res.body.success).toBe(false);
    expect(res.body.amountDue).toBe(500);
    // Only the ownership lookup should have run — no UPDATE/INSERT after rejection.
    expect(db.execute).toHaveBeenCalledTimes(2); // auth check + ownership lookup
  });

  // TC-PAY-06 — a booking that's already fully paid rejects any further
  // payment (the "repeated payment" symptom of the same defect).
  test('rejects any further payment on an already fully-paid booking', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[{ booking_id: 900, patient_id: 55, total_amount: 500, amount_paid: 500 }]]);

    const res = await request(app).post('/api/technicians/collect-payment')
      .set('Authorization', `Bearer ${token}`)
      .send({ bookingId: 900, amount: 100, paymentMethod: 'CASH' });

    expect(res.status).toBe(400);
    expect(res.body.amountDue).toBe(0);
  });

  // TC-PAY-07 — paying exactly the remaining due amount still succeeds
  // (the guard must not false-reject a legitimate exact final payment).
  test('paying exactly the remaining due amount still succeeds', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[{ booking_id: 900, patient_id: 55, total_amount: 878, amount_paid: 300 }]])
      .mockResolvedValueOnce([{ affectedRows: 1 }])
      .mockResolvedValueOnce([{ insertId: 1 }]);

    const res = await request(app).post('/api/technicians/collect-payment')
      .set('Authorization', `Bearer ${token}`)
      .send({ bookingId: 900, amount: 578, paymentMethod: 'CASH' });

    expect(res.status).toBe(200);
    expect(res.body.paymentStatus).toBe('paid');
    expect(res.body.amountDue).toBe(0);
  });
});
