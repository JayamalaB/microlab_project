// IT-C002 — Customer Creates Booking, IT-C003 — Customer Views Booking.
// Real HTTP wire against the real Express server (see realServer.js).
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

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  db.getConnection.mockReset();
  clientSync.syncBookingToClient.mockReset().mockResolvedValue({ success: true });
});

const token = jwt.sign(
  { id: 501, user_id: 501, client_id: 10, mobile: '9876543210', role: 'customer', user_type: 'patient_user' },
  process.env.JWT_SECRET, { expiresIn: '30d' }
);

function primeAuth() { db.execute.mockResolvedValueOnce([[{ user_auth_token: token }]]); }

function authed(method, path, body) {
  return fetch(`${server.url}${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: body ? JSON.stringify(body) : undefined,
  });
}

describe('IT-C002 — Customer Creates Booking (real server)', () => {
  test('select patient → select package → create booking → confirmation, verified against DB writes', async () => {
    primeAuth();
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    conn.execute
      .mockResolvedValueOnce([[{ patient_id_ref: null }]])              // patient_id_ref lookup
      .mockResolvedValueOnce([{ insertId: 950 }])                       // INSERT ip_bookings
      .mockResolvedValueOnce([{}])                                      // UPDATE booking_ref (derived from insertId)
      .mockResolvedValueOnce([{}])                                      // INSERT ip_patient_bookings
      .mockResolvedValueOnce([[{ product_id: 7, product_name: 'Complete Blood Count', document_required: 0 }]]) // package lookup
      .mockResolvedValueOnce([{ insertId: 1 }])                         // INSERT ip_booking_items
      .mockResolvedValueOnce([{}]);                                     // INSERT ip_payment_transactions

    const res = await authed('POST', '/api/bookings', {
      patientId: 501,
      totalAmount: 878,
      paymentType: 'pay_later',
      collectionAddress: '12 MG Road, Chennai',
      collectionPincode: '600001',
      items: [{ packageId: 7, originalPrice: 878, finalPrice: 878 }],
    });

    // API result
    expect(res.status).toBe(201);
    const body = await res.json();
    expect(body.success).toBe(true);
    expect(body.bookingId).toBe(950);
    expect(body.bookingItems[0]).toMatchObject({ productId: 7, docRequired: false });
    // booking_ref is now derived from the row's own id, not a timestamp —
    // see bookingController.js's own comment on why (LT-002 fix).
    expect(body.bookingRef).toBe('BK-000950');

    // Database result — the booking row, correct patient, correct amount, correct status.
    const bookingInsertParams = conn.execute.mock.calls[1][1];
    expect(bookingInsertParams).toContain(501);   // patientId
    expect(bookingInsertParams).toContain(878);   // totalAmount
    expect(bookingInsertParams).toContain('pending'); // correct initial status for a pay-later, same-day booking
    expect(conn.commit).toHaveBeenCalled();

    // Booking item — correct package, correct booking_id.
    const itemInsertParams = conn.execute.mock.calls[5][1];
    expect(itemInsertParams).toEqual([950, 7, 'Complete Blood Count', 501, 878, 878]);
  });

  test('missing patientId is rejected before any transaction opens', async () => {
    primeAuth();
    const res = await authed('POST', '/api/bookings', { totalAmount: 500 });
    expect(res.status).toBe(400);
    expect(db.getConnection).not.toHaveBeenCalled();
  });
});

describe('IT-C003 — Customer Views Booking (real server)', () => {
  test('the booking just created is retrievable and matches what was written', async () => {
    // getBooking has no auth middleware (a finding from the earlier phase),
    // so no token is needed to reach it — reflects the app's real behavior.
    db.execute.mockResolvedValueOnce([[{
      booking_id: 950, booking_ref: 'BK950', status: 'pending',
      total_amount: 878, patient_id: 501, test_names: 'Complete Blood Count',
      items_total: 878,
    }]]);

    const res = await fetch(`${server.url}/api/bookings/950`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.booking.booking_id).toBe(950);
    expect(body.booking.total_amount).toBe(878);
    expect(body.booking.patient_id).toBe(501);
    expect(body.booking.status).toBe('pending');
  });

  test('a booking that does not exist returns 404', async () => {
    db.execute.mockResolvedValueOnce([[]]);
    const res = await fetch(`${server.url}/api/bookings/999999`);
    expect(res.status).toBe(404);
  });
});
