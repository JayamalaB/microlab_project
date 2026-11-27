// One number on two phones, per app (services/userSessions.js).
//
// Same app on another phone → "Already logged in on another device" and
// "Log out & continue" (forceLogout) still works: the new phone gets the
// session and only the old phone of THAT app is logged out.
// The other app (customer vs technician) on the same number never blocks.
jest.mock('../../config/db');
jest.mock('../../socket/bookingSocket', () => ({
  forceTechnicianOffline: jest.fn(),
  emitForceLogout: jest.fn(),
}));
const db      = require('../../config/db');
const request = require('supertest');
const { emitForceLogout } = require('../../socket/bookingSocket');
const { buildTestApp } = require('../helpers/testApp');
const { mockFetchOnce } = require('../helpers/mockNetwork');

const app = buildTestApp('/api/auth', require('../../routes/auth'));

const MOBILE = '9876543210';
const user = {
  user_id: 42, client_id: 10, user_name: 'Test', user_microlab_type: 'technician', user_mobile_no: MOBILE,
};

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  emitForceLogout.mockClear();
  mockFetchOnce({ status: 'failure', msg: 'not found' }); // Jayamala registry
});

const verify = (body) => request(app).post('/api/auth/verify-otp')
  .send({ mobile: MOBILE, otp: '1234', role: 'customer', ...body });

describe('same number, same app, another phone', () => {
  test('send-otp shows "Already logged in on another device"', async () => {
    db.query.mockResolvedValueOnce([[{ ...user, deleted_at: null, is_logged_in: 1, user_auth_token: 'phone-1' }]]);

    const res = await request(app).post('/api/auth/send-otp').send({ mobile: MOBILE, role: 'customer' });

    expect(res.status).toBe(409);
    expect(res.body.message).toMatch(/Already logged in on another device/);
    expect(res.body.message).toMatch(/Log out & continue/);
  });

  test('verify-otp is refused the same way without "Log out & continue"', async () => {
    db.query
      .mockResolvedValueOnce([{ affectedRows: 1 }])                              // OTP claimed
      .mockResolvedValueOnce([[user]])                                            // the account
      .mockResolvedValueOnce([[{ is_logged_in: 1, user_auth_token: 'phone-1' }]]); // customer session

    const res = await verify();

    expect(res.status).toBe(409);
    expect(res.body.message).toBe('Already logged in on another device. Tap "Log out & continue" to sign in here instead.');
    expect(db.query.mock.calls[2][0]).toMatch(/LEFT JOIN ip_user_sessions s ON s.user_id = u.user_id AND s.role = \?/);
    expect(db.query.mock.calls[2][1]).toEqual(['customer', 'technician', 42]);
    expect(emitForceLogout).not.toHaveBeenCalled();
  });

  test('"Log out & continue" logs this phone in and logs the old phone of the same app out', async () => {
    db.query
      .mockResolvedValueOnce([{ affectedRows: 1 }])
      .mockResolvedValueOnce([[user]])
      .mockResolvedValueOnce([[{ is_logged_in: 1, user_auth_token: 'phone-1' }]]); // closed_at check only

    const res = await verify({ forceLogout: true });

    expect(res.status).toBe(200);
    const token = res.body.data.token;
    // The new token replaces the customer session (the old phone's token stops working).
    const save = db.query.mock.calls.find(c => /INSERT INTO ip_user_sessions \(user_id, role, auth_token/.test(c[0]));
    expect(save[1].slice(0, 3)).toEqual([42, 'customer', token]);
    // Only the customer app is told to log out — not the technician app.
    expect(emitForceLogout).toHaveBeenCalledWith(42, 'customer');
  });
});

describe('same number, the other app on another phone', () => {
  // Technician app logged in on phone 1, customer login tried on phone 2.
  const technicianElsewhere = { is_logged_in: null, user_auth_token: null, other_is_logged_in: 1, other_auth_token: 'tech-phone-1' };

  test('send-otp says it is logged in as a technician and offers "Log out & continue"', async () => {
    db.query.mockResolvedValueOnce([[{ ...user, deleted_at: null, ...technicianElsewhere }]]);

    const res = await request(app).post('/api/auth/send-otp').send({ mobile: MOBILE, role: 'customer' });

    expect(res.status).toBe(409);
    // Starts with the text the app looks for to show the button.
    expect(res.body.message).toMatch(/^Already logged in on another device as a technician\./);
    expect(res.body.message).toMatch(/Log out & continue/);
  });

  test('the technician login says "as a customer" the other way round', () => {
    const sessions = require('../../services/userSessions');
    expect(sessions.otherRoleOf('technician')).toBe('customer');
    expect(sessions.alreadyLoggedInMessage('customer'))
      .toBe('Already logged in on another device as a customer. Tap "Log out & continue" to sign in here instead.');
  });

  test('verify-otp is refused too without "Log out & continue"', async () => {
    db.query
      .mockResolvedValueOnce([{ affectedRows: 1 }])
      .mockResolvedValueOnce([[user]])
      .mockResolvedValueOnce([[technicianElsewhere]]);

    const res = await verify();

    expect(res.status).toBe(409);
    expect(res.body.message).toMatch(/as a technician/);
  });

  test('"Log out & continue" logs the customer in and logs the technician phone out', async () => {
    db.query
      .mockResolvedValueOnce([{ affectedRows: 1 }])
      .mockResolvedValueOnce([[user]])
      .mockResolvedValueOnce([[technicianElsewhere]]);
    db.query.mockImplementation(async (sql) =>
      /SELECT technician_id FROM ip_technicians/.test(sql) ? [[{ technician_id: 7 }]] : [[], {}]);

    const res = await verify({ forceLogout: true });

    expect(res.status).toBe(200);
    const sqls = db.query.mock.calls.map(c => c[0]);
    // The technician login is ended and the technician taken offline.
    const clear = db.query.mock.calls.find(c => /UPDATE ip_user_sessions[\s\S]*SET auth_token = NULL/.test(c[0]));
    expect(clear[1]).toEqual([42, 'technician']);
    expect(sqls.some(s => /UPDATE ip_technician_sessions SET ended_at = NOW\(\)/.test(s))).toBe(true);
    expect(sqls.some(s => /UPDATE ip_technician_live_location SET online_status = 'offline'/.test(s))).toBe(true);
    expect(emitForceLogout).toHaveBeenCalledWith(42, 'customer');
    expect(emitForceLogout).toHaveBeenCalledWith(42, 'technician');
  });

  test('no other login anywhere: the customer logs in and nothing else is touched', async () => {
    db.query
      .mockResolvedValueOnce([{ affectedRows: 1 }])
      .mockResolvedValueOnce([[user]])
      .mockResolvedValueOnce([[{}]]);

    const res = await verify();

    expect(res.status).toBe(200);
    expect(emitForceLogout).toHaveBeenCalledWith(42, 'customer');
    expect(emitForceLogout).not.toHaveBeenCalledWith(42, 'technician');
  });
});
