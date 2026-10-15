// Tests POST /api/auth/verify-otp — server/controllers/authController.js: verifyOtp
//
// Covers: TC-AUTH-06 (correct OTP, customer), TC-AUTH-07 (wrong OTP),
// TC-AUTH-08 (expired/already-used OTP), TC-AUTH-09 (concurrent-verify race
// — the second request's own OTP-consume UPDATE sees 0 rows because the
// first already claimed it), TC-AUTH-10 (soft-deleted account,
// defense-in-depth), TC-AUTH-11 (a successful verify always claims the
// session, even over an existing active one on another device — the actual
// uninstall/reinstall fix: see authController.js's own comment on the
// claim UPDATE for why this is safe).
//
// The real flow, as of the atomic-claim rewrite: ONE UPDATE both validates
// AND consumes the OTP (WHERE mobile=? AND otp=? AND expiry>NOW() AND
// active=1 AND deleted_at IS NULL) — affectedRows 0 means "not currently a
// valid, unused OTP for this number", for any reason (wrong code, expired,
// already consumed by a concurrent request, or a soft-deleted account).
// Only on affectedRows>0 does a follow-up SELECT (by mobile alone — safe,
// since the UPDATE just proved exclusive ownership) fetch the row's other
// fields. The session claim later is unconditional — no separate guard, no
// 409 for "already logged in elsewhere" anymore.
//
// verifyOtp's customer path always calls the Jayamala patient registry
// (fetchFromRegistry, via global fetch()) regardless of whether the patient
// is new — so every test here mocks fetch, even the "existing patient"
// cases, or it would attempt a real network call.
jest.mock('../../config/db');
const db      = require('../../config/db');
const request = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { mockFetchOnce } = require('../helpers/mockNetwork');

const authRoutes = require('../../routes/auth');
const app = buildTestApp('/api/auth', authRoutes);

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  mockFetchOnce({ status: 'failure', msg: 'not found' }); // Jayamala registry — irrelevant to these assertions
});

describe('POST /api/auth/verify-otp', () => {
  // TC-AUTH-07 — negative case: the OTP-consume UPDATE matches no row
  // (wrong code, or none sent).
  test('rejects an incorrect OTP', async () => {
    db.query.mockResolvedValueOnce([{ affectedRows: 0 }]); // consume UPDATE — no match

    const res = await request(app)
      .post('/api/auth/verify-otp')
      .send({ mobile: '9876543210', otp: '0000', role: 'customer' });

    expect(res.status).toBe(401);
    expect(res.body.message).toMatch(/invalid or expired/i);
  });

  // TC-AUTH-08 — an expired OTP fails the same WHERE clause (user_otp_expiry
  // > NOW() no longer holds) — indistinguishable from "wrong OTP" at the
  // database level, same as before this rewrite.
  test('an expired OTP is rejected the same way as a wrong one', async () => {
    db.query.mockResolvedValueOnce([{ affectedRows: 0 }]);

    const res = await request(app)
      .post('/api/auth/verify-otp')
      .send({ mobile: '9876543210', otp: '1234', role: 'customer' });

    expect(res.status).toBe(401);
  });

  // TC-AUTH-06 — the full success path for an existing customer/patient.
  test('correct OTP logs an existing customer in and issues a token', async () => {
    db.query
      .mockResolvedValueOnce([{ affectedRows: 1 }])       // 1. atomic consume — matched
      .mockResolvedValueOnce([[{                          // 2. fetch user by mobile
        user_id: 42, client_id: 10, user_name: 'user_9876543210',
        user_microlab_type: 'patient_user', user_mobile_no: '9876543210',
      }]])
      .mockResolvedValueOnce([[{                          // 3. existing ip_patients row
        patient_id: 501, patient_id_ref: null, patient_mobile: '9876543210',
        patient_relation: 'Self',
      }]])
      .mockResolvedValueOnce([{}]);                        // 4. unconditional session claim

    const res = await request(app)
      .post('/api/auth/verify-otp')
      .send({ mobile: '9876543210', otp: '1234', role: 'customer' });

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.data.token).toEqual(expect.any(String));
    expect(res.body.data.user.patient_id).toBe(501);

    // The 4th call is the claim — confirms it's unconditional (no leftover
    // single-active-session WHERE clause).
    const claimCall = db.query.mock.calls[3];
    expect(claimCall[0]).not.toMatch(/user_auth_token IS NULL/);
    expect(claimCall[0]).toMatch(/WHERE user_id = \?\s*$/);
  });

  // TC-AUTH-11 — the actual uninstall/reinstall fix: a correct, unexpired
  // OTP always claims the session, even though another device's token is
  // still on file and unexpired. No flag, no special request shape — this
  // is simply what a successful verify now does, every time.
  test('a successful verify claims the session even with another device already logged in', async () => {
    db.query
      .mockResolvedValueOnce([{ affectedRows: 1 }])
      .mockResolvedValueOnce([[{
        user_id: 42, client_id: 10, user_name: 'user_9876543210',
        user_microlab_type: 'patient_user', user_mobile_no: '9876543210',
      }]])
      .mockResolvedValueOnce([[{ patient_id: 501, patient_id_ref: null, patient_mobile: '9876543210' }]])
      .mockResolvedValueOnce([{}]); // claim always succeeds — no guard to fail

    const res = await request(app)
      .post('/api/auth/verify-otp')
      .send({ mobile: '9876543210', otp: '1234', role: 'customer' });

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
  });

  // TC-AUTH-09 — the race two concurrent verify-otp requests for the same
  // number now resolve at: whichever request's UPDATE actually clears the
  // OTP row wins (MySQL serializes the two UPDATEs); the loser's own
  // UPDATE affects 0 rows — because by the time it runs, user_otp is
  // already NULL — and it gets the same honest "Invalid or expired OTP" a
  // wrong code would, which is accurate: from the loser's perspective,
  // there is no longer a currently-valid OTP to consume.
  test('the losing side of a concurrent verify race gets a clean rejection, not a false success', async () => {
    db.query.mockResolvedValueOnce([{ affectedRows: 0 }]); // this request's UPDATE found user_otp already NULL

    const res = await request(app)
      .post('/api/auth/verify-otp')
      .send({ mobile: '9876543210', otp: '1234', role: 'customer' });

    expect(res.status).toBe(401);
    expect(res.body.message).toMatch(/invalid or expired/i);
  });

  // TC-AUTH-10 — defense-in-depth: deleted_at IS NULL is part of the same
  // atomic consume UPDATE's WHERE clause now, not a separate check — a
  // soft-deleted account's OTP (even if technically still unexpired) can
  // never be consumed, so this still fails at the very first query, same
  // outward result as before this rewrite.
  test('a soft-deleted account cannot complete verification even with a valid OTP on file', async () => {
    db.query.mockResolvedValueOnce([{ affectedRows: 0 }]); // deleted_at IS NULL excludes the row from the UPDATE's match

    const res = await request(app)
      .post('/api/auth/verify-otp')
      .send({ mobile: '9876543210', otp: '1234', role: 'customer' });

    expect(res.status).toBe(401);
  });

  // Negative case: missing fields never reach the database.
  test('rejects a request missing mobile or otp', async () => {
    const res = await request(app).post('/api/auth/verify-otp').send({ mobile: '9876543210' });
    expect(res.status).toBe(422);
    expect(db.query).not.toHaveBeenCalled();
  });
});
