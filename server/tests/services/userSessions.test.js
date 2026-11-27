// services/userSessions.js — one login session per user per role, so one
// mobile number can be logged in to the customer and technician apps at once.
jest.mock('../../config/db');
const db       = require('../../config/db');
const request  = require('supertest');
const sessions = require('../../services/userSessions');
const { buildTestApp } = require('../helpers/testApp');
const { customerToken, technicianToken } = require('../helpers/jwt');

const missingTable = () =>
  Object.assign(new Error("Table 'ip_user_sessions' doesn't exist"), { code: 'ER_NO_SUCH_TABLE' });

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  sessions._resetForTests();
});

describe('roles', () => {
  test('technician stays technician; anything else is the customer app', () => {
    expect(sessions.roleOf('technician')).toBe('technician');
    expect(sessions.roleOf('customer')).toBe('customer');
    expect(sessions.roleOf('patient')).toBe('customer');
    expect(sessions.roleOf(undefined)).toBe('customer');
  });

  test('role of a token', () => {
    expect(sessions.roleOfToken({ role: 'technician', userId: 1 })).toBe('technician');
    expect(sessions.roleOfToken({ role: 'customer', user_id: 1 })).toBe('customer');
    expect(sessions.roleOfToken({ userId: 1 })).toBe('technician'); // no role: technician tokens carry userId
    expect(sessions.roleOfToken({ user_id: 1 })).toBe('customer');
  });
});

describe('isCurrentToken', () => {
  test("a technician token is checked against the technician session, not the customer one", async () => {
    db.execute.mockResolvedValueOnce([[{ user_auth_token: 'tech-token' }]]);
    const ok = await sessions.isCurrentToken({ role: 'technician', userId: 42 }, 'tech-token');
    expect(ok).toBe(true);
    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toMatch(/FROM ip_user_sessions WHERE user_id = \? AND role = \?/);
    expect(params).toEqual([42, 'technician']);
  });

  test('a token replaced by a newer login of the same app is rejected', async () => {
    db.execute.mockResolvedValueOnce([[{ user_auth_token: 'newer-token' }]]);
    expect(await sessions.isCurrentToken({ role: 'customer', user_id: 42 }, 'old-token')).toBe(false);
  });

  test('a logged-out session (row with no token) is rejected without looking at ip_users', async () => {
    db.execute.mockResolvedValueOnce([[{ user_auth_token: null }]]);
    expect(await sessions.isCurrentToken({ role: 'customer', user_id: 42 }, 'tok')).toBe(false);
    expect(db.execute).toHaveBeenCalledTimes(1);
  });

  test('no session row yet: falls back to the ip_users column', async () => {
    db.execute
      .mockResolvedValueOnce([[]])                              // no ip_user_sessions row
      .mockResolvedValueOnce([[{ user_auth_token: 'tok' }]]);   // ip_users
    expect(await sessions.isCurrentToken({ role: 'customer', user_id: 42 }, 'tok')).toBe(true);
    expect(db.execute.mock.calls[1][0]).toMatch(/FROM ip_users/);
  });

  test('without the table, uses the old single-session column on ip_users', async () => {
    db.execute
      .mockRejectedValueOnce(missingTable())
      .mockResolvedValueOnce([[{ user_auth_token: 'tok' }]]);
    expect(await sessions.isCurrentToken({ role: 'technician', userId: 42 }, 'tok')).toBe(true);
    expect(db.execute.mock.calls[1][0]).toMatch(/SELECT user_auth_token FROM ip_users WHERE user_id = \?/);
    expect(sessions.dualRoleEnabled()).toBe(false);

    // Stays in legacy mode (no retry of the missing table on every request).
    db.execute.mockResolvedValueOnce([[{ user_auth_token: 'tok' }]]);
    await sessions.isCurrentToken({ role: 'technician', userId: 42 }, 'tok');
    expect(db.execute.mock.calls[2][0]).toMatch(/FROM ip_users/);
  });

  test('other database errors are not hidden', async () => {
    db.execute.mockRejectedValueOnce(new Error('connection lost'));
    await expect(sessions.isCurrentToken({ role: 'customer', user_id: 1 }, 't')).rejects.toThrow('connection lost');
  });
});

describe('writes', () => {
  test('saveLogin stores the login under its own role', async () => {
    const expiry = new Date();
    await sessions.saveLogin(42, 'technician', 'tok', expiry);
    const [sql, params] = db.query.mock.calls[0];
    expect(sql).toMatch(/INSERT INTO ip_user_sessions/);
    expect(sql).toMatch(/ON DUPLICATE KEY UPDATE/);
    expect(params).toEqual([42, 'technician', 'tok', expiry]);
  });

  test('clearLogin ends only that role', async () => {
    await sessions.clearLogin(42, 'customer');
    const [sql, params] = db.query.mock.calls[0];
    expect(sql).toMatch(/UPDATE ip_user_sessions[\s\S]*WHERE user_id = \? AND role = \?/);
    expect(params).toEqual([42, 'customer']);
  });

  test('writes are skipped quietly without the table', async () => {
    db.query.mockRejectedValueOnce(missingTable());
    await expect(sessions.saveFcmToken(42, 'customer', 'fcm')).resolves.toBeUndefined();
  });

  test('closeCustomerSide reports false without the table, so the caller deletes as before', async () => {
    db.query.mockRejectedValueOnce(missingTable());
    expect(await sessions.closeCustomerSide(42)).toBe(false);
  });
});

describe('middleware/auth.js uses the token\'s own role', () => {
  const authRoutes = require('../../routes/auth');
  const app = buildTestApp('/api/auth', authRoutes);

  test('a customer request is checked against the customer session', async () => {
    const token = customerToken({ userId: 42 });
    db.execute.mockResolvedValueOnce([[{ user_auth_token: token }]]);
    db.query.mockResolvedValue([{ affectedRows: 1 }]);

    const res = await request(app).post('/api/auth/fcm-token')
      .set('Authorization', `Bearer ${token}`).send({ token: 'fcm-1' });

    expect(res.status).toBe(200);
    expect(db.execute.mock.calls[0][1]).toEqual([42, 'customer']);
    // The push token is stored for the customer app.
    const save = db.query.mock.calls.find(c => /INSERT INTO ip_user_sessions \(user_id, role, fcm_token\)/.test(c[0]));
    expect(save[1]).toEqual([42, 'customer', 'fcm-1']);
  });

  test('a technician request is checked against the technician session', async () => {
    const token = technicianToken({ userId: 501 });
    db.execute.mockResolvedValueOnce([[{ user_auth_token: token }]]);

    const res = await request(app).post('/api/auth/fcm-token')
      .set('Authorization', `Bearer ${token}`).send({ token: 'fcm-2' });

    expect(res.status).toBe(200);
    expect(db.execute.mock.calls[0][1]).toEqual([501, 'technician']);
  });
});

describe('deleteAccount on a number that is also a technician', () => {
  const authRoutes = require('../../routes/auth');
  const app = buildTestApp('/api/auth', authRoutes);

  test('closes the customer side only; the account is not deleted', async () => {
    const token = customerToken({ userId: 42 });
    db.execute.mockResolvedValueOnce([[{ user_auth_token: token }]]);
    db.query
      .mockResolvedValueOnce([[{ technician_id: 7 }]])  // is a technician
      .mockResolvedValueOnce([{ affectedRows: 1 }]);   // close customer side

    const res = await request(app).delete('/api/auth/account')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(db.query.mock.calls[1][0]).toMatch(/closed_at = NOW\(\)/);
    expect(db.query.mock.calls.some(c => /deleted_at = NOW\(\)/.test(c[0]))).toBe(false);
  });

  test('a customer-only number is soft-deleted as before', async () => {
    const token = customerToken({ userId: 43 });
    db.execute.mockResolvedValueOnce([[{ user_auth_token: token }]]);
    db.query.mockResolvedValueOnce([[]]); // not a technician

    const res = await request(app).delete('/api/auth/account')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(db.query.mock.calls.some(c => /deleted_at = NOW\(\)/.test(c[0]))).toBe(true);
  });
});
