// Tests the branch a technician gets at login — controllers/authController.js
// verifyOtp, technician path. A branch_id that doesn't exist in ip_branches
// (e.g. a stale ip_users.user_branch_id) must never become the technician's
// branch: it was stored on ip_technicians, sent to the app at login and used
// for dispatch and slots ("app=24" in the dispatch log).
//
// DB answers are keyed on the SQL text (not call order).
jest.mock('../../config/db');
jest.mock('../../config/firebase', () => ({ messaging: null }));
jest.mock('../../utils/sms');
const db      = require('../../config/db');
const request = require('supertest');
const { buildTestApp } = require('../helpers/testApp');

const authRoutes = require('../../routes/auth');
const app = buildTestApp('/api/auth', authRoutes);

const BRANCHES = [
  { branch_id: 1, branch_code: '01' },
  { branch_id: 2, branch_code: '42' },
];

// registry: the ASMX technician login reply, or null for "not found".
function wire({ registry, userBranchId, existing }) {
  const realFetch = global.fetch;
  global.fetch = jest.fn(async () => ({
    status: 200,
    text: async () => `<string xmlns="http://tempuri.org/">${JSON.stringify(
      registry ? { status: 'success', technician: registry } : { status: 'failure', msg: 'not found' })}</string>`,
  }));
  afterEachRestore.push(() => { global.fetch = realFetch; });

  db.query.mockReset().mockImplementation(async (sql, params = []) => {
    if (/^\s*UPDATE ip_users\s+SET user_otp = NULL/.test(sql)) return [{ affectedRows: 1 }];
    if (/SELECT user_id, client_id, user_name, user_microlab_type/.test(sql)) {
      return [[{ user_id: 17, client_id: null, user_name: 'Nirosh', user_microlab_type: 'technician', user_mobile_no: '9000000001' }]];
    }
    if (/SELECT is_logged_in, user_auth_token/.test(sql)) return [[{ is_logged_in: 0, user_auth_token: null }]];
    if (/SELECT user_id, user_branch_id, user_city/.test(sql)) return [[{ user_id: 17, user_branch_id: userBranchId, user_city: 'Coimbatore' }]];
    if (/FROM ip_technicians tech/.test(sql) || /JOIN ip_technicians tech/.test(sql)) return [existing ? [existing] : []];
    if (/SELECT branch_id, branch_code FROM ip_branches/.test(sql)) return [BRANCHES];
    if (/SELECT branch_id FROM ip_branches WHERE branch_id = \?/.test(sql)) {
      return [BRANCHES.filter(b => b.branch_id === Number(params[0]))];
    }
    if (/^\s*INSERT INTO ip_technicians\s/.test(sql)) return [{ insertId: 601 }];
    if (/SELECT t.branch_id, t.technician_code/.test(sql)) return [[]]; // re-read: fall back to what login set
    if (/^\s*SELECT/.test(sql)) return [[]];
    return [{ affectedRows: 1, insertId: 1 }];
  });
}
const afterEachRestore = [];
afterEach(() => { while (afterEachRestore.length) afterEachRestore.pop()(); });

const login = () => request(app).post('/api/auth/verify-otp').send({ mobile: '9000000001', otp: '1234', role: 'technician' });
const refreshParams = () => db.query.mock.calls.find(c => /^\s*UPDATE ip_technicians/.test(c[0]))?.[1];

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
});

describe('technician login — local fallback (registry does not return the technician)', () => {
  test('uses the default branch code saved at an earlier registry login', async () => {
    wire({ registry: null, userBranchId: 24, existing: { user_id: 17, technician_id: 6, branch_id: 24, default_branch_id: '01' } });
    const res = await login();
    expect(res.status).toBe(200);
    expect(refreshParams()[1]).toBe(1);          // branch_id = COALESCE(1, branch_id)
    expect(res.body.data.user.branch_id).toBe(1);
  });

  test('a user_branch_id that is not a branch is never written', async () => {
    wire({ registry: null, userBranchId: 24, existing: { user_id: 17, technician_id: 6, branch_id: 1, default_branch_id: null } });
    const res = await login();
    expect(res.status).toBe(200);
    expect(refreshParams()[1]).toBeNull();       // COALESCE(NULL, branch_id) keeps branch 1
    expect(res.body.data.user.branch_id).toBe(1);
  });

  test('a valid user_branch_id is still used when there is no saved code', async () => {
    wire({ registry: null, userBranchId: 2, existing: { user_id: 17, technician_id: 6, branch_id: 1, default_branch_id: null } });
    await login();
    expect(refreshParams()[1]).toBe(2);
  });

  test('a first login with a branch that does not exist is refused instead of inserted', async () => {
    wire({ registry: null, userBranchId: 24, existing: null });
    const res = await login();
    expect(res.status).toBe(422);
    expect(db.query.mock.calls.some(c => /INSERT INTO ip_technicians\s/.test(c[0]))).toBe(false);
  });
});

describe('technician login — registry', () => {
  test('the registry default branch code decides the branch', async () => {
    wire({
      registry: { technician_id: 'X9', name: 'Nirosh', branch_id: ['01'], default_branch_id: '01' },
      userBranchId: 24,
      existing: { user_id: 17, technician_id: 6, branch_id: 24, default_branch_id: '01' },
    });
    const res = await login();
    expect(res.status).toBe(200);
    expect(refreshParams()[1]).toBe(1);
  });
});
