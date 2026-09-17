// Tests POST /api/auth/logout (protected route — needs the `auth`
// middleware helper) and POST /api/technicians/:id/logout.
//
// Covers: TC-AUTH-12 (logout clears the session so the number can log in
// elsewhere), TC-AUTH-13 (unauthorized — no/invalid token).
jest.mock('../../config/db');
const db      = require('../../config/db');
const request = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { customerToken, primeAuthCheck } = require('../helpers/jwt');
const { createMockConnection } = require('../helpers/mockConnection');

const authRoutes = require('../../routes/auth');
const app = buildTestApp('/api/auth', authRoutes);

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  db.getConnection.mockReset();
});

describe('POST /api/auth/logout', () => {
  // TC-AUTH-13 — the middleware itself, not the controller: no Authorization
  // header at all must never reach logout()'s own code.
  test('rejects a request with no auth token', async () => {
    const res = await request(app).post('/api/auth/logout');
    expect(res.status).toBe(401);
    expect(db.execute).not.toHaveBeenCalled();
  });

  // TC-AUTH-12 — a customer logout clears user_auth_token, which is exactly
  // what releases the single-active-session lock for another device.
  test('a valid customer session logs out and clears the auth token', async () => {
    const token = customerToken({ id: 501, userId: 42, clientId: 10 });
    primeAuthCheck(db, token); // middleware's own session check
    db.query.mockResolvedValueOnce([{ affectedRows: 1 }]); // logout()'s own UPDATE ip_users

    const res = await request(app)
      .post('/api/auth/logout')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    // Confirms the actual clearing statement ran with the right shape —
    // this is the exact fix from the "customer logout never told the
    // server" bug found earlier this session.
    expect(db.query.mock.calls[0][0]).toMatch(/user_auth_token = NULL/);
  });

  // A logged-out token must not work on the next request — proves
  // middleware/auth.js's session check, not just the logout endpoint itself.
  test('a token whose session was already cleared is rejected on the next request', async () => {
    const token = customerToken({ id: 501, userId: 42, clientId: 10 });
    // Middleware asks ip_users for the CURRENT token; simulate that it's
    // now NULL (already logged out / superseded by a newer login).
    db.execute.mockResolvedValueOnce([[{ user_auth_token: null }]]);

    const res = await request(app)
      .post('/api/auth/fcm-token')
      .set('Authorization', `Bearer ${token}`)
      .send({ token: 'some-fcm-token' });

    expect(res.status).toBe(401);
    expect(res.body.message).toMatch(/session expired|logged in elsewhere/i);
  });
});

describe('POST /api/technicians/:technicianId/logout', () => {
  const technicianRoutes = require('../../routes/technicians');
  const techApp = buildTestApp('/api/technicians', technicianRoutes);

  // TC-AUTH-14 — technician logout closes the session, marks the live
  // location offline, and clears the auth token (this route has no `auth`
  // middleware — it's identified purely by the :technicianId in the URL).
  // logoutTechnician uses a transaction (db.getConnection()), not plain
  // db.query, so it needs the connection mock, not the query mock.
  test('technician logout clears session, live-location status, and auth token', async () => {
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);

    const res = await request(techApp).post('/api/technicians/17/logout');

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    expect(conn.beginTransaction).toHaveBeenCalled();
    expect(conn.commit).toHaveBeenCalled();
    expect(conn.rollback).not.toHaveBeenCalled();
    expect(conn.release).toHaveBeenCalled();
    // The 2nd query inside the transaction is the live-location update.
    expect(conn.query.mock.calls[1][0]).toMatch(/ip_technician_live_location/);
    expect(conn.query.mock.calls[1][0]).toMatch(/online_status = 'offline'/);
  });
});
