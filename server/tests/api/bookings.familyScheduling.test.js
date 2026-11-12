// Tests POST /api/bookings/family — the status a visit is saved with, and the
// Razorpay capture of the one payment that covers every member.
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
jest.mock('../../config/settings');
jest.mock('../../services/clientSync');
const https      = require('https');
const db         = require('../../config/db');
const settings   = require('../../config/settings');
const clientSync = require('../../services/clientSync');
const request    = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { customerToken, primeAuthCheck } = require('../helpers/jwt');
const { createMockConnection } = require('../helpers/mockConnection');

const app   = buildTestApp('/api/bookings', require('../../routes/bookings'));
const token = customerToken({});

const TODAY  = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
const FUTURE = '2099-01-01';
const member = (patientId, price) => ({ patientId, totalAmount: price, items: [{ packageId: 7, finalPrice: price }] });
const STATUS_PARAM = 7; // index of status in the ip_bookings INSERT params

let conn;
let captureBody;
const realRequest = https.request;

beforeEach(() => {
  process.env.RAZORPAY_KEY_ID     = 'test_key';
  process.env.RAZORPAY_KEY_SECRET = 'test_value';
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  settings.getBool.mockReset().mockReturnValue(true);
  settings.get.mockReset().mockReturnValue('4');
  clientSync.syncBookingToClient.mockReset().mockResolvedValue({ success: true });

  let id = 900;
  conn = createMockConnection();
  conn.execute.mockImplementation(async (sql) => {
    if (/INSERT INTO ip_bookings/.test(sql)) return [{ insertId: id++ }];
    return /^\s*SELECT/.test(sql) ? [[]] : [{}];
  });
  db.getConnection.mockReset().mockResolvedValue(conn);

  captureBody = null;
  https.request = jest.fn(() => ({ on: jest.fn(), write: (b) => { captureBody = JSON.parse(b); }, end: jest.fn() }));
});
afterEach(() => { https.request = realRequest; });

function post(body) {
  primeAuthCheck(db, token);
  return request(app).post('/api/bookings/family').set('Authorization', `Bearer ${token}`)
    .send({ members: [member(501, 700), member(502, 350.5)], bookingType: 'lab_visit', ...body });
}
const insertedStatuses = () => conn.execute.mock.calls
  .filter(c => /INSERT INTO ip_bookings/.test(c[0])).map(c => c[1][STATUS_PARAM]);
const confirmed = () => conn.execute.mock.calls.filter(c => /SET status = 'confirmed'/.test(c[0]));

test('Pay Now succeeds and captures the combined total of all members', async () => {
  const res = await post({ collectionDate: TODAY, paymentType: 'full', razorpayPaymentId: 'pay_fam123' });

  expect(res.status).toBe(201);
  expect(captureBody).toEqual({ amount: 105050, currency: 'INR' });
  expect(https.request.mock.calls[0][0].path).toBe('/v1/payments/pay_fam123/capture');
  expect(clientSync.syncBookingToClient).toHaveBeenCalledTimes(2);
});

test('a same-day visit is pending, and paid moves it to confirmed', async () => {
  const res = await post({ collectionDate: TODAY, paymentType: 'full', razorpayPaymentId: 'pay_fam123' });

  expect(insertedStatuses()).toEqual(['pending', 'pending']);
  expect(confirmed()).toHaveLength(2);
  expect(res.body.isScheduled).toBe(false);
});

test('a future visit is scheduled on every member', async () => {
  const res = await post({ collectionDate: FUTURE, paymentType: 'pay_later' });

  expect(res.status).toBe(201);
  expect(insertedStatuses()).toEqual(['scheduled', 'scheduled']);
  expect(res.body.isScheduled).toBe(true);
  expect(captureBody).toBeNull();
});

test('a paid future visit stays scheduled, so the scheduler still picks it up', async () => {
  const res = await post({ collectionDate: FUTURE, paymentType: 'full', razorpayPaymentId: 'pay_fam123' });

  expect(insertedStatuses()).toEqual(['scheduled', 'scheduled']);
  expect(confirmed()).toHaveLength(0);
  expect(res.body.isScheduled).toBe(true);
});
