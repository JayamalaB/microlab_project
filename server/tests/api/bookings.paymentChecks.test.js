// Tests that a booking is refused, with nothing saved or captured, when the
// price check or the Razorpay check fails, and that a patient on another
// account can't be booked for. The checks themselves are tested in
// itemPrices.test.js and razorpayVerify.test.js.
jest.mock('../../config/db');
jest.mock('../../config/settings');
jest.mock('../../services/clientSync');
jest.mock('../../services/itemPrices', () => ({ checkItemPrices: jest.fn() }));
jest.mock('../../services/razorpayVerify', () => ({ verifyRazorpayPayment: jest.fn() }));
const https    = require('https');
const db       = require('../../config/db');
const settings = require('../../config/settings');
const clientSync = require('../../services/clientSync');
const { checkItemPrices } = require('../../services/itemPrices');
const { verifyRazorpayPayment } = require('../../services/razorpayVerify');
const request  = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { customerToken, primeAuthCheck } = require('../helpers/jwt');
const { createMockConnection } = require('../helpers/mockConnection');

const app   = buildTestApp('/api/bookings', require('../../routes/bookings'));
const token = customerToken({ clientId: 2001 });

const items  = [{ packageId: 7, finalPrice: 500 }];
const booking = { patientId: 501, bookingType: 'lab_visit', items };
const family  = { members: [{ patientId: 501, items }, { patientId: 502, items }], bookingType: 'lab_visit' };
const paid    = { paymentType: 'full', razorpayPaymentId: 'pay_x' };

let conn;
const realRequest = https.request;

beforeEach(() => {
  process.env.RAZORPAY_KEY_ID     = 'test_key';
  process.env.RAZORPAY_KEY_SECRET = 'test_value';
  db.execute.mockReset().mockResolvedValue([[], {}]);
  settings.getBool.mockReset().mockReturnValue(true);
  settings.get.mockReset().mockReturnValue('4');
  clientSync.syncBookingToClient.mockReset().mockResolvedValue({ success: true });
  checkItemPrices.mockReset().mockResolvedValue({ ok: true });
  verifyRazorpayPayment.mockReset().mockResolvedValue({ ok: true, amount: 500 });

  let id = 900;
  conn = createMockConnection();
  conn.execute.mockImplementation(async (sql) => {
    if (/INSERT INTO ip_bookings/.test(sql)) return [{ insertId: id++ }];
    return /^\s*SELECT/.test(sql) ? [[]] : [{}];
  });
  db.getConnection.mockReset().mockResolvedValue(conn);
  https.request = jest.fn(() => ({ on: jest.fn(), write: jest.fn(), end: jest.fn() }));
});
afterEach(() => { https.request = realRequest; });

function post(path, body) {
  primeAuthCheck(db, token);
  return request(app).post(path).set('Authorization', `Bearer ${token}`).send(body);
}
const nothingSaved = () => {
  expect(conn.execute.mock.calls.filter(c => /INSERT INTO/.test(c[0]))).toHaveLength(0);
  expect(conn.rollback).toHaveBeenCalled();
  expect(https.request).not.toHaveBeenCalled();
};

describe.each([
  ['a single booking', '/api/bookings', booking],
  ['a family visit',   '/api/bookings/family', family],
])('%s', (_name, path, body) => {
  test('a changed price is refused with nothing saved', async () => {
    checkItemPrices.mockResolvedValue({ ok: false, message: 'price changed' });
    const res = await post(path, { ...body, ...paid });
    expect(res.status).toBe(409);
    expect(res.body.message).toBe('price changed');
    expect(verifyRazorpayPayment).not.toHaveBeenCalled();
    nothingSaved();
  });

  test('a payment Razorpay does not confirm is refused with nothing saved', async () => {
    verifyRazorpayPayment.mockResolvedValue({ ok: false, message: 'not confirmed' });
    const res = await post(path, { ...body, ...paid });
    expect(res.status).toBe(402);
    expect(res.body.message).toBe('not confirmed');
    nothingSaved();
  });

  test('Pay Later never calls Razorpay', async () => {
    const res = await post(path, { ...body, paymentType: 'pay_later' });
    expect(res.status).toBe(201);
    expect(verifyRazorpayPayment).not.toHaveBeenCalled();
  });
});

test('the app\'s own total is ignored: Razorpay is checked against the server total', async () => {
  await post('/api/bookings', { ...booking, ...paid, totalAmount: 1 });
  expect(verifyRazorpayPayment).toHaveBeenCalledWith('pay_x', { amount: 500, checkReuse: true });
});

test('a family visit is checked against every member added together', async () => {
  await post('/api/bookings/family', { ...family, ...paid });
  expect(verifyRazorpayPayment).toHaveBeenCalledWith('pay_x', { amount: 1000, checkReuse: true });
});

test.each([
  ['/api/bookings', booking],
  ['/api/bookings/family', family],
])('%s refuses a patient on another account', async (path, body) => {
  conn.execute.mockImplementation(async (sql) => (
    /FROM ip_patients/.test(sql) ? [[{ patient_id_ref: null, client_id: 9999 }]] : [[]]
  ));
  const res = await post(path, { ...body, paymentType: 'pay_later' });
  expect(res.status).toBe(403);
  expect(conn.rollback).toHaveBeenCalled();
  expect(conn.commit).not.toHaveBeenCalled();
});

describe('POST /api/bookings/:bookingId/pay', () => {
  const owed = (total, paidSoFar = 0) => conn.execute.mockImplementation(async (sql) => (
    /FROM ip_bookings/.test(sql)
      ? [[{ booking_id: 900, patient_id: 501, total_amount: total, amount_paid: paidSoFar, status: 'pending' }]]
      : [{}]
  ));

  test('a payment smaller than the amount due is refused', async () => {
    owed(500);
    const res = await post('/api/bookings/900/pay', { razorpayPaymentId: 'pay_x', amount: 100 });
    expect(res.status).toBe(400);
    expect(verifyRazorpayPayment).not.toHaveBeenCalled();
  });

  test('a payment Razorpay does not confirm is refused', async () => {
    owed(500);
    verifyRazorpayPayment.mockResolvedValue({ ok: false, message: 'not confirmed' });
    const res = await post('/api/bookings/900/pay', { razorpayPaymentId: 'pay_x', amount: 500 });
    expect(res.status).toBe(402);
    expect(conn.commit).not.toHaveBeenCalled();
  });

  test('paying the remaining balance after an earlier payment works', async () => {
    owed(500, 300);
    const res = await post('/api/bookings/900/pay', { razorpayPaymentId: 'pay_x', amount: 200 });
    expect(res.status).toBe(200);
    expect(verifyRazorpayPayment).toHaveBeenCalledWith('pay_x', { amount: 200, checkReuse: true });
  });
});
