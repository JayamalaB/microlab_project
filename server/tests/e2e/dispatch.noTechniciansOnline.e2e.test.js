// IT-T003 negative case — no technician online at all when a booking
// request comes in.
//
// This scenario needs its own test FILE, not just its own describe block or
// its own startRealServer() call within a shared file: bookingSocket.js's
// onlineTechnicians/fcmOnlineTechnicians Maps are module-private state that
// persists for as long as that module stays loaded — and Jest's module-
// registry isolation boundary is the test FILE, not individual describe
// blocks or however many times startRealServer() is called within one file.
// Confirmed the hard way: an earlier version of this test lived in
// dispatch.e2e.test.js right after tests that put technicians online, in
// its own describe block with its OWN fresh startRealServer() instance —
// and it still failed, because that new server still shared the same
// already-populated bookingSocket.js module/Maps as every earlier test in
// that file. Only a separate file guarantees a truly pristine dispatch
// module.
jest.mock('../../config/db');
jest.mock('../../config/firebase', () => ({ messaging: null }));
jest.mock('../../services/clientSync');
const db         = require('../../config/db');
const clientSync = require('../../services/clientSync');
const jwt        = require('jsonwebtoken');
const { startRealServer } = require('../helpers/realServer');
const { createMockConnection } = require('../helpers/mockConnection');
const { connectClient, waitForEvent } = require('../helpers/socketServer');

let server;
beforeAll(async () => { server = await startRealServer(); });
afterAll(async () => { await server.close(); });

const custToken = jwt.sign(
  { id: 501, user_id: 501, client_id: 10, mobile: '9876543210', role: 'customer', user_type: 'patient_user' },
  process.env.JWT_SECRET, { expiresIn: '30d' }
);

beforeEach(() => {
  db.execute.mockReset().mockImplementation((sql) => {
    if (sql.includes('SELECT booking_date FROM ip_bookings')) {
      return Promise.resolve([[{ booking_date: new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }) }]]);
    }
    if (sql.includes('ip_patient_tracking_metadata')) return Promise.resolve([{}]);
    if (sql.includes('document_required')) return Promise.resolve([[{ doc_required: 0 }]]);
    return Promise.resolve([[], {}]);
  });
  db.query.mockReset().mockResolvedValue([[], {}]);
  db.getConnection.mockReset();
  clientSync.syncBookingToClient.mockReset().mockResolvedValue({ success: true });
});

test('with no technician ever online, the patient is told the booking timed out (Lane 3 slot fallback also unavailable)', async () => {
  db.execute.mockResolvedValueOnce([[{ user_auth_token: custToken }]]); // REST auth check
  const conn = createMockConnection();
  db.getConnection.mockResolvedValue(conn);
  conn.execute
    .mockResolvedValueOnce([[{ patient_id_ref: null }]])
    .mockResolvedValueOnce([{ insertId: 70102 }])
    .mockResolvedValueOnce([{}])
    .mockResolvedValueOnce([[{ product_id: 7, product_name: 'CBC', document_required: 0 }]])
    .mockResolvedValueOnce([{ insertId: 1 }])
    .mockResolvedValueOnce([{}]);

  const createRes = await fetch(`${server.url}/api/bookings`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${custToken}` },
    body: JSON.stringify({
      patientId: 501, totalAmount: 878, paymentType: 'pay_later',
      items: [{ packageId: 7, originalPrice: 878, finalPrice: 878 }],
    }),
  });
  expect(createRes.status).toBe(201);
  const booking = await createRes.json();

  const patient = await connectClient(server.url);
  try {
    const timeoutPromise = waitForEvent(patient, 'booking_timeout');
    patient.emit('booking_request', {
      bookingId: booking.bookingId, patientId: 501, patientName: 'Ravi Kumar',
      hospital: 'Microlab Chennai',
    });
    await expect(timeoutPromise).resolves.toEqual({ bookingId: booking.bookingId });
  } finally {
    patient.disconnect();
  }
});
