// Tests POST /api/technicians/booking-otp/{generate,verify,resend} —
// technicianController.js: generateBookingOtp, verifyBookingOtp, resendBookingOtp
//
// verifyBookingOtp no longer sends the consolidated visit_completed sync —
// that moved to the Handed to Lab step (socket/bookingSocket.js
// 'handed_to_lab'), so the success path asserts it is NOT called. The sync's
// own payload-building logic is covered separately in
// tests/integration/visitCompletedSync — this file mocks the whole clientSync
// module, since here we're only verifying verifyBookingOtp's own DB writes
// and status-machine rules.
jest.mock('../../config/db');
jest.mock('../../utils/sms');
jest.mock('../../services/clientSync');
const db          = require('../../config/db');
const sms         = require('../../utils/sms');
const clientSync  = require('../../services/clientSync');
const request     = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { technicianToken, primeAuthCheck } = require('../helpers/jwt');

const technicianRoutes = require('../../routes/technicians');
const app = buildTestApp('/api/technicians', technicianRoutes);
const token = technicianToken({ id: 17 });

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  sms.sendBookingOtp.mockReset().mockResolvedValue('101');
  clientSync.syncVisitCompletionToClient.mockReset().mockResolvedValue({ success: true });
});

// The auth middleware's DB check always runs first, so primeAuthCheck must
// always be queued before any controller-level mockResolvedValueOnce —
// callers of this helper are expected to call primeAuthCheck(db, token)
// themselves BEFORE queuing their own mocks, then use this just to fire
// the actual request.
function post(path, body) {
  return request(app).post(path).set('Authorization', `Bearer ${token}`).send(body);
}

describe('POST /api/technicians/booking-otp/generate', () => {
  test('rejects an unauthenticated request', async () => {
    const res = await request(app).post('/api/technicians/booking-otp/generate').send({ bookingId: 900 });
    expect(res.status).toBe(401);
  });

  test('rejects a request missing bookingId', async () => {
    primeAuthCheck(db, token);
    const res = await post('/api/technicians/booking-otp/generate', {});
    expect(res.status).toBe(400);
  });

  test('a booking not assigned to this technician is rejected', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[]]); // lookup finds nothing
    const res = await post('/api/technicians/booking-otp/generate', { bookingId: 900 });
    expect(res.status).toBe(404);
  });

  // TC-OTP-01 — the resolved mobile is masked in the response (never the
  // full number), and the "send" goes through the mocked SMS gateway.
  test('generates and stores an OTP, sending it to the resolved mobile', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[{ patient_mobile: '9876543210', patient_name: 'Test Patient', raw_patient_mobile: '9876543210', created_by: null }]])
      .mockResolvedValueOnce([{ affectedRows: 1 }]); // UPDATE collection_otp

    const res = await post('/api/technicians/booking-otp/generate', { bookingId: 900 });

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.maskedMobile).toBe('987****210');
    expect(sms.sendBookingOtp).toHaveBeenCalledWith('9876543210', expect.stringMatching(/^\d{4}$/));
  });
});

describe('POST /api/technicians/booking-otp/verify', () => {
  test('rejects a request missing bookingId or otp', async () => {
    primeAuthCheck(db, token);
    const res = await post('/api/technicians/booking-otp/verify', { bookingId: 900 });
    expect(res.status).toBe(400);
  });

  test('an assignment that does not exist is rejected', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[]]);
    const res = await post('/api/technicians/booking-otp/verify', { bookingId: 900, otp: '1234' });
    expect(res.status).toBe(404);
  });

  test('rejects verification before an OTP was ever generated', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[{ collection_otp: null, otp_attempts: 0, is_expired: 0 }]]);
    const res = await post('/api/technicians/booking-otp/verify', { bookingId: 900, otp: '1234' });
    expect(res.status).toBe(400);
    expect(res.body.message).toMatch(/generate OTP first/i);
  });

  // TC-OTP-02 — negative case: 3 wrong attempts already used (default
  // OTP_MAX_ATTEMPTS=3 from tests/setupEnv.js) locks out further tries.
  test('locks out verification after the max attempt count is reached', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[{ collection_otp: '1234', otp_attempts: 3, is_expired: 0 }]]);
    const res = await post('/api/technicians/booking-otp/verify', { bookingId: 900, otp: '0000' });
    expect(res.status).toBe(429);
    expect(res.body.attemptsExhausted).toBe(true);
  });

  // TC-OTP-03 — an expired OTP is rejected distinctly from a wrong one
  // (expired:true in the body), telling the client UI to offer resend.
  test('rejects an expired OTP', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[{ collection_otp: '1234', otp_attempts: 0, is_expired: 1 }]]);
    const res = await post('/api/technicians/booking-otp/verify', { bookingId: 900, otp: '1234' });
    expect(res.status).toBe(400);
    expect(res.body.expired).toBe(true);
  });

  // TC-OTP-04 — a wrong OTP increments the attempt counter and reports the
  // attempts remaining, without ever touching the syncVisitCompletionToClient path.
  test('an incorrect OTP increments the attempt counter', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[{ collection_otp: '1234', otp_attempts: 1, is_expired: 0 }]])
      .mockResolvedValueOnce([{}]); // UPDATE otp_attempts + 1

    const res = await post('/api/technicians/booking-otp/verify', { bookingId: 900, otp: '0000' });

    expect(res.status).toBe(400); // not 401 — the app signs out on any 401
    expect(res.body.message).toMatch(/1 attempt remaining/i);
    expect(clientSync.syncVisitCompletionToClient).not.toHaveBeenCalled();
  });

  // TC-OTP-05 — the full success path for a single (non-family) booking:
  // status flips to otp_verified, the ip_patient_bookings mirror runs, no
  // visit_group_id means the sibling cascade is skipped. The ASMX
  // visit_completed sync is NOT sent here any more — it moved to the Handed
  // to Lab step (socket/bookingSocket.js 'handed_to_lab').
  test('a correct OTP verifies a standalone booking and does NOT send the visit_completed sync', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[{ collection_otp: '1234', otp_attempts: 0, is_expired: 0 }]]) // OTP check
      .mockResolvedValueOnce([[{ paid: '500.00', due: '0.00' }]]) // visit payment — paid, no reason needed
      .mockResolvedValueOnce([{}])                              // UPDATE ip_technician_collection → otp_verified
      .mockResolvedValueOnce([{}])                              // mirror UPDATE ip_patient_bookings
      .mockResolvedValueOnce([[{ visit_group_id: null }]]);     // no sibling group — cascade skipped

    const res = await post('/api/technicians/booking-otp/verify', { bookingId: 900, otp: '1234' });

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    expect(db.execute).toHaveBeenCalledTimes(6); // auth check + the 5 above
    expect(clientSync.syncVisitCompletionToClient).not.toHaveBeenCalled();
  });

  // TC-OTP-06 — a family visit: verifying OTP on ONE sibling cascades
  // otp_verified to every other booking sharing the same visit_group_id,
  // in both ip_technician_collection and ip_patient_bookings.
  test('a correct OTP on a family visit cascades otp_verified to sibling bookings', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[{ collection_otp: '1234', otp_attempts: 0, is_expired: 0 }]])
      .mockResolvedValueOnce([[{ paid: '200.00', due: '300.00' }]]) // visit payment — part paid
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([[{ visit_group_id: 'VG123' }]])   // sibling group found
      .mockResolvedValueOnce([{ affectedRows: 1 }])             // cascade UPDATE ip_technician_collection
      .mockResolvedValueOnce([{ affectedRows: 1 }]);            // cascade UPDATE ip_patient_bookings

    const res = await post('/api/technicians/booking-otp/verify', { bookingId: 900, otp: '1234' });

    expect(res.status).toBe(200);
    // auth check + 7 controller calls (incl. the visit payment check)
    expect(db.execute).toHaveBeenCalledTimes(8);
    expect(db.execute.mock.calls[6][0]).toMatch(/ip_technician_collection tc/);
    expect(db.execute.mock.calls[6][1]).toEqual(['VG123', 900]);
    expect(db.execute.mock.calls[7][0]).toMatch(/ip_patient_bookings pb/);
  });
});

describe('POST /api/technicians/booking-otp/resend', () => {
  test('rejects while the 60-second cooldown is active', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[{ 1: 1 }]]); // cooldown row present
    const res = await post('/api/technicians/booking-otp/resend', { bookingId: 900 });
    expect(res.status).toBe(429);
    expect(sms.sendBookingOtp).not.toHaveBeenCalled();
  });

  test('resends a fresh OTP once the cooldown has passed', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[]])   // no active cooldown row
      .mockResolvedValueOnce([[{ patient_mobile: '9876543210', raw_patient_mobile: '9876543210', created_by: null }]])
      .mockResolvedValueOnce([{ affectedRows: 1 }]); // UPDATE collection_otp

    const res = await post('/api/technicians/booking-otp/resend', { bookingId: 900 });

    expect(res.status).toBe(200);
    expect(sms.sendBookingOtp).toHaveBeenCalled();
  });
});

// OTP without any payment toward the visit: allowed only with a reason, which
// is saved like a partial-payment reason (ip_bookings.partial_payment_reason).
describe('POST /api/technicians/booking-otp/verify — nothing paid', () => {
  const correctOtp = [[{ collection_otp: '1234', otp_attempts: 0, is_expired: 0 }]];
  const nothingPaid = [[{ paid: '0.00', due: '500.00' }]];

  test('nothing paid and no reason: refused, the OTP is not used up', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce(correctOtp).mockResolvedValueOnce(nothingPaid);
    const res = await post('/api/technicians/booking-otp/verify', { bookingId: 900, otp: '1234' });
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('NO_PAYMENT_REASON_REQUIRED');
    expect(db.execute.mock.calls.some(c => /collection_status\s+= 'otp_verified'/.test(c[0]))).toBe(false);
    expect(db.execute.mock.calls.some(c => /otp_attempts = otp_attempts \+ 1/.test(c[0]))).toBe(false);
  });

  test('a blank reason counts as none', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce(correctOtp).mockResolvedValueOnce(nothingPaid);
    const res = await post('/api/technicians/booking-otp/verify', { bookingId: 900, otp: '1234', noPaymentReason: '   ' });
    expect(res.status).toBe(400);
  });

  test('nothing paid with a reason: verified, and the reason saved for the visit', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce(correctOtp)
      .mockResolvedValueOnce(nothingPaid)
      .mockResolvedValueOnce([{}])                           // otp_verified
      .mockResolvedValueOnce([{}])                           // mirror
      .mockResolvedValueOnce([[{ visit_group_id: null }]]);  // no family
    const res = await post('/api/technicians/booking-otp/verify', {
      bookingId: 900, otp: '1234', noPaymentReason: '  Customer will pay at report delivery  ',
    });
    expect(res.status).toBe(200);
    const saved = db.execute.mock.calls.find(c => /SET b\.partial_payment_reason = \?/.test(c[0]));
    expect(saved[1]).toEqual([900, 'Customer will pay at report delivery', 900]);
  });

  test('a wrong OTP is still just a wrong OTP, reason or not', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[{ collection_otp: '1234', otp_attempts: 0, is_expired: 0 }]]).mockResolvedValueOnce([{}]);
    const res = await post('/api/technicians/booking-otp/verify', { bookingId: 900, otp: '0000', noPaymentReason: 'x' });
    expect(res.status).toBe(400);
    expect(res.body.message).toMatch(/Incorrect OTP/);
  });

  test('nothing due at all (₹0 visit): no reason needed', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce(correctOtp)
      .mockResolvedValueOnce([[{ paid: '0.00', due: '0.00' }]])
      .mockResolvedValueOnce([{}]).mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([[{ visit_group_id: null }]]);
    const res = await post('/api/technicians/booking-otp/verify', { bookingId: 900, otp: '1234' });
    expect(res.status).toBe(200);
  });
});
