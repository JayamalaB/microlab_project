// Confirms authController.js's writeLog() (otp.log) calls dbLogger.logOtpEvent,
// and that the raw OTP value never reaches it (the source call site masks
// it before the message is ever formed — see authController.js's sendOtp).
jest.mock('../../config/db');
jest.mock('../../utils/sms');
jest.mock('../../socket/bookingSocket', () => ({ forceTechnicianOffline: jest.fn() }));
jest.mock('../../utils/dbLogger');
const db       = require('../../config/db');
const sms      = require('../../utils/sms');
const dbLogger = require('../../utils/dbLogger');
const authController = require('../../controllers/authController');

beforeEach(() => jest.clearAllMocks());

test('sendOtp calls dbLogger.logOtpEvent and never passes the raw OTP value through', async () => {
  db.query = db.query || jest.fn();
  db.query.mockReset()
    .mockResolvedValueOnce([[{
      user_id: 42, client_id: 10, user_microlab_type: 'patient_user',
      user_auth_token: null, user_token_expiry: null, deleted_at: null,
    }]])
    .mockResolvedValueOnce([{}]);
  sms.sendLoginOtp = sms.sendLoginOtp || jest.fn();
  sms.sendLoginOtp.mockResolvedValue('OK');

  const req = { body: { mobile: '9876543210', role: 'customer' } };
  const res = { json: jest.fn(), status: jest.fn().mockReturnThis() };
  await authController.sendOtp(req, res);

  expect(dbLogger.logOtpEvent).toHaveBeenCalled();
  const allMessages = dbLogger.logOtpEvent.mock.calls.map(c => c[0]).join(' | ');
  expect(allMessages).not.toMatch(/value=\d{4}\b/);
});
