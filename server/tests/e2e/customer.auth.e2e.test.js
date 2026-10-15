// IT-C001 — Customer Login, driven over a REAL running Express server (not
// Supertest's in-memory request()) — genuine HTTP requests hit the real
// authController end to end. Only the DB, Firebase, and the SMS gateway are
// mocked (the three genuine external boundaries — see realServer.js header).
//
// Real app flow this exercises (screens/shared/login_screen.dart →
// otp_screen.dart, confirmed by reading both in the prior functional-test
// phase): enter mobile → POST /api/auth/send-otp → OTP screen → enter code
// → POST /api/auth/verify-otp → token issued → app routes to
// CustomerHomeScreen. This file proves the backend half of that pipe for
// real; the Flutter-side navigation is covered separately in the web
// integration_test suite (client/integration_test/).
jest.mock('../../config/db');
jest.mock('../../config/firebase', () => ({ messaging: null }));
jest.mock('../../utils/sms');
const db  = require('../../config/db');
const sms = require('../../utils/sms');
const jwt = require('jsonwebtoken');
const { startRealServer } = require('../helpers/realServer');

let server;
beforeAll(async () => { server = await startRealServer(); });
afterAll(async () => { await server.close(); });

// global.fetch is used BOTH by this file's own post()/fetch() calls to the
// real server AND by the app's internal fetchFromRegistry(Jayamala lookup).
// mockFetchOnce() replaces global.fetch wholesale, so it must be restored
// after any test that uses it — otherwise every fetch() call after it in
// this file (including this file's own requests to the real server) gets
// intercepted by the leftover mock instead of ever reaching the network.
// See tests/helpers/mockNetwork.js's header for the full story — this was
// caught the hard way while writing this exact file.
const realFetch = global.fetch;
afterEach(() => { global.fetch = realFetch; });

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  sms.sendLoginOtp.mockClear();
});

function post(path, body) {
  return fetch(`${server.url}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

describe('IT-C001 — Customer Login (real server)', () => {
  test('send-otp → verify-otp → authenticated home succeeds end to end', async () => {
    // Step 1: request OTP for a brand-new number — real registration path.
    db.query
      .mockResolvedValueOnce([[]])
      .mockResolvedValueOnce([{ insertId: 501 }])
      .mockResolvedValueOnce([{ insertId: 10 }])
      .mockResolvedValueOnce([{}]);
    const otpRes = await post('/api/auth/send-otp', { mobile: '9876543210', role: 'customer' });
    expect(otpRes.status).toBe(200);
    const otpBody = await otpRes.json();
    expect(otpBody.success).toBe(true);
    expect(sms.sendLoginOtp).toHaveBeenCalledWith('9876543210', expect.any(String));

    // Step 2: verify with the code the mocked DB says is on file (the real
    // random OTP generated internally by sendOtp is irrelevant here — the
    // mocked DB is the single source of truth verifyOtp actually reads from,
    // exactly like every request the real MySQL layer would serve).
    db.query
      .mockResolvedValueOnce([{ affectedRows: 1 }]) // atomic OTP consume — matched
      .mockResolvedValueOnce([[{
        user_id: 501, client_id: 10, user_name: 'user_9876543210',
        user_microlab_type: 'patient_user', user_mobile_no: '9876543210',
      }]])   // fetch user by mobile
      .mockResolvedValueOnce([[]])   // no existing ip_patients row → new patient
      .mockResolvedValueOnce([{ insertId: 900 }]) // INSERT ip_patients
      .mockResolvedValueOnce([{}]); // unconditional session claim
    // Deliberately NOT mocking global.fetch here: process.env.CLIENT_PATIENT_URL
    // is unset in tests/setupEnv.js, so authController.js's customer-path
    // fetchFromRegistry(undefined, ...) call throws immediately (invalid URL,
    // never reaches the network) — and that call is wrapped in its own
    // non-fatal try/catch (unlike the technician path, which isn't), so
    // verifyOtp just continues with phpPatients=[]. Mocking global.fetch here
    // would only reintroduce the leak this file's header comment describes.
    const verifyRes = await post('/api/auth/verify-otp', { mobile: '9876543210', otp: '1234', role: 'customer' });
    expect(verifyRes.status).toBe(200);
    const verifyBody = await verifyRes.json();
    expect(verifyBody.success).toBe(true);
    expect(verifyBody.data.token).toEqual(expect.any(String));
    // is_new_user drives OtpScreen's real navigation branch: true routes to
    // CompleteProfileScreen, false routes straight to CustomerHomeScreen.
    expect(typeof verifyBody.data.is_new_user).toBe('boolean');
  });

  test('wrong OTP is rejected over the real wire, matching the OTP screen error path', async () => {
    db.query.mockResolvedValueOnce([{ affectedRows: 0 }]); // atomic consume — no matching row
    const res = await post('/api/auth/verify-otp', { mobile: '9876543210', otp: '0000', role: 'customer' });
    expect(res.status).toBe(401);
    const body = await res.json();
    expect(body.message).toMatch(/invalid or expired/i);
  });

  test('expired OTP is rejected the same way as a wrong one', async () => {
    db.query.mockResolvedValueOnce([{ affectedRows: 0 }]); // expiry filter excludes the row from the UPDATE's match
    const res = await post('/api/auth/verify-otp', { mobile: '9876543210', otp: '1234', role: 'customer' });
    expect(res.status).toBe(401);
  });

  test('malformed mobile number is rejected before any DB round trip', async () => {
    const res = await post('/api/auth/send-otp', { mobile: '12345', role: 'customer' });
    expect(res.status).toBe(422);
    expect(db.query).not.toHaveBeenCalled();
  });

  test('logout over the real wire clears the session', async () => {
    const token = jwt.sign(
      { id: 501, user_id: 501, client_id: 10, mobile: '9876543210', role: 'customer', user_type: 'patient_user' },
      process.env.JWT_SECRET, { expiresIn: '30d' }
    );
    db.execute.mockResolvedValueOnce([[{ user_auth_token: token }]]); // auth middleware's own session check
    db.query.mockResolvedValueOnce([{ affectedRows: 1 }]);           // logout's own UPDATE

    const res = await fetch(`${server.url}/api/auth/logout`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.json()).success).toBe(true);
  });
});
