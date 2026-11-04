// Tests services/razorpayVerify.js — a payment id only counts once Razorpay
// confirms it is real, for the right amount, and not already used.
jest.mock('../../config/db');
const db = require('../../config/db');
const { verifyRazorpayPayment } = require('../../services/razorpayVerify');

const realFetch = global.fetch;
const razorpayReplies = (body, ok = true, status = 200) => {
  global.fetch = jest.fn().mockResolvedValue({ ok, status, json: async () => body });
};
const paid = (over) => ({ status: 'authorized', currency: 'INR', amount: 50000, ...over });

beforeAll(() => { jest.spyOn(console, 'warn').mockImplementation(() => {}); });
beforeEach(() => {
  process.env.RAZORPAY_KEY_ID     = 'test_key';
  process.env.RAZORPAY_KEY_SECRET = 'test_value';
  db.execute.mockReset().mockResolvedValue([[]]);
});
afterEach(() => { global.fetch = realFetch; });

test.each([['authorized'], ['captured']])('a %s payment for the right amount passes', async (status) => {
  razorpayReplies(paid({ status }));
  const r = await verifyRazorpayPayment('pay_ok1', { amount: 500 });
  expect(r).toEqual({ ok: true, amount: 500, status });
});

test('made-up text is refused without calling Razorpay', async () => {
  razorpayReplies(paid());
  for (const id of ['x', 'wallet:paytm', 'pay_../../orders', '', undefined]) {
    expect((await verifyRazorpayPayment(id, { amount: 500 })).ok).toBe(false);
  }
  expect(global.fetch).not.toHaveBeenCalled();
});

test('a payment id Razorpay does not know is refused', async () => {
  razorpayReplies({}, false, 400);
  expect((await verifyRazorpayPayment('pay_fake', { amount: 500 })).ok).toBe(false);
});

test('a failed payment is refused', async () => {
  razorpayReplies(paid({ status: 'failed' }));
  expect((await verifyRazorpayPayment('pay_x', { amount: 500 })).ok).toBe(false);
});

test('a payment for the wrong amount is refused', async () => {
  razorpayReplies(paid({ amount: 100 }));
  expect((await verifyRazorpayPayment('pay_x', { amount: 500 })).ok).toBe(false);
});

test('one paisa of rounding is allowed, and the real amount is returned', async () => {
  razorpayReplies(paid({ amount: 49999 }));
  expect(await verifyRazorpayPayment('pay_x', { amount: 500 })).toMatchObject({ ok: true, amount: 499.99 });
});

test('atLeast: a larger shared payment covers this booking\'s part', async () => {
  razorpayReplies(paid({ amount: 90000 }));
  expect((await verifyRazorpayPayment('pay_x', { amount: 500, atLeast: true })).ok).toBe(true);
  expect((await verifyRazorpayPayment('pay_x', { amount: 1000, atLeast: true })).ok).toBe(false);
});

test('checkReuse: a payment already on a booking is refused', async () => {
  razorpayReplies(paid());
  db.execute.mockResolvedValueOnce([[{ 1: 1 }]]);
  const r = await verifyRazorpayPayment('pay_x', { amount: 500, checkReuse: true });
  expect(r).toEqual({ ok: false, message: 'This payment has already been used.' });
});

test('Razorpay being unreachable is a refusal, not a pass', async () => {
  global.fetch = jest.fn().mockRejectedValue(new Error('timeout'));
  expect((await verifyRazorpayPayment('pay_x', { amount: 500 })).ok).toBe(false);
});

test('missing Razorpay keys are a refusal, not a pass', async () => {
  delete process.env.RAZORPAY_KEY_ID;
  razorpayReplies(paid());
  expect((await verifyRazorpayPayment('pay_x', { amount: 500 })).ok).toBe(false);
});
