// IT-T001 — Technician Login, IT-T002 — Technician Online/Offline.
// Real HTTP wire + a real Socket.IO client connected to the real server
// (see realServer.js) — the technician's online/offline state lives in
// module-private Maps inside socket/bookingSocket.js with no export, so a
// real socket connection is the only faithful way to prove this works.
jest.mock('../../config/db');
jest.mock('../../config/firebase', () => ({ messaging: null }));
jest.mock('../../utils/sms');
const db  = require('../../config/db');
const sms = require('../../utils/sms');
const jwt = require('jsonwebtoken');
const { startRealServer } = require('../helpers/realServer');
const { connectClient, waitForEvent } = require('../helpers/socketServer');

let server;
beforeAll(async () => { server = await startRealServer(); });
afterAll(async () => { await server.close(); });

// Unlike the customer path (customer.auth.e2e.test.js), the TECHNICIAN
// verifyOtp branch does NOT swallow a Jayamala-lookup failure — an
// unmocked fetch(undefined, ...) throws, and that throw is caught by a
// try/catch that returns 502 immediately. So a technician login test needs
// fetch to actually resolve (as a "not found in Jayamala" response, which
// the real code then falls back to a local ip_users lookup for) — mocked
// with a URL-aware passthrough so this file's OWN fetch() calls to the real
// server keep working (see mockNetwork.js's warning about global.fetch
// leaking across every call in the file, not just the one you intended).
const realFetch = global.fetch;
afterEach(() => { global.fetch = realFetch; });
function mockJayamalaRegistryOnce(jsonBody, status = 200) {
  global.fetch = jest.fn((url, opts) => {
    if (String(url).startsWith(server.url)) return realFetch(url, opts);
    return Promise.resolve({ status, json: async () => jsonBody });
  });
}

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

describe('IT-T001 — Technician Login (real server)', () => {
  // Precondition: this technician is already known locally (a real ip_users
  // + ip_technicians row) but Jayamala's registry doesn't have them —
  // exercises the local-fallback branch, not the Jayamala-confirmed branch.
  test('an existing (locally-known) technician logs in over the real wire and receives a token', async () => {
    mockJayamalaRegistryOnce({ status: 'failure', msg: 'not found' });
    db.query
      .mockResolvedValueOnce([{ affectedRows: 1 }])                    // atomic OTP consume — matched
      .mockResolvedValueOnce([[{ user_id: 17, client_id: null, user_name: 'Suresh', user_mobile_no: '9000000001' }]]) // fetch user by mobile
      .mockResolvedValueOnce([[{ user_id: 17, user_branch_id: 3, user_city: 'Chennai' }]]) // _findLocalTechnicianUser
      .mockResolvedValueOnce([[{ user_id: 17, technician_id: 501, branch_id: 3 }]]) // existingRows (ip_technicians already exists)
      .mockResolvedValueOnce([{ affectedRows: 1 }])                   // refresh UPDATE ip_technicians
      .mockResolvedValueOnce([[{ branch_id: 3, technician_code: 'T-001', specialization: null,
        tech_photo: null, tech_city: 'Chennai', user_name: 'Suresh', user_email: null }]]) // re-read branch/profile
      .mockResolvedValueOnce([{ affectedRows: 1 }])                   // atomic session claim
      .mockResolvedValueOnce([{ insertId: 88 }])                      // INSERT ip_technician_sessions
      .mockResolvedValueOnce([{}]);                                   // INSERT/UPDATE ip_technician_live_location

    const res = await post('/api/auth/verify-otp', { mobile: '9000000001', otp: '1234', role: 'technician' });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.success).toBe(true);
    expect(body.data.token).toEqual(expect.any(String));
    expect(body.data.user.technician_id).toBe(501);
  });

  test('a wrong OTP is rejected over the real wire, before the registry is ever consulted', async () => {
    db.query.mockResolvedValueOnce([{ affectedRows: 0 }]); // atomic consume — no match
    const res = await post('/api/auth/verify-otp', { mobile: '9000000001', otp: '0000', role: 'technician' });
    expect(res.status).toBe(401);
  });

  // Negative: a mobile that's neither in Jayamala nor known locally.
  test('a technician number unknown to both Jayamala and the local DB is rejected', async () => {
    mockJayamalaRegistryOnce({ status: 'failure', msg: 'not found' });
    db.query
      .mockResolvedValueOnce([{ affectedRows: 1 }])
      .mockResolvedValueOnce([[{ user_id: 99, client_id: null, user_name: 'Ghost', user_mobile_no: '9999999999' }]])
      .mockResolvedValueOnce([[]]); // _findLocalTechnicianUser — nothing found either

    const res = await post('/api/auth/verify-otp', { mobile: '9999999999', otp: '1234', role: 'technician' });
    expect(res.status).toBe(404);
  });

  test('technician logout (no auth middleware — identified by URL param) clears session over the real wire', async () => {
    const { createMockConnection } = require('../helpers/mockConnection');
    const connMockDb = require('../../config/db');
    const conn = createMockConnection();
    connMockDb.getConnection.mockResolvedValue(conn);

    const res = await fetch(`${server.url}/api/technicians/501/logout`, { method: 'POST' });
    expect(res.status).toBe(200);
    expect(conn.commit).toHaveBeenCalled();
  });
});

describe('IT-T002 — Technician Online/Offline (real server + real Socket.IO)', () => {
  test('going online is reflected in the live-location DB write; going offline clears socket/status', async () => {
    const tech = await connectClient(server.url);
    try {
      tech.emit('technician_online', { technicianId: 501, technicianName: 'Suresh', lat: 13.05, lng: 80.25 });
      await waitForEvent(tech, 'session_started');

      // Verify DB result: the live-location upsert marks the technician online.
      const onlineWrite = db.execute.mock.calls.find(c => c[0].includes('ip_technician_live_location') && c[0].includes("'online'"));
      expect(onlineWrite).toBeDefined();

      db.execute.mockClear();
      tech.emit('technician_offline', { technicianId: 501 });
      await new Promise(r => setTimeout(r, 50)); // technician_offline is fire-and-forget

      const offlineWrite = db.execute.mock.calls.find(c => c[0].includes('ip_technician_live_location') && c[0].includes("'offline'"));
      expect(offlineWrite).toBeDefined();
      expect(offlineWrite[1]).toContain(501);
    } finally {
      tech.disconnect();
    }
  });
});
