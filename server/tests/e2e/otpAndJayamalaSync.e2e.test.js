// IT — OTP verification integration + the consolidated Jayamala
// visit_completed integration (the single most critical scenario in the
// brief). Driven over the real HTTP wire against the real running server.
//
// Unlike every other e2e file, this one deliberately does NOT mock
// services/clientSync.js — the whole point is to prove the real sync module
// runs for real when OTP is verified over the real wire, builds ONE real
// consolidated request, and that none of the old individual technician-side
// sync actions ('package_added', 'family_member_added', technician-side
// 'collection_photo_added') ever fire — confirmed by grepping the actual
// controllers first (only bookingController.js's payBooking, a CUSTOMER
// action, still fires 'payment_update'; nothing fires the other three
// anymore). Only the deepest real I/O boundary — Node's http module, which
// clientSync.js's internal postJson() uses — is mocked, exactly like
// tests/integration/visitCompletedSync.test.js.
jest.mock('../../config/db');
jest.mock('../../config/settings');
jest.mock('../../utils/sms');
jest.mock('../../config/firebase', () => ({ messaging: null })); // defense-in-depth — this flow shouldn't reach it, but never risk a real Admin SDK call
const db       = require('../../config/db');
const settings = require('../../config/settings');
const sms      = require('../../utils/sms');
const http     = require('http');
const jwt      = require('jsonwebtoken');
const { startRealServer } = require('../helpers/realServer');

let server;
beforeAll(async () => { server = await startRealServer(); });
afterAll(async () => { await server.close(); });

const realHttpRequest = http.request;
afterEach(() => { http.request = realHttpRequest; }); // see mockNetwork.js's leak warning

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

const techToken = jwt.sign(
  { id: 17, userId: 501, mobile: '9000000001', role: 'technician', branchId: 3 },
  process.env.JWT_SECRET, { expiresIn: '30d' }
);

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  sms.sendBookingOtp.mockReset().mockResolvedValue('101');
  settings.getBool.mockReset().mockReturnValue(true);
  settings.get.mockReset().mockReturnValue('10000');
});

function primeAuth() { db.execute.mockResolvedValueOnce([[{ user_auth_token: techToken }]]); }

function techPost(path, body) {
  return fetch(`${server.url}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${techToken}` },
    body: JSON.stringify(body),
  });
}

describe('OTP verification integration (real wire)', () => {
  test('wrong OTP is rejected and does not trigger any sync', async () => {
    primeAuth();
    db.execute.mockResolvedValueOnce([[{ collection_otp: '1234', otp_attempts: 0, is_expired: 0 }]]);
    const capture = mockJayamalaHttp({ status: 'success' });

    const res = await techPost('/api/technicians/booking-otp/verify', { bookingId: 900, otp: '0000' });
    expect(res.status).toBe(401);
    expect(http.request).not.toHaveBeenCalled();
    expect(capture()).toBeNull();
  });

  test('expired OTP is rejected', async () => {
    primeAuth();
    db.execute.mockResolvedValueOnce([[{ collection_otp: '1234', otp_attempts: 0, is_expired: 1 }]]);
    const res = await techPost('/api/technicians/booking-otp/verify', { bookingId: 900, otp: '1234' });
    expect(res.status).toBe(400);
    expect((await res.json()).expired).toBe(true);
  });

  test('the attempt limit locks out further tries', async () => {
    primeAuth();
    db.execute.mockResolvedValueOnce([[{ collection_otp: '1234', otp_attempts: 3, is_expired: 0 }]]);
    const res = await techPost('/api/technicians/booking-otp/verify', { bookingId: 900, otp: '0000' });
    expect(res.status).toBe(429);
  });

  test('verifying against an unassigned booking is rejected', async () => {
    primeAuth();
    db.execute.mockResolvedValueOnce([[]]);
    const res = await techPost('/api/technicians/booking-otp/verify', { bookingId: 999999, otp: '1234' });
    expect(res.status).toBe(404);
  });
});

describe('Consolidated Jayamala integration — real clientSync.js, real HTTP boundary mocked only (real wire)', () => {
  test('correct OTP produces ONE consolidated visit_completed request carrying package, payment, and photo — and updates collection_status to otp_verified', async () => {
    primeAuth();
    db.execute
      // verifyBookingOtp itself:
      .mockResolvedValueOnce([[{ collection_otp: '1234', otp_attempts: 0, is_expired: 0 }]]) // OTP check
      .mockResolvedValueOnce([{}])                              // UPDATE ip_technician_collection -> otp_verified
      .mockResolvedValueOnce([{}])                              // mirror UPDATE ip_patient_bookings
      .mockResolvedValueOnce([[{ visit_group_id: null }]])      // no sibling group — solo booking
      // syncVisitCompletionToClient (real, unmocked module) picks up from here:
      .mockResolvedValueOnce([[{ booking_id: 900, booking_ref: 'BK900', patient_id: 501, status: 'completed', bill_id: null, visit_group_id: null }]]) // primaryBooking
      .mockResolvedValueOnce([[{ booking_id: 900, booking_ref: 'BK900', booking_type: 'home_collection', booking_date: '2026-09-01', total_amount: 1000, patient_id: 501, client_id: 10, status: 'completed', bill_id: null, visit_group_id: null, slot_time: '10:00 AM' }]]) // single-booking branch
      .mockResolvedValueOnce([{}])                              // UPDATE client_sync_status='pending'
      .mockResolvedValueOnce([[{                                // _fetchPatientTestsPayment: patient
        patient_id: 501, patient_id_ref: 'JAYA501', patient_name: 'Ravi Kumar', patient_mobile: '9876543210',
        patient_gender: 'M', patient_city: 'Chennai', patient_address: '12 MG Road', patient_email: null,
        patient_dob: '1990-01-01', patient_age: 36, patient_relation: 'Self', health_conditions: null, patient_photo: null,
      }]])
      .mockResolvedValueOnce([[{ booking_item_id: 1, product_id: 7, name: 'Complete Blood Count', price: 1000, document_required: 0, prescription_url: null }]]) // tests
      .mockResolvedValueOnce([[{ payment_type: 'RAZORPAY', amount_paid: 1000, amount_due: 0, gateway_transaction_id: 'pay_e2e_1' }]]) // payment
      .mockResolvedValueOnce([[{ file_path: '/uploads/collection/900_proof.jpg' }]])   // collection photo
      .mockResolvedValueOnce([[{ user_name: 'Tech Suresh' }]])  // technician name
      .mockResolvedValueOnce([{}])                              // UPDATE client_sync_status='synced'
      .mockResolvedValueOnce([{}]);                             // UPDATE bill_id

    const capture = mockJayamalaHttp({ status: 'success', bill_id: 55555 });

    const res = await techPost('/api/technicians/booking-otp/verify', { bookingId: 900, otp: '1234' });
    expect(res.status).toBe(200);
    expect((await res.json()).success).toBe(true);

    // Exactly ONE outbound request — the consolidated visit_completed call.
    expect(http.request).toHaveBeenCalledTimes(1);
    const payload = capture();
    expect(payload.action).toBe('visit_completed');
    expect(payload.bookings).toHaveLength(1);
    const entry = payload.bookings[0];
    expect(entry.blood_test_list[0]).toMatchObject({ id: 7, name: 'Complete Blood Count', price: 1000 });
    expect(entry.payment_details).toMatchObject({ total_amount: 1000, paid_amount: 1000, payment_type: 'full payment' });
    expect(entry.proof_photo).toBe('/uploads/collection/900_proof.jpg');
    expect(entry.patient_id).toBe('JAYA501'); // top-level patient identification requirement
    expect(payload.patient_id).toBe('JAYA501'); // required at the request root too, not just per-booking

    // The DB write confirming collection_status really became otp_verified.
    const statusUpdate = db.execute.mock.calls.find(c =>
      c[0].includes('ip_technician_collection') && c[0].includes("collection_status") && c[0].includes("'otp_verified'"));
    expect(statusUpdate).toBeDefined();
  });

  test('a family visit produces ONE consolidated request with one bookings[] entry per member', async () => {
    primeAuth();
    db.execute
      .mockResolvedValueOnce([[{ collection_otp: '1234', otp_attempts: 0, is_expired: 0 }]])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([[{ visit_group_id: 'VG_E2E' }]])   // sibling group found
      .mockResolvedValueOnce([{ affectedRows: 1 }])              // cascade UPDATE ip_technician_collection
      .mockResolvedValueOnce([{ affectedRows: 1 }])              // cascade UPDATE ip_patient_bookings
      // syncVisitCompletionToClient:
      .mockResolvedValueOnce([[{ booking_id: 900, booking_ref: 'BK900', patient_id: 501, status: 'completed', bill_id: null, visit_group_id: 'VG_E2E' }]])
      .mockResolvedValueOnce([[
        { booking_id: 900, booking_ref: 'BK900', booking_type: 'home_collection', booking_date: '2026-09-01', total_amount: 700, patient_id: 501, client_id: 10, status: 'completed', bill_id: null, visit_group_id: 'VG_E2E', slot_time: '10:00 AM' },
        { booking_id: 901, booking_ref: 'BK901', booking_type: 'home_collection', booking_date: '2026-09-01', total_amount: 300, patient_id: 502, client_id: 10, status: 'completed', bill_id: null, visit_group_id: 'VG_E2E', slot_time: '10:00 AM' },
      ]])
      .mockResolvedValueOnce([{}]) // pending
      .mockResolvedValueOnce([[{ patient_id: 501, patient_id_ref: 'JAYA501', patient_name: 'Ravi Kumar', patient_mobile: '9876543210', patient_gender: 'M', patient_city: 'Chennai', patient_address: 'MG Road', patient_email: null, patient_dob: '1990-01-01', patient_age: 36, patient_relation: 'Self', health_conditions: null, patient_photo: null }]])
      .mockResolvedValueOnce([[{ booking_item_id: 1, product_id: 7, name: 'CBC', price: 700, document_required: 0, prescription_url: null }]])
      .mockResolvedValueOnce([[{ payment_type: 'PAY_LATER', amount_paid: 0, amount_due: 700, gateway_transaction_id: null }]])
      .mockResolvedValueOnce([[]])
      .mockResolvedValueOnce([[{ patient_id: 502, patient_id_ref: null, patient_name: 'Meena Kumar', patient_mobile: '9876500002', patient_gender: 'F', patient_city: 'Chennai', patient_address: 'MG Road', patient_email: null, patient_dob: '1992-05-05', patient_age: 34, patient_relation: 'Daughter', health_conditions: null, patient_photo: null }]])
      .mockResolvedValueOnce([[{ booking_item_id: 2, product_id: 9, name: 'Lipid Profile', price: 300, document_required: 0, prescription_url: null }]])
      .mockResolvedValueOnce([[{ payment_type: 'PAY_LATER', amount_paid: 0, amount_due: 300, gateway_transaction_id: null }]])
      .mockResolvedValueOnce([[]])
      .mockResolvedValueOnce([[{ user_name: 'Tech Suresh' }]])
      .mockResolvedValueOnce([{}]); // synced

    const capture = mockJayamalaHttp({ status: 'success' });
    const res = await techPost('/api/technicians/booking-otp/verify', { bookingId: 900, otp: '1234' });
    expect(res.status).toBe(200);
    expect(http.request).toHaveBeenCalledTimes(1); // still ONE consolidated request for the whole visit

    const payload = capture();
    expect(payload.visit_group_id).toBe('VG_E2E');
    expect(payload.bookings).toHaveLength(2);
    expect(payload.bookings[0].booking_ref).toBe('BK900');
    expect(payload.bookings[1].booking_ref).toBe('BK901');
    // No family member's data appears under the other's entry.
    expect(payload.bookings[0].blood_test_list[0].name).toBe('CBC');
    expect(payload.bookings[1].blood_test_list[0].name).toBe('Lipid Profile');
    expect(payload.bookings[1].patient_details.name).toBe('Meena Kumar');
  });
});
