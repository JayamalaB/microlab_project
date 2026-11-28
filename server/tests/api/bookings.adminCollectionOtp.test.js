// Admin portal — collection OTP:
//   POST /api/bookings/:bookingId/collection-otp/send
//   POST /api/bookings/:bookingId/collection-otp/verify
// Same HMAC check (adminAuth) as /dispatch; the OTP rules are the ones the
// technician app uses (technicianController: issueCollectionOtp /
// verifyCollectionOtp), applied to the booking's assigned technician.
// Dummy secret only.
jest.mock('../../config/db');
jest.mock('../../utils/sms');
jest.mock('../../services/clientSync');
jest.mock('../../services/dynamicKeyService', () => {
  const actual = jest.requireActual('../../services/dynamicKeyService');
  return { ...actual, getActiveEncryptedValue: jest.fn() };
});
jest.mock('../../socket/bookingSocket', () => {
  const actual = jest.requireActual('../../socket/bookingSocket');
  const mocked = Object.assign(function bookingSocket() {}, actual);
  mocked._setVisitBookingStatus = jest.fn();
  mocked.emitCollectionOtpVerified = jest.fn();
  return mocked;
});

const crypto  = require('crypto');
const request = require('supertest');
const db      = require('../../config/db');
const sms     = require('../../utils/sms');
const { getActiveEncryptedValue } = require('../../services/dynamicKeyService');
const bookingSocket = require('../../socket/bookingSocket');
const { buildTestApp } = require('../helpers/testApp');
const bookingRoutes = require('../../routes/bookings');

const app = buildTestApp('/api/bookings', bookingRoutes);
const SECRET = 'test-only-dummy-admin-secret';
const TECH_ID = 17;

function signedPost(path, bookingId, body = {}, { secret = SECRET, headers = true } = {}) {
  const ts  = Math.floor(Date.now() / 1000).toString();
  const sig = crypto.createHmac('sha256', secret).update(`${bookingId}|${ts}`).digest('hex');
  const req = request(app).post(path).send(body);
  if (headers) req.set('X-Admin-Timestamp', ts).set('X-Admin-Signature', sig);
  return req;
}
const send   = (id, opts) => signedPost(`/api/bookings/${id}/collection-otp/send`, id, {}, opts);
const verify = (id, body, opts) => signedPost(`/api/bookings/${id}/collection-otp/verify`, id, body, opts);

// The first query of both endpoints: booking + assigned technician.
const target = (over = {}) => [[{
  booking_id: 600, booking_status: 'sample_collected',
  technician_id: TECH_ID, collection_status: 'sample_collected', ...over,
}]];

beforeAll(() => {
  jest.spyOn(console, 'log').mockImplementation(() => {});
  jest.spyOn(console, 'warn').mockImplementation(() => {});
  jest.spyOn(console, 'error').mockImplementation(() => {});
});
beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  sms.sendBookingOtp.mockReset().mockResolvedValue('101');
  getActiveEncryptedValue.mockReset().mockResolvedValue(SECRET);
  bookingSocket._setVisitBookingStatus.mockClear();
  bookingSocket.emitCollectionOtpVerified.mockClear();
});

describe('admin signature (same as /dispatch)', () => {
  test('no admin headers → 403, nothing runs', async () => {
    const res = await send(600, { headers: false });
    expect(res.status).toBe(403);
    expect(db.execute).not.toHaveBeenCalled();
    expect(sms.sendBookingOtp).not.toHaveBeenCalled();
  });

  test('signed with the wrong secret → 403', async () => {
    const res = await verify(600, { otp: '1234' }, { secret: 'wrong-secret' });
    expect(res.status).toBe(403);
    expect(db.execute).not.toHaveBeenCalled();
  });
});

describe('POST /:bookingId/collection-otp/send', () => {
  test('booking not found → 404 BOOKING_NOT_FOUND', async () => {
    db.execute.mockResolvedValueOnce([[]]);
    const res = await send(600);
    expect(res.status).toBe(404);
    expect(res.body.code).toBe('BOOKING_NOT_FOUND');
  });

  test('cancelled booking → 409 CANCELLED', async () => {
    db.execute.mockResolvedValueOnce(target({ booking_status: 'cancelled' }));
    const res = await send(600);
    expect(res.status).toBe(409);
    expect(res.body.code).toBe('CANCELLED');
  });

  test('no technician assigned → 404 NO_TECHNICIAN', async () => {
    db.execute.mockResolvedValueOnce(target({ technician_id: null, collection_status: null }));
    const res = await send(600);
    expect(res.status).toBe(404);
    expect(res.body.code).toBe('NO_TECHNICIAN');
  });

  test.each(['otp_verified', 'handed_to_lab_pending', 'handed_to_lab'])(
    'already past the OTP (%s) → 409 ALREADY_VERIFIED', async (step) => {
      db.execute.mockResolvedValueOnce(target({ collection_status: step }));
      const res = await send(600);
      expect(res.status).toBe(409);
      expect(res.body.code).toBe('ALREADY_VERIFIED');
      expect(sms.sendBookingOtp).not.toHaveBeenCalled();
    });

  test.each(['assigned', 'en_route'])(
    'technician not at the customer yet (%s) → 409 WRONG_STAGE', async (step) => {
      db.execute.mockResolvedValueOnce(target({ collection_status: step }));
      const res = await send(600);
      expect(res.status).toBe(409);
      expect(res.body.code).toBe('WRONG_STAGE');
      expect(res.body.currentStep).toBe(step);
    });

  test('sent less than 60 seconds ago → 429 RESEND_COOLDOWN, no SMS', async () => {
    db.execute
      .mockResolvedValueOnce(target())
      .mockResolvedValueOnce([[{ 1: 1 }]]); // cooldown row present
    const res = await send(600);
    expect(res.status).toBe(429);
    expect(res.body.code).toBe('RESEND_COOLDOWN');
    expect(sms.sendBookingOtp).not.toHaveBeenCalled();
  });

  test('sends the OTP: stored on the assigned technician row, SMSed, never returned', async () => {
    db.execute
      .mockResolvedValueOnce(target({ collection_status: 'arrived' }))
      .mockResolvedValueOnce([[]])                                    // no cooldown
      .mockResolvedValueOnce([[{ patient_mobile: '9876543210', raw_patient_mobile: '9876543210', created_by: null }]])
      .mockResolvedValueOnce([{ affectedRows: 1 }]);                  // UPDATE collection_otp

    const res = await send(600);

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ success: true, maskedMobile: '987****210' });
    const [, stored] = db.execute.mock.calls[3];
    expect(stored[0]).toMatch(/^\d{4}$/);
    expect(stored.slice(2)).toEqual([600, TECH_ID]);
    expect(sms.sendBookingOtp).toHaveBeenCalledWith('9876543210', stored[0]);
    expect(JSON.stringify(res.body)).not.toContain(stored[0]);
  });
});

describe('POST /:bookingId/collection-otp/verify', () => {
  const otpRow = (over = {}) => [[{ collection_otp: '1234', otp_attempts: 0, is_expired: 0, ...over }]];

  test.each([[{}], [{ otp: '12' }], [{ otp: 'abcd' }]])(
    'missing or malformed otp %j → 400 OTP_REQUIRED', async (body) => {
      const res = await verify(600, body);
      expect(res.status).toBe(400);
      expect(res.body.code).toBe('OTP_REQUIRED');
      expect(db.execute).not.toHaveBeenCalled();
    });

  test('already verified → 409 ALREADY_VERIFIED', async () => {
    db.execute.mockResolvedValueOnce(target({ collection_status: 'otp_verified' }));
    const res = await verify(600, { otp: '1234' });
    expect(res.status).toBe(409);
    expect(res.body.code).toBe('ALREADY_VERIFIED');
  });

  test('no OTP sent yet → 400 OTP_NOT_GENERATED', async () => {
    db.execute.mockResolvedValueOnce(target()).mockResolvedValueOnce(otpRow({ collection_otp: null }));
    const res = await verify(600, { otp: '1234' });
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('OTP_NOT_GENERATED');
  });

  test('wrong OTP → 400 OTP_INVALID with attempts left, counter goes up', async () => {
    db.execute.mockResolvedValueOnce(target()).mockResolvedValueOnce(otpRow()).mockResolvedValueOnce([{}]);
    const res = await verify(600, { otp: '0000' });
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('OTP_INVALID');
    expect(res.body.attemptsRemaining).toBe(2);
    expect(db.execute.mock.calls[2][0]).toMatch(/otp_attempts = otp_attempts \+ 1/);
    expect(db.execute.mock.calls[2][1]).toEqual([600, TECH_ID]);
  });

  test('expired OTP → 400 OTP_EXPIRED', async () => {
    db.execute.mockResolvedValueOnce(target()).mockResolvedValueOnce(otpRow({ is_expired: 1 }));
    const res = await verify(600, { otp: '1234' });
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('OTP_EXPIRED');
  });

  test('attempts used up → 429 TOO_MANY_ATTEMPTS', async () => {
    db.execute.mockResolvedValueOnce(target()).mockResolvedValueOnce(otpRow({ otp_attempts: 3 }));
    const res = await verify(600, { otp: '1234' });
    expect(res.status).toBe(429);
    expect(res.body.code).toBe('TOO_MANY_ATTEMPTS');
  });

  test('nothing paid and no reason → 400 NO_PAYMENT_REASON_REQUIRED, OTP not used up', async () => {
    db.execute
      .mockResolvedValueOnce(target())
      .mockResolvedValueOnce(otpRow())
      .mockResolvedValueOnce([[{ paid: '0.00', due: '500.00' }]]);
    const res = await verify(600, { otp: '1234' });
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('NO_PAYMENT_REASON_REQUIRED');
    expect(db.execute.mock.calls.some(c => /collection_status\s+= 'otp_verified'/.test(c[0]))).toBe(false);
  });

  test('correct OTP: verified for the assigned technician, booking status + socket updated', async () => {
    db.execute
      .mockResolvedValueOnce(target())
      .mockResolvedValueOnce(otpRow())
      .mockResolvedValueOnce([[{ paid: '500.00', due: '0.00' }]])
      .mockResolvedValueOnce([{}])                            // ip_technician_collection → otp_verified
      .mockResolvedValueOnce([{}])                            // ip_patient_bookings mirror
      .mockResolvedValueOnce([[{ visit_group_id: null }]]);   // no family

    const res = await verify(600, { otp: '1234', verifiedBy: 'Priya' });

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ success: true });
    expect(db.execute.mock.calls[3][0]).toMatch(/collection_status\s+= 'otp_verified'/);
    expect(db.execute.mock.calls[3][1]).toEqual([600, TECH_ID]);
    expect(db.execute.mock.calls[4][0]).toMatch(/UPDATE ip_patient_bookings SET collection_status = 'otp_verified'/);
    expect(bookingSocket._setVisitBookingStatus).toHaveBeenCalledWith(600, 'otp_verified');
    expect(bookingSocket.emitCollectionOtpVerified).toHaveBeenCalledWith(600, TECH_ID, 'admin (Priya)');
  });

  test('family visit: every member moves to otp_verified', async () => {
    db.execute
      .mockResolvedValueOnce(target())
      .mockResolvedValueOnce(otpRow())
      .mockResolvedValueOnce([[{ paid: '200.00', due: '300.00' }]])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([[{ visit_group_id: 'VG9' }]])
      .mockResolvedValueOnce([{ affectedRows: 1 }])
      .mockResolvedValueOnce([{ affectedRows: 1 }]);

    const res = await verify(600, { otp: '1234' });

    expect(res.status).toBe(200);
    expect(db.execute.mock.calls[6][0]).toMatch(/ip_technician_collection tc/);
    expect(db.execute.mock.calls[6][1]).toEqual(['VG9', 600]);
    expect(db.execute.mock.calls[7][0]).toMatch(/ip_patient_bookings pb/);
  });

  test('nothing paid with a reason: verified and the reason saved', async () => {
    db.execute
      .mockResolvedValueOnce(target())
      .mockResolvedValueOnce(otpRow())
      .mockResolvedValueOnce([[{ paid: '0.00', due: '500.00' }]])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([[{ visit_group_id: null }]]);

    const res = await verify(600, { otp: '1234', noPaymentReason: 'Customer pays at the lab' });

    expect(res.status).toBe(200);
    const saved = db.execute.mock.calls.find(c => /SET b\.partial_payment_reason = \?/.test(c[0]));
    expect(saved[1]).toEqual([600, 'Customer pays at the lab', 600]);
  });
});
