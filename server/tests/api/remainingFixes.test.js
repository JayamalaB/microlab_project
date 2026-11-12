// The smaller fixes: refunds cover everything paid, the cancel cutoff uses the
// real time, technician and top-up payments are captured, family fare errors
// reach the customer, tech-location, and upload file types.
jest.mock('../../config/db');
jest.mock('../../config/settings');
jest.mock('../../services/clientSync');
jest.mock('../../services/razorpayVerify', () => ({ verifyRazorpayPayment: jest.fn() }));
jest.mock('../../services/razorpayCapture', () => ({ captureRazorpayPayment: jest.fn() }));
jest.mock('../../services/itemPrices', () => ({ checkItemPrices: async () => ({ ok: true }) }));
jest.mock('../../socket/bookingSocket', () => ({
  triggerScheduledDispatch: jest.fn(),
  freeTechnician: jest.fn(),
  unassignAndRedispatch: jest.fn(),
  stopDispatch: jest.fn(),
  redispatchBooking: jest.fn(),
  forceTechnicianOffline: jest.fn(),
}));
const db         = require('../../config/db');
const settings   = require('../../config/settings');
const clientSync = require('../../services/clientSync');
const { verifyRazorpayPayment } = require('../../services/razorpayVerify');
const { captureRazorpayPayment } = require('../../services/razorpayCapture');
const request    = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { customerToken, technicianToken, primeAuthCheck } = require('../helpers/jwt');
const { createMockConnection } = require('../helpers/mockConnection');

const bookings    = buildTestApp('/api/bookings', require('../../routes/bookings'));
const technicians = buildTestApp('/api/technicians', require('../../routes/technicians'));
const uploads     = buildTestApp('/api/upload', require('../../routes/upload'));
const custToken = customerToken({ clientId: 2001 });
const techToken = technicianToken({ id: 17 });

beforeAll(() => { jest.spyOn(console, 'error').mockImplementation(() => {}); });
beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  db.getConnection.mockReset();
  settings.getBool.mockReset().mockImplementation((_k, def) => def);
  settings.get.mockReset().mockImplementation((_k, def) => def);
  settings.getList.mockReset().mockImplementation((_k, def) => def);
  clientSync.syncBookingToClient.mockReset().mockResolvedValue({ success: true });
  verifyRazorpayPayment.mockReset();
  captureRazorpayPayment.mockClear();
});

describe('cancelling', () => {
  const row = (over) => ({
    booking_id: 900, booking_ref: 'B1', status: 'pending', booking_type: 'lab_visit', total_amount: 1000,
    available_slot_id: 55, booking_date: '2099-01-01', patient_id: 501, visit_group_id: null,
    amount_paid: 800, items_total: 1000, ...over,
  });
  function wire(booking, slotTime) {
    primeAuthCheck(db, custToken);
    db.execute.mockImplementation(async (sql) => {
      if (/SELECT b\.booking_id, b\.booking_ref, b\.status/.test(sql)) return [[booking]];
      if (/SELECT slot_time FROM ip_available_slots/.test(sql)) return [[{ slot_time: slotTime }]];
      return /^\s*SELECT/.test(sql) ? [[]] : [{ affectedRows: 1 }];
    });
  }
  const cancel = () => request(bookings).post('/api/bookings/900/cancel')
    .set('Authorization', `Bearer ${custToken}`).send({});

  test('the refund is worked out from everything paid, not the latest payment', async () => {
    wire(row());
    await cancel();
    const [lookup] = db.execute.mock.calls.find(c => /SELECT b\.booking_id, b\.booking_ref, b\.status/.test(c[0]));
    expect(lookup).toMatch(/COALESCE\(b\.amount_paid, 0\)/);
    expect(lookup).not.toMatch(/ip_payment_transactions/);
    const [, params] = db.execute.mock.calls.find(c => /SET status = 'cancelled'/.test(c[0]));
    expect(params[1]).toBe(800); // refund_amount
  });

  describe('with a 60-minute cutoff', () => {
    // Today's date and a time, both in IST, the given minutes from now.
    const istIn = (minutes) => {
      const ist = new Date(Date.now() + (330 + minutes) * 60000).toISOString();
      return { date: ist.slice(0, 10), time: `${ist.slice(11, 16)}:00` };
    };
    beforeEach(() => {
      settings.get.mockImplementation((k, def) => (k === 'cancel_cutoff_minutes' ? '60' : def));
    });

    test('a slot two hours away can still be cancelled', async () => {
      const { date, time } = istIn(120);
      wire(row({ booking_date: date }), time);
      expect((await cancel()).status).toBe(200);
    });

    test('a slot thirty minutes away cannot', async () => {
      const { date, time } = istIn(30);
      wire(row({ booking_date: date }), time);
      expect((await cancel()).status).toBe(400);
    });
  });
});

describe('technician Razorpay collection', () => {
  function collect(payment) {
    verifyRazorpayPayment.mockResolvedValue(payment);
    primeAuthCheck(db, techToken);
    db.execute
      .mockResolvedValueOnce([[{ booking_id: 900, patient_id: 55, total_amount: 500, amount_paid: 0 }]])
      .mockResolvedValueOnce([{ affectedRows: 1 }])
      .mockResolvedValueOnce([{ insertId: 1 }]);
    return request(technicians).post('/api/technicians/collect-payment')
      .set('Authorization', `Bearer ${techToken}`)
      .send({ bookingId: 900, amount: 500, paymentMethod: 'RAZORPAY', razorpayPaymentId: 'pay_x' });
  }

  test('an authorised payment is captured in full', async () => {
    const res = await collect({ ok: true, amount: 900, status: 'authorized' });
    expect(res.status).toBe(200);
    expect(captureRazorpayPayment).toHaveBeenCalledWith('pay_x', 900);
  });

  test('a payment already captured, like the next share of a family payment, is not captured again', async () => {
    await collect({ ok: true, amount: 900, status: 'captured' });
    expect(captureRazorpayPayment).not.toHaveBeenCalled();
  });

  test('a payment Razorpay does not confirm records nothing', async () => {
    const res = await collect({ ok: false, message: 'not confirmed' });
    expect(res.status).toBe(402);
    expect(db.execute.mock.calls.some(c => /UPDATE ip_bookings/.test(c[0]))).toBe(false);
  });
});

test('a family Home Collection visit without a collection location is refused', async () => {
  primeAuthCheck(db, custToken);
  db.getConnection.mockResolvedValue(createMockConnection());
  const res = await request(bookings).post('/api/bookings/family')
    .set('Authorization', `Bearer ${custToken}`)
    .send({ members: [{ patientId: 501 }, { patientId: 502 }], bookingType: 'home_collection' }); // no pickup location
  expect(res.status).toBe(422);
  expect(res.body.code).toBe('MISSING_COORDINATES');
});

describe('GET /api/bookings/:bookingId/tech-location', () => {
  const call = () => request(bookings).get('/api/bookings/900/tech-location')
    .set('Authorization', `Bearer ${custToken}`);

  test('gives the technician\'s last position', async () => {
    primeAuthCheck(db, custToken);
    db.execute
      .mockResolvedValueOnce([[{ 1: 1 }]])
      .mockResolvedValueOnce([[{ lat: '13.05', lng: '80.25' }]]);
    const res = await call();
    expect(res.body).toEqual({ success: true, lat: 13.05, lng: 80.25 });
  });

  test('is 404 before any position is known', async () => {
    primeAuthCheck(db, custToken);
    db.execute.mockResolvedValueOnce([[{ 1: 1 }]]).mockResolvedValueOnce([[]]);
    expect((await call()).status).toBe(404);
  });
});

describe('uploads', () => {
  const upload = (filename) => {
    primeAuthCheck(db, custToken);
    return request(uploads).post('/api/upload').set('Authorization', `Bearer ${custToken}`)
      .attach('photo', Buffer.from('x'), filename);
  };

  test.each([['page.html'], ['script.js'], ['image.svg']])('%s is refused', async (name) => {
    const res = await upload(name);
    expect(res.status).toBe(422);
  });

  test.each([['photo.jpg'], ['SCAN.PDF']])('%s is accepted', async (name) => {
    const res = await upload(name);
    expect(res.status).toBe(200);
    require('fs').unlinkSync(require('path').join(__dirname, '..', '..', 'uploads', res.body.url.split('/').pop()));
  });
});
