// Tests services/serviceCharge.js — the Home Collection service charge
// collected on the spot: worked out when a technician accepts (customer ↔
// branch being offered, up and down → ip_products km range), added to the
// bill when they arrive, worked out again on a reassignment (the difference
// goes into the bill), and never touching bookings made before this change.
jest.mock('../../config/db');
const db = require('../../config/db');
const sc = require('../../services/serviceCharge');

// ip_products km ranges (up-and-down km): 0–10 ₹75, 10–20 ₹150.
const PRODUCTS = [
  { product_id: 61, product_name: 'SAMPLE COLLECTION FEES H (75)', test_code: '06020', product_price: '75.00', from: 0, to: 10 },
  { product_id: 62, product_name: 'SAMPLE COLLECTION FEES H (150)', test_code: '06021', product_price: '150.00', from: 10.01, to: 20 },
];

// visit: the visit's ip_bookings rows (oldest first); arrived: whether the
// technician reached arrival.
function wire(visit, { arrived = false } = {}) {
  db.execute.mockReset().mockImplementation(async (sql, params = []) => {
    if (/FROM ip_products\s+WHERE from_km <= \?/.test(sql)) {
      const km = params[0];
      return [PRODUCTS.filter(p => p.from <= km && p.to >= km)];
    }
    if (/SELECT b\.booking_id, b\.status, b\.service_charge_status/.test(sql)) return [visit];
    if (/FROM ip_technician_collection tc/.test(sql)) return [arrived ? [{ arrived: 1 }] : []];
    if (/SELECT b\.booking_id, b\.service_charge_status, b\.home_collection_fare, b\.service_charge_km/.test(sql)) {
      return [visit.filter(r => r.service_charge_status != null).map(r => ({ ...r, product_name: r.product_name ?? null }))];
    }
    return [{ affectedRows: 1 }];
  });
}
const booking = (over = {}) => ({
  booking_id: 900, status: 'assigned', service_charge_status: 'pending', home_collection_fare: null,
  total_amount: '500.00', amount_paid: '0.00', payment_status: 'unpaid', ...over,
});
const updates = (re) => db.execute.mock.calls.filter(c => /^\s*UPDATE ip_bookings/.test(c[0]) && re.test(c[0]));

describe('markPending', () => {
  test('marks the booking pending on its own connection', async () => {
    const conn = { execute: jest.fn().mockResolvedValue([{}]) };
    expect(await sc.markPending(conn, 900)).toEqual({ status: 'pending' });
    expect(conn.execute.mock.calls[0]).toEqual([expect.stringMatching(/service_charge_status = 'pending'/), [900]]);
  });

  test('before the migration: skipped, the booking still goes through', async () => {
    const conn = { execute: jest.fn().mockRejectedValue(Object.assign(new Error('x'), { code: 'ER_BAD_FIELD_ERROR' })) };
    expect((await sc.markPending(conn, 900)).skipped).toMatch(/run add_service_charge_on_accept\.sql/);
  });
});

describe('calculateOnAccept', () => {
  test('Coimbatore 6.1 km → 12.2 km up and down → the ₹150 product, saved but not in the total yet', async () => {
    wire([booking()]);
    const r = await sc.calculateOnAccept(900, { servedDistanceKm: 6.1 });
    expect(r).toMatchObject({ status: 'calculated', oneWayKm: 6.1, roundTripKm: 12.2, price: 150, productName: 'SAMPLE COLLECTION FEES H (150)', carrierId: 900 });
    const [sql, params] = updates(/service_charge_status = \?/)[0];
    expect(sql).not.toMatch(/total_amount/); // not in the bill before arrival
    expect(params).toEqual([150, 62, 12.2, 6.1, 'calculated', 900]);
  });

  test('Peelamedu 2 km → 4 km → the ₹75 product', async () => {
    wire([booking()]);
    expect(await sc.calculateOnAccept(900, { servedDistanceKm: 2 })).toMatchObject({ roundTripKm: 4, price: 75 });
  });

  test('no product covers the km: no charge, status no_product', async () => {
    wire([booking()]);
    const r = await sc.calculateOnAccept(900, { servedDistanceKm: 16.2 });
    expect(r).toMatchObject({ status: 'no_product', roundTripKm: 32.4, price: null });
    expect(updates(/service_charge_status = \?/)[0][1]).toEqual([null, null, 32.4, 16.2, 'no_product', 900]);
  });

  test('a family visit: the main member carries the charge', async () => {
    wire([booking({ booking_id: 900 }), booking({ booking_id: 901, service_charge_status: null })]);
    const r = await sc.calculateOnAccept(901, { servedDistanceKm: 2 });
    expect(r.carrierId).toBe(900);
  });

  test('the main member was cancelled: the next active member takes the charge over', async () => {
    wire([booking({ booking_id: 900, status: 'cancelled' }), booking({ booking_id: 901, service_charge_status: null })]);
    const r = await sc.calculateOnAccept(900, { servedDistanceKm: 2 });
    expect(r.carrierId).toBe(901);
    expect(updates(/service_charge_status = NULL/)[0][1]).toEqual([900]);
    expect(updates(/SET service_charge_status = 'pending'/)[0][1]).toEqual([901]);
  });

  test('reassigned before arrival: the new branch\'s charge simply replaces the old one', async () => {
    wire([booking({ service_charge_status: 'calculated', home_collection_fare: '75.00' })]);
    const r = await sc.calculateOnAccept(900, { servedDistanceKm: 6.1 });
    expect(r).toMatchObject({ status: 'calculated', price: 150 });
    expect(r.difference).toBeUndefined();
  });

  test('reassigned after arrival (charge in the bill and collected): the difference becomes due', async () => {
    // ₹500 tests + ₹75 = ₹575, all paid. New branch: ₹150 → ₹75 more due.
    wire([booking({ service_charge_status: 'applied', home_collection_fare: '75.00', total_amount: '575.00', amount_paid: '575.00', payment_status: 'paid' })]);
    const r = await sc.calculateOnAccept(900, { servedDistanceKm: 6.1 });
    expect(r).toMatchObject({ status: 'applied', difference: 75, totalAmount: 650, amountDue: 75, overpaid: 0 });
    const [sql, params] = updates(/total_amount = \?/)[0];
    expect(sql).toMatch(/WHERE booking_id = \? AND service_charge_status = 'applied' AND total_amount = \?/);
    expect(params).toEqual([150, 62, 12.2, 6.1, 'applied', 650, 75, 'partial', 900, '575.00']);
  });

  test('reassigned after arrival to a nearer branch: lower total, overpaid amount reported for a manual refund', async () => {
    wire([booking({ service_charge_status: 'applied', home_collection_fare: '150.00', total_amount: '650.00', amount_paid: '650.00', payment_status: 'paid' })]);
    const r = await sc.calculateOnAccept(900, { servedDistanceKm: 2 });
    expect(r).toMatchObject({ difference: -75, totalAmount: 575, amountDue: 0, overpaid: 75 });
  });

  test('a booking made before this change keeps its booking-time fare', async () => {
    wire([booking({ service_charge_status: null, home_collection_fare: '75.00' })]);
    const r = await sc.calculateOnAccept(900, { servedDistanceKm: 6.1 });
    expect(r.skipped).toMatch(/booking-time fare kept/);
    expect(updates(/./)).toHaveLength(0);
  });

  test('unknown distance: skipped, nothing changed', async () => {
    wire([booking()]);
    expect((await sc.calculateOnAccept(900, { servedDistanceKm: null })).skipped).toMatch(/distance unknown/);
    expect(updates(/./)).toHaveLength(0);
  });
});

describe('applyOnArrival', () => {
  test('adds the charge to total and amount due', async () => {
    wire([booking({ service_charge_status: 'calculated', home_collection_fare: '150.00' })]);
    const r = await sc.applyOnArrival(900);
    expect(r).toMatchObject({ status: 'applied', fare: 150, totalAmount: 650, amountDue: 650 });
    const [sql, params] = updates(/service_charge_status = 'applied'/)[0];
    expect(sql).toMatch(/AND service_charge_status = 'calculated' AND total_amount = \?/);
    expect(params).toEqual([650, 650, 'unpaid', 900, '500.00']);
  });

  test('tests already paid online: the service charge is due, payment becomes partial', async () => {
    wire([booking({ service_charge_status: 'calculated', home_collection_fare: '75.00', amount_paid: '500.00', payment_status: 'paid' })]);
    expect(await sc.applyOnArrival(900)).toMatchObject({ totalAmount: 575, amountDue: 75 });
    expect(updates(/service_charge_status = 'applied'/)[0][1][2]).toBe('partial');
  });

  test('applied only once', async () => {
    wire([booking({ service_charge_status: 'applied', home_collection_fare: '75.00' })]);
    expect((await sc.applyOnArrival(900)).skipped).toMatch(/applied/);
  });

  test('no product: nothing to add', async () => {
    wire([booking({ service_charge_status: 'no_product' })]);
    expect((await sc.applyOnArrival(900)).skipped).toMatch(/no_product/);
  });
});

describe('applyIfArrived', () => {
  test('applies when the visit is at arrival or later', async () => {
    wire([booking({ service_charge_status: 'calculated', home_collection_fare: '75.00' })], { arrived: true });
    expect(await sc.applyIfArrived(900)).toMatchObject({ status: 'applied' });
  });
  test('waits while the technician is on the way', async () => {
    wire([booking({ service_charge_status: 'calculated', home_collection_fare: '75.00' })], { arrived: false });
    expect((await sc.applyIfArrived(900)).skipped).toMatch(/not arrived/);
  });
});

describe('view', () => {
  test('before arrival: km known, amount and product hidden', async () => {
    wire([booking({ service_charge_status: 'calculated', home_collection_fare: '150.00', service_charge_km: '12.20', home_collection_distance_km: '6.10', product_name: 'X' })]);
    expect(await sc.view(900)).toEqual({ status: 'calculated', carrierBookingId: 900, productName: null, oneWayKm: 6.1, roundTripKm: 12.2, amount: null });
  });
  test('after arrival: product, km and amount', async () => {
    wire([booking({ service_charge_status: 'applied', home_collection_fare: '150.00', service_charge_km: '12.20', home_collection_distance_km: '6.10', product_name: 'SAMPLE COLLECTION FEES H (150)' })]);
    expect(await sc.view(900)).toMatchObject({ status: 'applied', productName: 'SAMPLE COLLECTION FEES H (150)', amount: 150, roundTripKm: 12.2 });
  });
  test('a booking made before this change: status null', async () => {
    wire([booking({ service_charge_status: null })]);
    expect(await sc.view(900)).toEqual({ status: null });
  });
});
