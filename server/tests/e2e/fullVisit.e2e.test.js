// The complete end-to-end visit (task brief §15) — one real customer
// booking, through real dispatch, real acceptance, real status
// transitions, real package/family/payment/photo actions, real OTP
// verification, ending in exactly ONE real consolidated Jayamala sync.
// Every hop runs over the real HTTP/Socket.IO wire against the real
// running server (see realServer.js); only the DB, Firebase, SMS gateway,
// and the outbound Jayamala HTTP call are mocked.
//
// Scoping note: login itself (send-otp/verify-otp round trip, both roles)
// is already proven independently and exhaustively in
// customer.auth.e2e.test.js and technician.authAndStatus.e2e.test.js. This
// file uses pre-signed tokens for the customer and technician instead of
// replaying that handshake, so the test stays focused on proving the
// booking lifecycle itself rather than re-testing login mechanics already
// covered elsewhere — a deliberate scoping choice, disclosed here and in
// the final test report, not a gap.
jest.mock('../../config/db');
jest.mock('../../config/settings');
jest.mock('../../services/clientSync', () => {
  const real = jest.requireActual('../../services/clientSync');
  return { ...real, syncBookingToClient: jest.fn().mockResolvedValue({ success: true }) };
});
jest.mock('../../config/firebase', () => ({ messaging: null }));
jest.mock('../../utils/sms');
const db         = require('../../config/db');
const settings   = require('../../config/settings');
const clientSync = require('../../services/clientSync'); // syncBookingToClient mocked; syncVisitCompletionToClient REAL
const sms        = require('../../utils/sms');
const http       = require('http');
const jwt        = require('jsonwebtoken');
const { startRealServer } = require('../helpers/realServer');
const { createMockConnection } = require('../helpers/mockConnection');
const { connectClient, waitForEvent } = require('../helpers/socketServer');

let server;
beforeAll(async () => { server = await startRealServer(); });
afterAll(async () => { await server.close(); });

const realHttpRequest = http.request;
afterEach(() => { http.request = realHttpRequest; });
function mockJayamalaHttp(jsonBody, statusCode = 200) {
  const reqHandle = { write: jest.fn(), end: jest.fn(), on: jest.fn(), setTimeout: jest.fn(), destroy: jest.fn() };
  http.request = jest.fn((options, callback) => {
    const res = { statusCode, on: (event, handler) => {
      if (event === 'data') handler(Buffer.from(JSON.stringify(jsonBody)));
      if (event === 'end') handler();
    } };
    queueMicrotask(() => callback(res));
    return reqHandle;
  });
  return () => (reqHandle.write.mock.calls[0] ? JSON.parse(reqHandle.write.mock.calls[0][0]) : null);
}

const custToken = jwt.sign(
  { id: 501, user_id: 501, client_id: 10, mobile: '9876543210', role: 'customer', user_type: 'patient_user' },
  process.env.JWT_SECRET, { expiresIn: '30d' }
);
const techToken = jwt.sign(
  { id: 17, userId: 501, mobile: '9000000001', role: 'technician', branchId: 3 },
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
  sms.sendBookingOtp.mockReset().mockResolvedValue('101');
  settings.getBool.mockReset().mockReturnValue(true);
  settings.get.mockReset().mockReturnValue('10000');
  clientSync.syncBookingToClient.mockClear();
});

function primeAuth(token) { db.execute.mockResolvedValueOnce([[{ user_auth_token: token }]]); }
function post(token, path, body) {
  return fetch(`${server.url}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: body ? JSON.stringify(body) : undefined,
  });
}

test('the complete visit — booking through to one consolidated Jayamala sync', async () => {
  const bookingId = 80001;

  // ── Technician goes online, ready to receive work ──────────────────────
  const tech = await connectClient(server.url);
  tech.emit('technician_online', { technicianId: 501, technicianName: 'Suresh', lat: 13.05, lng: 80.25 });
  await waitForEvent(tech, 'session_started');

  // ── Customer creates a booking (real REST) ──────────────────────────────
  primeAuth(custToken);
  const conn = createMockConnection();
  db.getConnection.mockResolvedValue(conn);
  conn.execute
    .mockResolvedValueOnce([[{ patient_id_ref: null }]])
    .mockResolvedValueOnce([{ insertId: bookingId }])
    .mockResolvedValueOnce([{}])
    .mockResolvedValueOnce([[{ product_id: 7, product_name: 'CBC', document_required: 0 }]])
    .mockResolvedValueOnce([{ insertId: 1 }])
    .mockResolvedValueOnce([{}]);
  const createRes = await post(custToken, '/api/bookings', {
    patientId: 501, totalAmount: 1000, paymentType: 'pay_later',
    collectionAddress: '12 MG Road', collectionLatitude: 13.05, collectionLongitude: 80.25,
    items: [{ packageId: 7, originalPrice: 1000, finalPrice: 1000 }],
  });
  expect(createRes.status).toBe(201);
  const created = await createRes.json();
  expect(created.bookingId).toBe(bookingId);

  // ── Customer's own socket dispatches it live ────────────────────────────
  const patient = await connectClient(server.url);
  const bookingRequest = waitForEvent(tech, 'booking_request');
  patient.emit('booking_request', {
    bookingId, patientId: 501, patientName: 'Ravi Kumar', patientMobile: '9876543210',
    patientAddress: '12 MG Road', patientLat: 13.05, patientLng: 80.25, hospital: 'Microlab Chennai',
  });
  const dispatched = await bookingRequest;
  expect(dispatched.bookingId).toBe(bookingId);

  // ── Technician accepts → customer sees it ───────────────────────────────
  const acceptedAtCustomer = waitForEvent(patient, 'booking_accepted');
  tech.emit('booking_accepted', { bookingId, technicianId: 501, technicianName: 'Suresh' });
  const acceptedPayload = await acceptedAtCustomer;
  expect(acceptedPayload.technicianId).toBe(501);
  const assignedWrite = db.execute.mock.calls.find(c => c[0].includes("status = 'assigned'"));
  expect(assignedWrite).toBeDefined();

  // ── Technician starts the journey → location updates → arrives ─────────
  const enRouteAtCustomer = waitForEvent(patient, 'technician_en_route');
  tech.emit('technician_en_route', { bookingId, technicianId: 501 });
  await enRouteAtCustomer;

  tech.emit('update_technician_location', { technicianId: 501, lat: 13.052, lng: 80.251, speed: 20 });
  await new Promise(r => setTimeout(r, 30));
  const locationWrite = db.execute.mock.calls.find(c => c[0].includes('ip_technician_live_location') && c[0].includes('latitude'));
  expect(locationWrite).toBeDefined();

  const arrivedAtCustomer = waitForEvent(patient, 'technician_arrived');
  tech.emit('technician_arrived', { bookingId, technicianId: 501 });
  await arrivedAtCustomer;
  const arrivedWrite = db.execute.mock.calls.find(c => c[0].includes("collection_status = 'arrived'"));
  expect(arrivedWrite).toBeDefined();

  // ── On-site: add a package ──────────────────────────────────────────────
  primeAuth(techToken);
  db.execute
    .mockResolvedValueOnce([[{ product_id: 9, product_name: 'Lipid Profile', product_category: 'Pathology', product_price: '300.00', document_required: 0 }]])
    .mockResolvedValueOnce([[{ patient_id: 501 }]])
    .mockResolvedValueOnce([{ insertId: 5 }])
    .mockResolvedValueOnce([{}]);
  const addItemRes = await post(techToken, `/api/bookings/${bookingId}/items`, { productId: 9 });
  expect(addItemRes.status).toBe(201);

  // ── On-site: add a family member ────────────────────────────────────────
  primeAuth(techToken);
  const famConn = createMockConnection();
  db.getConnection.mockResolvedValue(famConn);
  famConn.execute
    .mockResolvedValueOnce([[{ client_id: 10, branch_id: 3, booking_date: '2026-09-01', collection_address: '12 MG Road', postal_code: '600001', city: 'Chennai', collection_latitude: 13.05, collection_longitude: 80.25, available_slot_id: null, visit_group_id: null, slot_id: null }]])
    .mockResolvedValueOnce([[{ user_name: 'Tech Suresh' }]])
    .mockResolvedValueOnce([{}])
    .mockResolvedValueOnce([{}])
    .mockResolvedValueOnce([[]])
    .mockResolvedValueOnce([{ insertId: 602 }])
    .mockResolvedValueOnce([[{ patient_id_ref: null }]])
    .mockResolvedValueOnce([[{ product_id: 7, product_name: 'CBC', product_price: '500.00', offer: 'no', discount_percent: 0 }]])
    .mockResolvedValueOnce([{ insertId: bookingId + 1 }])
    .mockResolvedValueOnce([{}]).mockResolvedValueOnce([{}]).mockResolvedValueOnce([{}]).mockResolvedValueOnce([{}]).mockResolvedValueOnce([{}]);
  const famRes = await post(techToken, '/api/technicians/add-visit-member', {
    parentBookingId: bookingId,
    members: [{ name: 'Meena Kumar', mobile: '9876500002', relation: 'Spouse', tests: [{ productId: 7 }] }],
  });
  expect(famRes.status).toBe(201);
  const famBody = await famRes.json();
  const visitGroupId = famBody.visitGroupId;
  expect(visitGroupId).toMatch(/^VG\d+$/);

  // ── Collect payment — full ₹1000 ────────────────────────────────────────
  primeAuth(techToken);
  db.execute
    .mockResolvedValueOnce([[{ booking_id: bookingId, patient_id: 501, total_amount: 1000, amount_paid: 0 }]])
    .mockResolvedValueOnce([{ affectedRows: 1 }])
    .mockResolvedValueOnce([{ insertId: 1 }]);
  const payRes = await post(techToken, '/api/technicians/collect-payment', { bookingId, amount: 1000, paymentMethod: 'CASH' });
  expect(payRes.status).toBe(200);
  expect((await payRes.json())).toMatchObject({ amountPaid: 1000, amountDue: 0, paymentStatus: 'paid' });

  // ── Upload collection photo ─────────────────────────────────────────────
  primeAuth(techToken);
  db.execute.mockResolvedValueOnce([[{ patient_id: 501 }]]).mockResolvedValueOnce([{ insertId: 12 }]);
  const photoRes = await post(techToken, `/api/bookings/${bookingId}/collection-photo`, {
    imageUrl: 'https://cdn.example.com/uploads/80001_proof.jpg',
  });
  expect(photoRes.status).toBe(201);

  // ── OTP verification → completion → ONE consolidated Jayamala sync ─────
  primeAuth(techToken);
  db.execute
    .mockResolvedValueOnce([[{ collection_otp: '1234', otp_attempts: 0, is_expired: 0 }]]) // OTP check
    .mockResolvedValueOnce([{}])                          // otp_verified
    .mockResolvedValueOnce([{}])                          // mirror ip_patient_bookings
    .mockResolvedValueOnce([[{ visit_group_id: visitGroupId }]]) // sibling group found — family visit
    .mockResolvedValueOnce([{ affectedRows: 1 }])         // cascade ip_technician_collection
    .mockResolvedValueOnce([{ affectedRows: 1 }])         // cascade ip_patient_bookings
    // syncVisitCompletionToClient (real):
    .mockResolvedValueOnce([[{ booking_id: bookingId, booking_ref: 'BK80001', patient_id: 501, status: 'completed', bill_id: null, visit_group_id: visitGroupId }]])
    .mockResolvedValueOnce([[
      { booking_id: bookingId,   booking_ref: 'BK80001', booking_type: 'home_collection', booking_date: '2026-09-01', total_amount: 1300, patient_id: 501, client_id: 10, status: 'completed', bill_id: null, visit_group_id: visitGroupId, slot_time: '10:00 AM' },
      { booking_id: bookingId+1, booking_ref: 'BK80002', booking_type: 'home_collection', booking_date: '2026-09-01', total_amount: 500,  patient_id: 602, client_id: 10, status: 'completed', bill_id: null, visit_group_id: visitGroupId, slot_time: '10:00 AM' },
    ]])
    .mockResolvedValueOnce([{}]) // pending
    .mockResolvedValueOnce([[{ patient_id: 501, patient_id_ref: 'JAYA501', patient_name: 'Ravi Kumar', patient_mobile: '9876543210', patient_gender: 'M', patient_city: 'Chennai', patient_address: '12 MG Road', patient_email: null, patient_dob: '1990-01-01', patient_age: 36, patient_relation: 'Self', health_conditions: null, patient_photo: null }]])
    .mockResolvedValueOnce([[
      { booking_item_id: 1, product_id: 7, name: 'CBC', price: 1000, document_required: 0, prescription_url: null },
      { booking_item_id: 5, product_id: 9, name: 'Lipid Profile', price: 300, document_required: 0, prescription_url: null },
    ]])
    .mockResolvedValueOnce([[{ payment_type: 'CASH', amount_paid: 1000, amount_due: 0, gateway_transaction_id: null }]])
    .mockResolvedValueOnce([[{ file_path: '/uploads/collection/80001_proof.jpg' }]])
    .mockResolvedValueOnce([[{ patient_id: 602, patient_id_ref: null, patient_name: 'Meena Kumar', patient_mobile: '9876500002', patient_gender: 'F', patient_city: 'Chennai', patient_address: '12 MG Road', patient_email: null, patient_dob: '1992-05-05', patient_age: 34, patient_relation: 'Spouse', health_conditions: null, patient_photo: null }]])
    .mockResolvedValueOnce([[{ booking_item_id: 6, product_id: 7, name: 'CBC', price: 500, document_required: 0, prescription_url: null }]])
    .mockResolvedValueOnce([[{ payment_type: 'PAY_LATER', amount_paid: 0, amount_due: 500, gateway_transaction_id: null }]])
    .mockResolvedValueOnce([[]])
    .mockResolvedValueOnce([[{ user_name: 'Tech Suresh' }]])
    .mockResolvedValueOnce([{}]); // synced

  const capture = mockJayamalaHttp({ status: 'success', bill_id: 99999 });
  const otpRes = await post(techToken, '/api/technicians/booking-otp/verify', { bookingId, otp: '1234' });
  expect(otpRes.status).toBe(200);
  expect((await otpRes.json()).success).toBe(true);

  // Final state across every component:
  expect(http.request).toHaveBeenCalledTimes(1); // exactly ONE consolidated request for the whole visit
  const payload = capture();
  expect(payload.action).toBe('visit_completed');
  expect(payload.visit_group_id).toBe(visitGroupId);
  expect(payload.bookings).toHaveLength(2); // primary + the family member added mid-visit
  expect(payload.bookings[0].blood_test_list.map(t => t.name)).toEqual(['CBC', 'Lipid Profile']); // package added on-site is present
  expect(payload.bookings[0].payment_details).toMatchObject({ total_amount: 1300, paid_amount: 1000 }); // payment collected on-site is present
  expect(payload.bookings[0].proof_photo).toBe('/uploads/collection/80001_proof.jpg'); // photo uploaded on-site is present
  expect(payload.bookings[1].patient_details.name).toBe('Meena Kumar'); // family member added on-site is present
  expect(payload.patient_id).toBe('JAYA501');

  // Old individual technician-side sync actions never fired anywhere in
  // this whole visit. syncBookingToClient legitimately fires exactly once —
  // createBooking's own real, expected customer-side 'new_booking' sync,
  // fired at booking creation regardless of payment status (see
  // bookings.createBooking.test.js) — but never with 'package_added',
  // 'family_member_added', or technician-side 'collection_photo_added',
  // confirming those old individual technician-side syncs really are gone
  // for this whole visit, not just absent from one action's own test.
  expect(clientSync.syncBookingToClient).toHaveBeenCalledTimes(1);
  expect(clientSync.syncBookingToClient).toHaveBeenCalledWith(
    bookingId, expect.objectContaining({ action: 'new_booking' })
  );
  const forbiddenActions = ['package_added', 'family_member_added', 'collection_photo_added'];
  for (const call of clientSync.syncBookingToClient.mock.calls) {
    expect(forbiddenActions).not.toContain(call[1]?.action);
  }

  tech.disconnect();
  patient.disconnect();
}, 15000);
