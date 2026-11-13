// Tests the technician's charge packages — server/controllers/technicianController.js:
// getChargePackages, getAdditionalCharges, addAdditionalCharges,
// removeAdditionalCharge.
//
// The technician picks products instead of typing an amount; prices come
// from ip_products, each package is added to total and amount due, several
// per booking, removable, only between arrival and Sample Collected.
jest.mock('../../config/db');
const db      = require('../../config/db');
const request = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { technicianToken, primeAuthCheck } = require('../helpers/jwt');

const technicianRoutes = require('../../routes/technicians');
const app   = buildTestApp('/api/technicians', technicianRoutes);
const token = technicianToken({ id: 17 });
const auth  = (r) => r.set('Authorization', `Bearer ${token}`);

const booking = (over = {}) => ({
  booking_id: 900, status: 'assigned', total_amount: '1350.00', amount_paid: '0.00',
  payment_status: 'unpaid', additional_charge_amount: '0.00', visit_group_id: null,
  package_charges: '0.00', collection_status: 'arrived', ...over,
});
const product = (id, price, code = `T${id}`) =>
  ({ product_id: id, product_name: `Product ${id}`, test_code: code, product_price: price });

// A transaction connection whose answers are keyed on the SQL text.
function wireConn(answers) {
  const conn = {
    beginTransaction: jest.fn().mockResolvedValue(),
    commit:   jest.fn().mockResolvedValue(),
    rollback: jest.fn().mockResolvedValue(),
    release:  jest.fn(),
    execute:  jest.fn(async (sql) => {
      for (const [re, value] of answers) if (re.test(sql)) return value;
      return [{ affectedRows: 1 }];
    }),
  };
  db.getConnection.mockResolvedValue(conn);
  return conn;
}
const call = (conn, re) => conn.execute.mock.calls.filter(c => re.test(c[0]));
const bookingUpdate = (conn) => call(conn, /^\s*UPDATE ip_bookings/)[0];

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  db.getConnection.mockReset();
});

describe('GET /api/technicians/charge-packages', () => {
  test('lists every active product with its server price', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[
      { product_id: 7, product_name: 'CBC', test_code: 'T7', product_price: '350.00', product_category: 'Blood' },
      { product_id: 9, product_name: 'Home Visit 0-10 km', test_code: null, product_price: '100', product_category: null },
    ]]);
    const res = await auth(request(app).get('/api/technicians/charge-packages'));
    expect(res.status).toBe(200);
    expect(res.body.packages).toEqual([
      { productId: 7, name: 'CBC', testCode: 'T7', price: 350, category: 'Blood' },
      { productId: 9, name: 'Home Visit 0-10 km', testCode: null, price: 100, category: null },
    ]);
    expect(db.execute.mock.calls[1][0]).toMatch(/product_active = 1 AND deleted_at IS NULL/);
    expect(db.execute.mock.calls[1][0]).not.toMatch(/from_km/);
  });

  test('needs a technician login', async () => {
    expect((await request(app).get('/api/technicians/charge-packages')).status).toBe(401);
  });
});

describe('GET /api/technicians/bookings/:bookingId/additional-charges', () => {
  const url = '/api/technicians/bookings/900/additional-charges';

  test('returns the visit charges and the service charge product name', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[booking({ visit_group_id: 'VG-000900' })]])
      .mockResolvedValueOnce([[
        { charge_id: 1, booking_id: 900, product_id: 7, product_name: 'CBC', test_code: 'T7', price: '350.00', reason: null },
        { charge_id: 2, booking_id: 901, product_id: 8, product_name: 'HbA1c', test_code: 'T8', price: '400.00', reason: 'Asked on site' },
      ]])
      .mockResolvedValueOnce([[{ product_name: 'Home Collection 10-20 km' }]]);

    const res = await auth(request(app).get(url));
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      success: true,
      serviceChargeProductName: 'Home Collection 10-20 km',
      canEdit: true,
      charges: [
        { chargeId: 1, bookingId: 900, name: 'CBC', price: 350, reason: null },
        { chargeId: 2, bookingId: 901, name: 'HbA1c', price: 400, reason: 'Asked on site' },
      ],
    });
    // The whole visit: the booking or anything in its group.
    expect(db.execute.mock.calls[2][1]).toEqual([900, 'VG-000900', 'VG-000900']);
  });

  test('after Sample Collected the list is read-only', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[booking({ collection_status: 'otp_verified' })]]);
    const res = await auth(request(app).get(url));
    expect(res.body.canEdit).toBe(false);
  });

  test('a booking not assigned to this technician is refused', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[]]);
    expect((await auth(request(app).get(url))).status).toBe(404);
  });
});

describe('POST /api/technicians/bookings/:bookingId/additional-charges', () => {
  const url  = '/api/technicians/bookings/900/additional-charges';
  const post = (body) => auth(request(app).post(url)).send(body);

  test('adds several packages at their database prices', async () => {
    primeAuthCheck(db, token);
    const conn = wireConn([
      [/FROM ip_bookings b/, [[booking()]]],
      [/FROM ip_products/, [[product(7, '350.00'), product(8, '99.50')]]],
    ]);

    const res = await post({ productIds: [7, 8], reason: '  Doctor asked  ' });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      success: true, additionalChargeAmount: 449.5, totalAmount: 1799.5, amountDue: 1799.5, paymentStatus: 'unpaid',
    });

    const inserts = call(conn, /INSERT INTO ip_booking_additional_charges/);
    expect(inserts.map(c => c[1])).toEqual([
      [900, 7, 'Product 7', 'T7', 350, 'Doctor asked', 17],
      [900, 8, 'Product 8', 'T8', 99.5, 'Doctor asked', 17],
    ]);
    expect(bookingUpdate(conn)[1]).toEqual([449.5, 1799.5, 1799.5, 'unpaid', 900]);
    expect(conn.commit).toHaveBeenCalled();
    expect(conn.release).toHaveBeenCalled();
  });

  test('a price sent by the app is ignored', async () => {
    primeAuthCheck(db, token);
    const conn = wireConn([
      [/FROM ip_bookings b/, [[booking()]]],
      [/FROM ip_products/, [[product(7, '350.00')]]],
    ]);
    await post({ productIds: [7], price: 1, amount: 1 });
    expect(call(conn, /INSERT INTO/)[0][1][4]).toBe(350);
  });

  test('the reason is optional', async () => {
    primeAuthCheck(db, token);
    const conn = wireConn([
      [/FROM ip_bookings b/, [[booking()]]],
      [/FROM ip_products/, [[product(7, '350.00')]]],
    ]);
    expect((await post({ productIds: [7] })).status).toBe(200);
    expect(call(conn, /INSERT INTO/)[0][1][5]).toBeNull();
  });

  test('adds on top of charges already on the booking, after a part payment', async () => {
    primeAuthCheck(db, token);
    const conn = wireConn([
      [/FROM ip_bookings b/, [[booking({ total_amount: '1700.00', additional_charge_amount: '350.00', amount_paid: '1000.00', payment_status: 'partial' })]]],
      [/FROM ip_products/, [[product(8, '400.00')]]],
    ]);
    const res = await post({ productIds: [8] });
    expect(res.body).toMatchObject({ additionalChargeAmount: 750, totalAmount: 2100, amountDue: 1100, paymentStatus: 'partial' });
    expect(bookingUpdate(conn)[1]).toEqual([750, 2100, 1100, 'partial', 900]);
  });

  test('a fully paid booking becomes partial again', async () => {
    primeAuthCheck(db, token);
    wireConn([
      [/FROM ip_bookings b/, [[booking({ amount_paid: '1350.00', payment_status: 'paid' })]]],
      [/FROM ip_products/, [[product(7, '200.00')]]],
    ]);
    const res = await post({ productIds: [7] });
    expect(res.body).toMatchObject({ amountDue: 200, paymentStatus: 'partial' });
  });

  test('nothing selected, bad ids or a long reason are refused', async () => {
    for (const body of [{}, { productIds: [] }, { productIds: ['x'] }, { productIds: [0] }, { productIds: [7], reason: 'r'.repeat(256) }]) {
      primeAuthCheck(db, token);
      expect((await post(body)).status).toBe(400);
    }
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('a product that is inactive or gone is refused and nothing is saved', async () => {
    primeAuthCheck(db, token);
    const conn = wireConn([
      [/FROM ip_bookings b/, [[booking()]]],
      [/FROM ip_products/, [[product(7, '350.00')]]],
    ]);
    const res = await post({ productIds: [7, 8] });
    expect(res.status).toBe(409);
    expect(call(conn, /INSERT INTO/)).toHaveLength(0);
    expect(conn.rollback).toHaveBeenCalled();
  });

  test('not allowed before arrival or from OTP Verified on', async () => {
    for (const s of ['en_route', 'otp_verified', 'handed_to_lab']) {
      primeAuthCheck(db, token);
      const conn = wireConn([[/FROM ip_bookings b/, [[booking({ collection_status: s })]]]]);
      expect((await post({ productIds: [7] })).status).toBe(409);
      expect(call(conn, /INSERT INTO/)).toHaveLength(0);
    }
  });

  test('a booking not assigned to this technician is refused', async () => {
    primeAuthCheck(db, token);
    wireConn([[/FROM ip_bookings b/, [[]]]]);
    expect((await post({ productIds: [7] })).status).toBe(404);
  });

  test('the booking row is locked while the totals change', async () => {
    primeAuthCheck(db, token);
    const conn = wireConn([
      [/FROM ip_bookings b/, [[booking()]]],
      [/FROM ip_products/, [[product(7, '350.00')]]],
    ]);
    await post({ productIds: [7] });
    expect(call(conn, /FROM ip_bookings b/)[0][0]).toMatch(/FOR UPDATE$/);
  });

  test('a database error rolls back and releases the connection', async () => {
    primeAuthCheck(db, token);
    const conn = wireConn([
      [/FROM ip_bookings b/, [[booking()]]],
      [/FROM ip_products/, [[product(7, '350.00')]]],
    ]);
    conn.execute.mockImplementationOnce(async () => [[booking()]])
      .mockImplementationOnce(async () => [[product(7, '350.00')]])
      .mockImplementationOnce(async () => { throw new Error('db down'); });
    jest.spyOn(console, 'error').mockImplementationOnce(() => {});
    expect((await post({ productIds: [7] })).status).toBe(500);
    expect(conn.rollback).toHaveBeenCalled();
    expect(conn.commit).not.toHaveBeenCalled();
    expect(conn.release).toHaveBeenCalled();
  });
});

describe('DELETE /api/technicians/bookings/:bookingId/additional-charges/:chargeId', () => {
  const url = '/api/technicians/bookings/900/additional-charges/5';
  const del = () => auth(request(app).delete(url));

  test('removes one package and takes its price off', async () => {
    primeAuthCheck(db, token);
    const conn = wireConn([
      [/FROM ip_bookings b/, [[booking({ total_amount: '1700.00', additional_charge_amount: '350.00' })]]],
      [/FROM ip_booking_additional_charges/, [[{ charge_id: 5, product_id: 7, price: '350.00' }]]],
    ]);
    const res = await del();
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ additionalChargeAmount: 0, totalAmount: 1350, amountDue: 1350 });
    expect(call(conn, /SET deleted_at = NOW\(\)/)[0][1]).toEqual([5]);
    expect(bookingUpdate(conn)[1]).toEqual([0, 1350, 1350, 'unpaid', 900]);
    expect(conn.commit).toHaveBeenCalled();
  });

  test('only a charge on this booking can be removed', async () => {
    primeAuthCheck(db, token);
    const conn = wireConn([
      [/FROM ip_bookings b/, [[booking()]]],
      [/FROM ip_booking_additional_charges/, [[]]],
    ]);
    expect((await del()).status).toBe(404);
    expect(call(conn, /charges\s+WHERE charge_id = \? AND booking_id = \?/)[0][1]).toEqual([5, 900]);
    expect(conn.commit).not.toHaveBeenCalled();
  });

  test('refused when the total would go below what is already paid', async () => {
    primeAuthCheck(db, token);
    const conn = wireConn([
      [/FROM ip_bookings b/, [[booking({ total_amount: '1700.00', additional_charge_amount: '350.00', amount_paid: '1700.00', payment_status: 'paid' })]]],
      [/FROM ip_booking_additional_charges/, [[{ charge_id: 5, product_id: 7, price: '350.00' }]]],
    ]);
    const res = await del();
    expect(res.status).toBe(400);
    expect(res.body.message).toMatch(/already paid/);
    expect(call(conn, /SET deleted_at/)).toHaveLength(0);
  });

  test('not allowed from OTP Verified on', async () => {
    primeAuthCheck(db, token);
    wireConn([[/FROM ip_bookings b/, [[booking({ collection_status: 'otp_verified' })]]]]);
    expect((await del()).status).toBe(409);
  });
});

describe('PUT /additional-charge (older apps) keeps the packages', () => {
  test('replacing the typed charge leaves the package charges in the total', async () => {
    primeAuthCheck(db, token);
    // ₹350 of packages + ₹50 typed already on a ₹1750 booking.
    db.execute
      .mockResolvedValueOnce([[booking({ total_amount: '1750.00', additional_charge_amount: '400.00', package_charges: '350.00' })]])
      .mockResolvedValueOnce([{ affectedRows: 1 }]);
    const res = await auth(request(app).put('/api/technicians/bookings/900/additional-charge'))
      .send({ amount: 80, reason: 'Waited' });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ additionalChargeAmount: 430, totalAmount: 1780, amountDue: 1780 });
    expect(db.execute.mock.calls[2][1].slice(0, 3)).toEqual([430, 'Waited', 1780]);
  });
});
