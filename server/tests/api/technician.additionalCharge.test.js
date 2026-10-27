// Tests PUT /api/technicians/bookings/:bookingId/additional-charge —
// server/controllers/technicianController.js: setAdditionalCharge
//
// Updated Total = Existing Total + Additional Charge; saving again replaces
// the charge, 0 removes it; only between arrival and Sample Collected.
jest.mock('../../config/db');
const db      = require('../../config/db');
const request = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { technicianToken, primeAuthCheck } = require('../helpers/jwt');

const technicianRoutes = require('../../routes/technicians');
const app = buildTestApp('/api/technicians', technicianRoutes);
const token = technicianToken({ id: 17 });
const url = '/api/technicians/bookings/900/additional-charge';

const booking = (over = {}) => ({
  booking_id: 900, status: 'assigned', total_amount: '1350.00', amount_paid: '0.00',
  payment_status: 'unpaid', additional_charge_amount: '0.00', collection_status: 'arrived', ...over,
});

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
});

const put = (body) => request(app).put(url).set('Authorization', `Bearer ${token}`).send(body);

describe('PUT /api/technicians/bookings/:bookingId/additional-charge', () => {
  test('rejects an unauthenticated request', async () => {
    const res = await request(app).put(url).send({ amount: 50, reason: 'Waited' });
    expect(res.status).toBe(401);
  });

  test('a charge needs a reason', async () => {
    primeAuthCheck(db, token);
    const res = await put({ amount: 50, reason: '  ' });
    expect(res.status).toBe(400);
    expect(res.body.message).toMatch(/reason/);
  });

  test('rejects a negative amount and one above the maximum', async () => {
    primeAuthCheck(db, token);
    expect((await put({ amount: -5, reason: 'x' })).status).toBe(400);
    primeAuthCheck(db, token);
    const res = await put({ amount: 5000, reason: 'x' });
    expect(res.status).toBe(400);
    expect(res.body.message).toMatch(/at most ₹1000/);
  });

  test('a booking not assigned to this technician is rejected', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[]]);
    expect((await put({ amount: 50, reason: 'Waited' })).status).toBe(404);
  });

  test('not allowed before arrival or after Sample Collected', async () => {
    for (const s of ['en_route', 'otp_verified', 'handed_to_lab']) {
      primeAuthCheck(db, token);
      db.execute.mockResolvedValueOnce([[booking({ collection_status: s })]]);
      const res = await put({ amount: 50, reason: 'Waited' });
      expect(res.status).toBe(409);
    }
  });

  test('adds the charge to total and amount due (unpaid booking)', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[booking()]])
      .mockResolvedValueOnce([{ affectedRows: 1 }]);

    const res = await put({ amount: 70, reason: 'Waited 30 min' });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      success: true, additionalChargeAmount: 70, additionalChargeReason: 'Waited 30 min',
      totalAmount: 1420, amountDue: 1420, paymentStatus: 'unpaid',
    });
    // calls[0] auth check, [1] lookup, [2] UPDATE
    const [sql, params] = db.execute.mock.calls[2];
    expect(sql).toMatch(/WHERE booking_id = \? AND additional_charge_amount = \? AND amount_paid = \? AND total_amount = \?/);
    expect(params.slice(0, 6)).toEqual([70, 'Waited 30 min', 1420, 1420, 'unpaid', 900]);
  });

  test('a fully paid booking becomes partial with only the charge due', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[booking({ amount_paid: '1350.00', payment_status: 'paid' })]])
      .mockResolvedValueOnce([{ affectedRows: 1 }]);

    const res = await put({ amount: 70, reason: 'Extra distance' });
    expect(res.body).toMatchObject({ totalAmount: 1420, amountDue: 70, paymentStatus: 'partial' });
  });

  test('saving again replaces the earlier charge, it is not added twice', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[booking({ total_amount: '1420.00', additional_charge_amount: '70.00' })]])
      .mockResolvedValueOnce([{ affectedRows: 1 }]);

    const res = await put({ amount: 100, reason: 'Waited 45 min' });
    expect(res.body).toMatchObject({ totalAmount: 1450, amountDue: 1450 });
  });

  test('amount 0 removes the charge and clears the reason', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[booking({ total_amount: '1420.00', additional_charge_amount: '70.00',
        amount_paid: '1420.00', payment_status: 'paid' })]]);
    // Removing would put the total (1350) below what is paid (1420).
    const blocked = await put({ amount: 0, reason: '' });
    expect(blocked.status).toBe(400);

    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[booking({ total_amount: '1420.00', additional_charge_amount: '70.00' })]])
      .mockResolvedValueOnce([{ affectedRows: 1 }]);
    const res = await put({ amount: 0, reason: '' });
    expect(res.body).toMatchObject({ additionalChargeAmount: 0, additionalChargeReason: null, totalAmount: 1350 });
  });

  test('a payment landing in between is not overwritten (409)', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[booking()]])
      .mockResolvedValueOnce([{ affectedRows: 0 }]);
    const res = await put({ amount: 70, reason: 'Waited' });
    expect(res.status).toBe(409);
  });
});
