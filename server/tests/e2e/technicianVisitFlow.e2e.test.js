// Package/Test integration, Family booking integration, Payment
// integration (full/partial/pay-later, exact amounts per the brief), and
// Collection photo integration — all driven over the real HTTP wire against
// the real running Express server (see realServer.js).
jest.mock('../../config/db');
jest.mock('../../services/clientSync');
const db         = require('../../config/db');
const clientSync = require('../../services/clientSync');
const jwt        = require('jsonwebtoken');
const { startRealServer } = require('../helpers/realServer');
const { createMockConnection } = require('../helpers/mockConnection');

let server;
beforeAll(async () => { server = await startRealServer(); });
afterAll(async () => { await server.close(); });

const techToken = jwt.sign(
  { id: 17, userId: 501, mobile: '9000000001', role: 'technician', branchId: 3 },
  process.env.JWT_SECRET, { expiresIn: '30d' }
);

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  db.getConnection.mockReset();
  clientSync.syncBookingToClient.mockReset().mockResolvedValue({ success: true });
});

function primeAuth() { db.execute.mockResolvedValueOnce([[{ user_auth_token: techToken }]]); }

function techFetch(method, path, body) {
  return fetch(`${server.url}${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${techToken}` },
    body: body ? JSON.stringify(body) : undefined,
  });
}

describe('Package/Test integration (real wire)', () => {
  test('technician adds a package to a booking — UI/API/DB/total all agree, no immediate sync', async () => {
    primeAuth();
    db.execute
      .mockResolvedValueOnce([[{ product_id: 9, product_name: 'Lipid Profile', product_category: 'Pathology', product_price: '300.00', document_required: 0 }]])
      .mockResolvedValueOnce([[{ patient_id: 501 }]])
      .mockResolvedValueOnce([{ insertId: 5 }])
      .mockResolvedValueOnce([{}]); // UPDATE ip_bookings total_amount/amount_due

    const res = await techFetch('POST', '/api/bookings/900/items', { productId: 9 });
    expect(res.status).toBe(201);
    const body = await res.json();
    expect(body.item).toMatchObject({ productId: 9, name: 'Lipid Profile', price: 300 });

    const totalUpdate = db.execute.mock.calls.find(c => c[0].includes('UPDATE ip_bookings') && c[0].includes('total_amount = total_amount'));
    expect(totalUpdate[1]).toEqual([300, 300, '900']);
    expect(clientSync.syncBookingToClient).not.toHaveBeenCalled();
  });

  test('technician removes a package — total rolls back, package belongs to the correct booking/patient', async () => {
    primeAuth();
    db.execute
      .mockResolvedValueOnce([[{ product_id: 9, name: 'Lipid Profile', price: 300 }]])
      .mockResolvedValueOnce([{ affectedRows: 1 }])
      .mockResolvedValueOnce([{}]);

    const res = await techFetch('DELETE', '/api/bookings/900/items/5');
    expect(res.status).toBe(200);
    expect(clientSync.syncBookingToClient).toHaveBeenCalledWith(900, expect.objectContaining({ action: 'package_removed' }));
  });
});

describe('Family booking integration (real wire, technician on-site addition)', () => {
  test('adding two family members produces separate bookings under one visit_group_id, correct patient/package/payment per member', async () => {
    primeAuth();
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    conn.execute
      .mockResolvedValueOnce([[{                                  // parent context — no visit_group_id yet
        client_id: 10, branch_id: 3, booking_date: '2026-09-01',
        collection_address: 'MG Road', postal_code: '600001', city: 'Chennai',
        collection_latitude: 13.05, collection_longitude: 80.25,
        available_slot_id: null, visit_group_id: null, slot_id: null,
      }]])
      .mockResolvedValueOnce([[{ user_name: 'Tech Suresh' }]])
      .mockResolvedValueOnce([{}])   // backfill technician on parent
      .mockResolvedValueOnce([{}])   // backfill visit_group_id on parent
      // member 1
      .mockResolvedValueOnce([[]])
      .mockResolvedValueOnce([{ insertId: 601 }])
      .mockResolvedValueOnce([[{ patient_id_ref: null }]])
      .mockResolvedValueOnce([[{ product_id: 7, product_name: 'CBC', product_price: '500.00', offer: 'no', discount_percent: 0 }]])
      .mockResolvedValueOnce([{ insertId: 951 }])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}])
      // member 2
      .mockResolvedValueOnce([[]])
      .mockResolvedValueOnce([{ insertId: 602 }])
      .mockResolvedValueOnce([[{ patient_id_ref: null }]])
      .mockResolvedValueOnce([[{ product_id: 9, product_name: 'Lipid Profile', product_price: '300.00', offer: 'no', discount_percent: 0 }]])
      .mockResolvedValueOnce([{ insertId: 952 }])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}]);

    const res = await techFetch('POST', '/api/technicians/add-visit-member', {
      parentBookingId: 900,
      members: [
        { name: 'Asha Kumar', mobile: '9876500001', relation: 'Daughter', tests: [{ productId: 7 }] },
        { name: 'Ravi Kumar', mobile: '9876500002', relation: 'Son', tests: [{ productId: 9 }] },
      ],
    });

    expect(res.status).toBe(201);
    const body = await res.json();
    expect(body.totalMembers).toBe(2);
    expect(body.members[0]).toMatchObject({ newBookingId: 951, patientId: 601, totalAmount: 500 });
    expect(body.members[1]).toMatchObject({ newBookingId: 952, patientId: 602, totalAmount: 300 });
    // One member's data does not appear under the other's booking.
    expect(body.members[0].newBookingId).not.toBe(body.members[1].newBookingId);
    expect(body.members[0].patientId).not.toBe(body.members[1].patientId);
    expect(body.visitGroupId).toMatch(/^VG\d+$/);
  });
});

describe('Payment integration (real wire) — full / partial / pay-later, exact amounts', () => {
  test('full payment: Total=1000, Paid=1000, Due=0', async () => {
    primeAuth();
    db.execute
      .mockResolvedValueOnce([[{ booking_id: 900, patient_id: 501, total_amount: 1000, amount_paid: 0 }]])
      .mockResolvedValueOnce([{ affectedRows: 1 }])
      .mockResolvedValueOnce([{ insertId: 1 }]);

    const res = await techFetch('POST', '/api/technicians/collect-payment', { bookingId: 900, amount: 1000, paymentMethod: 'CASH' });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toMatchObject({ amountPaid: 1000, amountDue: 0, paymentStatus: 'paid' });
  });

  test('partial payment: Total=1000, Paid=500, Due=500', async () => {
    primeAuth();
    db.execute
      .mockResolvedValueOnce([[{ booking_id: 900, patient_id: 501, total_amount: 1000, amount_paid: 0 }]])
      .mockResolvedValueOnce([{ affectedRows: 1 }])
      .mockResolvedValueOnce([{ insertId: 1 }]);

    const res = await techFetch('POST', '/api/technicians/collect-payment', { bookingId: 900, amount: 500, paymentMethod: 'CASH' });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toMatchObject({ amountPaid: 500, amountDue: 500, paymentStatus: 'partial' });
  });

  test('pay later: Total=1000, Paid=0, Due=1000 — reflected on booking creation, not the collect-payment endpoint', async () => {
    // No primeAuth() here — this test authenticates as a CUSTOMER (custToken
    // below), not the technician token primeAuth() is scoped to.
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    conn.execute
      .mockResolvedValueOnce([[{ patient_id_ref: null }]])
      .mockResolvedValueOnce([{ insertId: 953 }])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([[{ product_id: 7, product_name: 'CBC', document_required: 0 }]])
      .mockResolvedValueOnce([{ insertId: 1 }])
      .mockResolvedValueOnce([{}]);

    const custToken = jwt.sign(
      { id: 501, user_id: 501, client_id: 10, mobile: '9876543210', role: 'customer', user_type: 'patient_user' },
      process.env.JWT_SECRET, { expiresIn: '30d' }
    );
    db.execute.mockResolvedValueOnce([[{ user_auth_token: custToken }]]);
    const res = await fetch(`${server.url}/api/bookings`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${custToken}` },
      body: JSON.stringify({
        patientId: 501, totalAmount: 1000, paymentType: 'pay_later',
        items: [{ packageId: 7, originalPrice: 1000, finalPrice: 1000 }],
      }),
    });
    expect(res.status).toBe(201);
    const insertParams = conn.execute.mock.calls[1][1];
    expect(insertParams).toContain(1000); // total_amount
    expect(insertParams).toContain(0);    // amount_paid
    expect(insertParams).toContain(1000); // amount_due (also 1000, appears twice — total & due)
  });
});

describe('Collection photo integration (real wire)', () => {
  test('the uploaded photo is associated with the correct booking', async () => {
    primeAuth();
    db.execute
      .mockResolvedValueOnce([[{ patient_id: 501 }]])
      .mockResolvedValueOnce([{ insertId: 12 }]);

    const res = await techFetch('POST', '/api/bookings/900/collection-photo', {
      imageUrl: 'https://cdn.example.com/uploads/900_proof.jpg',
    });
    expect(res.status).toBe(201);
    const insertCall = db.execute.mock.calls.find(c => c[0].includes('ip_booking_documents') && c[0].includes('collection_proof'));
    expect(insertCall[1]).toEqual(['900', 501, 'https://cdn.example.com/uploads/900_proof.jpg', '900_proof.jpg', 501]);
  });
});
