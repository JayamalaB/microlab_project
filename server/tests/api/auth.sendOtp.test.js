// Tests POST /api/auth/send-otp — server/controllers/authController.js: sendOtp
//
// Covers: TC-AUTH-01 (registration/new number), TC-AUTH-02 (existing number),
// TC-AUTH-03 (soft-deleted account blocked), TC-AUTH-04 (existing active
// session no longer blocks a fresh OTP — the uninstall/reinstall fix),
// TC-AUTH-05 (invalid mobile format).
jest.mock('../../config/db');
jest.mock('../../utils/sms'); // never let a test send a real SMS — see utils/__mocks__/sms.js
const db      = require('../../config/db');
const sms     = require('../../utils/sms');
const request = require('supertest');
const { buildTestApp } = require('../helpers/testApp');

const authRoutes = require('../../routes/auth');
const app = buildTestApp('/api/auth', authRoutes);

beforeEach(() => {
  // mockReset (not mockClear) so no queued mockResolvedValueOnce leaks
  // between tests — but that also wipes the safe default from the manual
  // mock file, so it's reapplied here for any call a given test doesn't
  // explicitly care about.
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  sms.sendLoginOtp.mockClear();
});

describe('POST /api/auth/send-otp', () => {
  // TC-AUTH-05 — negative case: malformed input never reaches the database.
  test('rejects a mobile number that fails the 10-digit Indian-number format', async () => {
    const res = await request(app)
      .post('/api/auth/send-otp')
      .send({ mobile: '12345', role: 'customer' });

    expect(res.status).toBe(422);
    expect(res.body.success).toBe(false);
    // No DB call at all — the regex check in sendOtp runs before any query.
    expect(db.query).not.toHaveBeenCalled();
  });

  // TC-AUTH-01 — a brand-new number is treated as registration: an ip_users
  // row (and a linked ip_clients row) gets created, then an OTP is "sent".
  test('a brand-new mobile number gets registered and sent an OTP', async () => {
    db.query
      .mockResolvedValueOnce([[]])                       // SELECT existing — none found
      .mockResolvedValueOnce([{ insertId: 9001 }])        // INSERT ip_users
      .mockResolvedValueOnce([{ insertId: 5001 }])        // INSERT ip_clients
      .mockResolvedValueOnce([{}]);                       // UPDATE ip_users SET client_id

    const res = await request(app)
      .post('/api/auth/send-otp')
      .send({ mobile: '9876543210', role: 'customer' });

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    // 4 db.query calls in this exact order proves the registration path ran:
    // look up → insert user → insert client → link client_id back.
    expect(db.query).toHaveBeenCalledTimes(4);
    expect(db.query.mock.calls[1][0]).toMatch(/INSERT INTO ip_users/);
    expect(db.query.mock.calls[2][0]).toMatch(/INSERT INTO ip_clients/);
    // Confirms the SMS "gateway" that ran was the mock, not a real network
    // call — and that it was actually invoked, for this exact number.
    expect(sms.sendLoginOtp).toHaveBeenCalledWith('9876543210', expect.any(String));
  });

  // TC-AUTH-02 — an existing, active number just gets a fresh OTP written.
  test('an existing active number gets its OTP refreshed, no new row created', async () => {
    db.query
      .mockResolvedValueOnce([[{
        user_id: 42, client_id: 10, user_microlab_type: 'patient_user',
        user_auth_token: null, user_token_expiry: null, deleted_at: null,
      }]])
      .mockResolvedValueOnce([{}]); // UPDATE ip_users SET user_otp=...

    const res = await request(app)
      .post('/api/auth/send-otp')
      .send({ mobile: '9876543210', role: 'customer' });

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    expect(db.query).toHaveBeenCalledTimes(2);
    expect(db.query.mock.calls[1][0]).toMatch(/UPDATE ip_users/);
  });

  // TC-AUTH-03 — soft-deleted account (this session's new feature): must be
  // rejected before any OTP is generated or sent, with an explicit message,
  // and must NOT fall through to the "treat as new user" registration path.
  test('a soft-deleted account is rejected before an OTP is ever sent', async () => {
    db.query.mockResolvedValueOnce([[{
      user_id: 42, client_id: 10, user_microlab_type: 'patient_user',
      user_auth_token: null, user_token_expiry: null,
      deleted_at: '2026-01-01 00:00:00',
    }]]);

    const res = await request(app)
      .post('/api/auth/send-otp')
      .send({ mobile: '9876543210', role: 'customer' });

    expect(res.status).toBe(403);
    expect(res.body.success).toBe(false);
    expect(res.body.message).toMatch(/deleted/i);
    // Only the one lookup happened — nothing else was written.
    expect(db.query).toHaveBeenCalledTimes(1);
  });

  // TC-AUTH-04 — an existing number with an unexpired session on file (a
  // real device logged in elsewhere, or an uninstalled app whose session
  // never got cleared) still gets a fresh OTP sent — this is the actual
  // uninstall/reinstall fix. Blocking here would permanently lock a real
  // account owner out with no self-service way back in; the single-active-
  // session guarantee is enforced later, in verify-otp's atomic claim
  // (auth.verifyOtp.test.js's TC-AUTH-11), the one point it's actually
  // safe to enforce it — after a real OTP has proven who's asking.
  test('a number already logged in elsewhere still gets a fresh OTP sent', async () => {
    const futureExpiry = new Date(Date.now() + 24 * 60 * 60 * 1000);
    db.query
      .mockResolvedValueOnce([[{
        user_id: 42, client_id: 10, user_microlab_type: 'patient_user',
        user_auth_token: 'some-active-token', user_token_expiry: futureExpiry,
        deleted_at: null,
      }]])
      .mockResolvedValueOnce([{}]); // UPDATE ip_users SET user_otp=...

    const res = await request(app)
      .post('/api/auth/send-otp')
      .send({ mobile: '9876543210', role: 'customer' });

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    expect(sms.sendLoginOtp).toHaveBeenCalledWith('9876543210', expect.any(String));
  });

  // Negative case: a technician's mobile number cannot log in on the
  // customer role.
  test('rejects a known technician number trying to log in as customer', async () => {
    db.query.mockResolvedValueOnce([[{
      user_id: 17, client_id: null, user_microlab_type: 'technician',
      user_auth_token: null, user_token_expiry: null, deleted_at: null,
    }]]);

    const res = await request(app)
      .post('/api/auth/send-otp')
      .send({ mobile: '9000000001', role: 'customer' });

    expect(res.status).toBe(403);
    expect(res.body.message).toMatch(/technician account/i);
  });
});
