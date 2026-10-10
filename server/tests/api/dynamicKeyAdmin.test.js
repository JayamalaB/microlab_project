// Tests the Dynamic Key Admin API (routes/dynamicKeyAdmin.js) end to end
// over the real router, middleware and controller — only the DB is mocked.
// The app is assembled the way server.js does it: the admin router mounted
// BEFORE the global express.json(). Dummy values only.
jest.mock('../../config/db');
jest.mock('../../utils/encryption', () => {
  const actual = jest.requireActual('../../utils/encryption');
  return { ...actual, encrypt: jest.fn(actual.encrypt), decrypt: jest.fn(actual.decrypt) };
});
const crypto  = require('crypto');
const express = require('express');
const request = require('supertest');
const db      = require('../../config/db');
const encryption = require('../../utils/encryption');
const { createMockConnection } = require('../helpers/mockConnection');
const dynamicKeyAdminRouter = require('../../routes/dynamicKeyAdmin');

const SECRET = 'test-only-dynamic-key-admin-secret';
const BASE   = '/api/admin/dynamic-keys';

function buildApp() {
  const app = express();
  app.use(BASE, dynamicKeyAdminRouter);
  app.use(express.json()); // global parser comes after, as in server.js
  return app;
}

function sign({ method, path, timestamp, rawBody = '', secret = SECRET }) {
  const bodyHash = crypto.createHash('sha256').update(rawBody, 'utf8').digest('hex');
  return crypto.createHmac('sha256', secret).update(`${method}|${path}|${timestamp}|${bodyHash}`).digest('hex');
}
const now = () => Math.floor(Date.now() / 1000).toString();

function signedGet(app, path, { secret } = {}) {
  const ts = now();
  return request(app).get(path)
    .set('X-Admin-Timestamp', ts)
    .set('X-Admin-Signature', sign({ method: 'GET', path, timestamp: ts, secret }));
}

function signedPost(app, path, body, { rawBody, signedPath, signedMethod = 'POST', signedBody, secret } = {}) {
  const ts  = now();
  const raw = rawBody ?? JSON.stringify(body);
  return request(app).post(path)
    .set('Content-Type', 'application/json')
    .set('X-Admin-Timestamp', ts)
    .set('X-Admin-Signature', sign({
      method: signedMethod, path: signedPath ?? path, timestamp: ts,
      rawBody: signedBody ?? raw, secret,
    }))
    .send(raw);
}

// FOR UPDATE read → UPDATE deactivate → INSERT
function mockRotation(latestVersion) {
  const conn = createMockConnection();
  conn.execute
    .mockResolvedValueOnce([latestVersion === null ? [] : [{ version: latestVersion }]])
    .mockResolvedValueOnce([{}])
    .mockResolvedValueOnce([{ insertId: 1 }]);
  db.getConnection.mockResolvedValue(conn);
  return conn;
}

const LIST_ROW = {
  key_name: 'EXAMPLE_KEY', latest_version: 3, active_version: 3, expires_at: null,
  updated_at: '2026-10-07 15:00:00', updated_by: 'admin_demo',
};
const VERSION_ROWS = [
  { version: 3, is_active: 1, created_at: '2026-10-07 15:00:00', created_by: 'admin_demo', expires_at: null },
  { version: 2, is_active: 0, created_at: '2026-10-06 14:00:00', created_by: 'admin_demo', expires_at: null },
];

let app;
beforeEach(() => {
  process.env.DYNAMIC_KEY_ADMIN_HMAC_SECRET = SECRET;
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.getConnection.mockReset();
  encryption.encrypt.mockClear();
  encryption.decrypt.mockClear();
  app = buildApp();
});
afterEach(() => {
  delete process.env.DYNAMIC_KEY_ADMIN_HMAC_SECRET;
  delete process.env.ADMIN_PORTAL_SECRET;
});

// ── Authentication ──────────────────────────────────────────────────────
describe('authentication', () => {
  test('1. valid GET signature → accepted', async () => {
    db.execute.mockResolvedValueOnce([[LIST_ROW]]);
    const res = await signedGet(app, BASE);
    expect(res.status).toBe(200);
  });

  test('2. valid POST signature → accepted', async () => {
    mockRotation(null);
    const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, { value: 'DUMMY_VALUE_001', adminUser: 'admin_demo' });
    expect(res.status).toBe(200);
  });

  test('3. missing signature → 403', async () => {
    const res = await request(app).get(BASE).set('X-Admin-Timestamp', now());
    expect(res.status).toBe(403);
    expect(db.execute).not.toHaveBeenCalled();
  });

  test('4. missing timestamp → 403', async () => {
    const res = await request(app).get(BASE).set('X-Admin-Signature', 'a'.repeat(64));
    expect(res.status).toBe(403);
  });

  test('5. invalid timestamp → 403', async () => {
    const res = await request(app).get(BASE)
      .set('X-Admin-Timestamp', '1760000000.5')
      .set('X-Admin-Signature', sign({ method: 'GET', path: BASE, timestamp: '1760000000.5' }));
    expect(res.status).toBe(403);
  });

  test('6. old timestamp → 403', async () => {
    const ts = (Math.floor(Date.now() / 1000) - 600).toString();
    const res = await request(app).get(BASE).set('X-Admin-Timestamp', ts)
      .set('X-Admin-Signature', sign({ method: 'GET', path: BASE, timestamp: ts }));
    expect(res.status).toBe(403);
  });

  test('7. future timestamp → 403', async () => {
    const ts = (Math.floor(Date.now() / 1000) + 600).toString();
    const res = await request(app).get(BASE).set('X-Admin-Timestamp', ts)
      .set('X-Admin-Signature', sign({ method: 'GET', path: BASE, timestamp: ts }));
    expect(res.status).toBe(403);
  });

  test('8. wrong signature → 403', async () => {
    const res = await signedGet(app, BASE, { secret: 'not-the-right-secret' });
    expect(res.status).toBe(403);
  });

  test('9. modified path → 403', async () => {
    const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, { value: 'X', adminUser: 'a' }, { signedPath: `${BASE}/OTHER_KEY` });
    expect(res.status).toBe(403);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('10. modified method → 403', async () => {
    const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, { value: 'X', adminUser: 'a' }, { signedMethod: 'GET' });
    expect(res.status).toBe(403);
  });

  test('11. modified raw body → 403', async () => {
    const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, { value: 'DUMMY_VALUE_999', adminUser: 'a' }, {
      signedBody: JSON.stringify({ value: 'DUMMY_VALUE_001', adminUser: 'a' }),
    });
    expect(res.status).toBe(403);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('12. any query string → 400, before auth and before the DB', async () => {
    const res = await request(app).post(`${BASE}/EXAMPLE_KEY?value=secret`).send('{}');
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ success: false, message: 'Query parameters are not allowed' });
    expect(db.getConnection).not.toHaveBeenCalled();

    const onGet = await request(app).get(`${BASE}?page=1`);
    expect(onGet.status).toBe(400);
  });

  test('13. wrong signature length → 403, no crash', async () => {
    const res = await request(app).get(BASE).set('X-Admin-Timestamp', now()).set('X-Admin-Signature', 'abc');
    expect(res.status).toBe(403);
    expect(res.body.message).toBe('Invalid admin signature');
  });

  test('14. uses DYNAMIC_KEY_ADMIN_HMAC_SECRET, not ADMIN_PORTAL_SECRET', async () => {
    process.env.ADMIN_PORTAL_SECRET = 'booking-admin-secret';
    const signedWithPortalSecret = await signedGet(app, BASE, { secret: 'booking-admin-secret' });
    expect(signedWithPortalSecret.status).toBe(403);

    delete process.env.DYNAMIC_KEY_ADMIN_HMAC_SECRET;
    const noDedicatedSecret = await signedGet(app, BASE, { secret: 'booking-admin-secret' });
    expect(noDedicatedSecret.status).toBe(500);
    expect(noDedicatedSecret.body.message).toBe('Server misconfiguration');
  });
});

// ── Listing / metadata ─────────────────────────────────────────────────
describe('listing and metadata', () => {
  test('15–17. list returns metadata only — no decrypt, no encrypted values', async () => {
    db.execute.mockResolvedValueOnce([[LIST_ROW]]);
    const res = await signedGet(app, BASE);
    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      success: true,
      keys: [{ keyName: 'EXAMPLE_KEY', activeVersion: 3, latestVersion: 3, expiresAt: null, updatedAt: '2026-10-07 15:00:00', updatedBy: 'admin_demo' }],
    });
    expect(encryption.decrypt).not.toHaveBeenCalled();
    expect(db.execute.mock.calls[0][0]).not.toContain('encrypted_value');
  });

  test('18–19. single key returns version history, no decrypt', async () => {
    db.execute.mockResolvedValueOnce([VERSION_ROWS]);
    const res = await signedGet(app, `${BASE}/EXAMPLE_KEY`);
    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      success: true,
      keyName: 'EXAMPLE_KEY',
      versions: [
        { version: 3, isActive: true,  createdAt: '2026-10-07 15:00:00', createdBy: 'admin_demo', expiresAt: null },
        { version: 2, isActive: false, createdAt: '2026-10-06 14:00:00', createdBy: 'admin_demo', expiresAt: null },
      ],
    });
    expect(encryption.decrypt).not.toHaveBeenCalled();
  });

  test('20. unknown key → 404 "Key not found"', async () => {
    db.execute.mockResolvedValueOnce([[]]);
    const res = await signedGet(app, `${BASE}/DOES_NOT_EXIST`);
    expect(res.status).toBe(404);
    expect(res.body).toEqual({ success: false, message: 'Key not found' });
  });
});

// ── Create / rotate ─────────────────────────────────────────────────────
describe('create / rotate', () => {
  const body = (extra = {}) => ({ value: 'DUMMY_VALUE_001', adminUser: 'admin_demo', ...extra });

  test('21. new key → version 1, adminUser recorded as created_by', async () => {
    const conn = mockRotation(null);
    const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, body());
    expect(res.body).toEqual({ success: true, keyName: 'EXAMPLE_KEY', version: 1 });
    const insertParams = conn.execute.mock.calls[2][1];
    expect(insertParams[3]).toBe('admin_demo'); // created_by
  });

  test('22. existing key → next version', async () => {
    mockRotation(4);
    const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, body());
    expect(res.body.version).toBe(5);
  });

  test('23. correct expectedVersion → succeeds', async () => {
    mockRotation(2);
    const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, body({ expectedVersion: 2 }));
    expect(res.status).toBe(200);
    expect(res.body.version).toBe(3);
  });

  test('24. stale expectedVersion → 409 "Version conflict"', async () => {
    const conn = mockRotation(3);
    const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, body({ expectedVersion: 2 }));
    expect(res.status).toBe(409);
    expect(res.body).toEqual({ success: false, message: 'Version conflict' });
    expect(conn.commit).not.toHaveBeenCalled();
  });

  test('25. missing value → 400', async () => {
    const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, { adminUser: 'admin_demo' });
    expect(res.status).toBe(400);
    expect(res.body.message).toBe('value is required');
  });

  test.each(['client-api-key', 'lowercase', 'abc.def', '..%2Fsecret', '1STARTS_WITH_DIGIT', 'A'.repeat(101)])(
    '26. invalid key name %s → 400', async (badName) => {
      const res = await signedPost(app, `${BASE}/${badName}`, body());
      expect(res.status).toBe(400);
      expect(res.body.message).toBe('Invalid key name');
      expect(db.getConnection).not.toHaveBeenCalled();
    });

  test.each(['DYNAMIC_KEY_MASTER_KEY', 'DYNAMIC_KEY_ADMIN_HMAC_SECRET', 'JWT_SECRET', 'CLIENT_SERVER_SECRET',
    'ADMIN_WEBHOOK_SECRET', 'RAZORPAY_WEBHOOK_SECRET', 'RAZORPAY_KEY_SECRET', 'DB_PASS', 'CHATBOT_DB_PASSWORD'])(
    '27. denied key name %s → 400 (write and read)', async (denied) => {
      const write = await signedPost(app, `${BASE}/${denied}`, body());
      expect(write.status).toBe(400);
      const read = await signedGet(app, `${BASE}/${denied}`);
      expect(read.status).toBe(400);
      expect(db.getConnection).not.toHaveBeenCalled();
      expect(db.execute).not.toHaveBeenCalled();
    });

  test('27b. ADMIN_PORTAL_SECRET is a managed Dynamic Key → write and read allowed', async () => {
    mockRotation(null);
    const write = await signedPost(app, `${BASE}/ADMIN_PORTAL_SECRET`, body({ expectedVersion: 0 }));
    expect(write.status).toBe(200);
    expect(write.body).toEqual({ success: true, keyName: 'ADMIN_PORTAL_SECRET', version: 1 });

    db.execute.mockResolvedValueOnce([VERSION_ROWS]);
    const read = await signedGet(app, `${BASE}/ADMIN_PORTAL_SECRET`);
    expect(read.status).toBe(200);
    expect(JSON.stringify(read.body)).not.toContain('DUMMY_VALUE');
  });

  test('28. oversized value (byte length, not character count) → 400; exactly 4096 bytes is allowed', async () => {
    const multiByte = '€'.repeat(1366); // 1366 chars but 4098 UTF-8 bytes
    const tooBig = await signedPost(app, `${BASE}/EXAMPLE_KEY`, body({ value: multiByte }));
    expect(tooBig.status).toBe(400);
    expect(tooBig.body).toEqual({ success: false, message: 'Value exceeds maximum allowed size' });
    expect(db.getConnection).not.toHaveBeenCalled();

    mockRotation(null);
    const atLimit = await signedPost(app, `${BASE}/EXAMPLE_KEY`, body({ value: 'x'.repeat(4096) }));
    expect(atLimit.status).toBe(200);
  });

  // 29. expiresAt (Phase 4.4): ISO-8601 with seconds and an explicit zone.
  describe('29. expiresAt', () => {
    const Y = new Date().getUTCFullYear() + 1; // always in the future, well before the 2038 cap
    const insertedEpoch = (conn) => conn.execute.mock.calls[2][1][4];

    test('+05:30 offset → stored as the correct absolute instant via FROM_UNIXTIME', async () => {
      const conn = mockRotation(null);
      const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, body({ expiresAt: `${Y}-06-15T10:00:00+05:30` }));
      expect(res.status).toBe(200);
      expect(insertedEpoch(conn)).toBe(Date.UTC(Y, 5, 15, 4, 30) / 1000); // 10:00 IST = 04:30 UTC
      expect(conn.execute.mock.calls[2][0]).toContain('FROM_UNIXTIME(?)');
    });

    test('Z (UTC) → same instant rules', async () => {
      const conn = mockRotation(null);
      const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, body({ expiresAt: `${Y}-06-15T10:00:00Z` }));
      expect(res.status).toBe(200);
      expect(insertedEpoch(conn)).toBe(Date.UTC(Y, 5, 15, 10) / 1000);
    });

    test('fractional seconds are accepted and truncated to whole seconds', async () => {
      const conn = mockRotation(null);
      const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, body({ expiresAt: `${Y}-06-15T10:00:00.999Z` }));
      expect(res.status).toBe(200);
      expect(insertedEpoch(conn)).toBe(Date.UTC(Y, 5, 15, 10) / 1000);
    });

    test('omitted and null both mean "never expires"', async () => {
      let conn = mockRotation(null);
      expect((await signedPost(app, `${BASE}/EXAMPLE_KEY`, body())).status).toBe(200);
      expect(insertedEpoch(conn)).toBeNull();

      conn = mockRotation(null);
      expect((await signedPost(app, `${BASE}/EXAMPLE_KEY`, body({ expiresAt: null }))).status).toBe(200);
      expect(insertedEpoch(conn)).toBeNull();
    });

    test('the 2038-01-19T03:14:07Z upper bound itself is accepted', async () => {
      const conn = mockRotation(null);
      const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, body({ expiresAt: '2038-01-19T03:14:07Z' }));
      expect(res.status).toBe(200);
      expect(insertedEpoch(conn)).toBe(2147483647);
    });

    test.each([
      ['timezone-less',          () => `${Y}-06-15T10:00:00`],
      ['timezone-less, space',   () => `${Y}-06-15 10:00:00`],
      ['impossible date Feb 30', () => `${Y}-02-30T00:00:00Z`],
      ['month 13',               () => `${Y}-13-01T00:00:00Z`],
      ['hour 24',                () => `${Y}-06-15T24:00:00Z`],
      ['no seconds',             () => `${Y}-06-15T10:00Z`],
      ['offset without colon',   () => `${Y}-06-15T10:00:00+0530`],
      ['offset beyond ±14:00',   () => `${Y}-06-15T10:00:00+15:00`],
      ['lower-case z',           () => `${Y}-06-15T10:00:00z`],
      ['single-digit month',     () => `${Y}-6-15T10:00:00Z`],
      ['free text',              () => 'tomorrow'],
      ['empty string',           () => ''],
      ['number, not string',     () => 1798761600],
    ])('%s → 400 "Invalid expiresAt"', async (_label, makeValue) => {
      const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, body({ expiresAt: makeValue() }));
      expect(res.status).toBe(400);
      expect(res.body).toEqual({ success: false, message: 'Invalid expiresAt' });
      expect(db.getConnection).not.toHaveBeenCalled();
    });

    test('a past timestamp → 400', async () => {
      const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, body({ expiresAt: '2020-01-01T00:00:00Z' }));
      expect(res.status).toBe(400);
      expect(res.body).toEqual({ success: false, message: 'expiresAt must be in the future' });
      expect(db.getConnection).not.toHaveBeenCalled();
    });

    test('beyond 2038-01-19T03:14:07Z → 400 (would otherwise silently become "never expires")', async () => {
      for (const v of ['2038-01-19T03:14:08Z', '2040-01-01T00:00:00Z']) {
        const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, body({ expiresAt: v }));
        expect(res.status).toBe(400);
        expect(res.body.message).toBe('expiresAt must be on or before 2038-01-19T03:14:07Z');
      }
      expect(db.getConnection).not.toHaveBeenCalled();
    });
  });

  test('30. missing / blank / oversized adminUser → 400', async () => {
    expect((await signedPost(app, `${BASE}/EXAMPLE_KEY`, { value: 'X' })).status).toBe(400);
    expect((await signedPost(app, `${BASE}/EXAMPLE_KEY`, { value: 'X', adminUser: '   ' })).status).toBe(400);
    expect((await signedPost(app, `${BASE}/EXAMPLE_KEY`, { value: 'X', adminUser: 'a'.repeat(101) })).status).toBe(400);
  });

  test('expectedVersion of the wrong type → 400', async () => {
    const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, body({ expectedVersion: '2' }));
    expect(res.status).toBe(400);
  });

  test.each([['ER_LOCK_DEADLOCK', 1213], ['ER_LOCK_WAIT_TIMEOUT', 1205], ['ER_DUP_ENTRY', 1062]])(
    '31. %s → 409, raw DB error not exposed', async (code, errno) => {
      const conn = createMockConnection();
      conn.execute
        .mockResolvedValueOnce([[]])
        .mockResolvedValueOnce([{}])
        .mockRejectedValueOnce(Object.assign(new Error('Deadlock found when trying to get lock'), { code, errno }));
      db.getConnection.mockResolvedValue(conn);
      const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, body());
      expect(res.status).toBe(409);
      expect(res.body).toEqual({ success: false, message: 'Concurrent modification — retry' });
    });

  test('32–33. success response never contains the plaintext or the encrypted value', async () => {
    const conn = mockRotation(null);
    const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, body({ value: 'DUMMY_SECRET_VALUE_777' }));
    const storedEncrypted = conn.execute.mock.calls[2][1][1];
    const responseText = JSON.stringify(res.body);
    expect(Object.keys(res.body).sort()).toEqual(['keyName', 'success', 'version']);
    expect(responseText).not.toContain('DUMMY_SECRET_VALUE_777');
    expect(responseText).not.toContain(storedEncrypted);
    expect(storedEncrypted).not.toContain('DUMMY_SECRET_VALUE_777'); // and it was actually encrypted
  });

  test('unexpected DB failure → 500 with no internal detail', async () => {
    const conn = createMockConnection();
    conn.execute.mockRejectedValueOnce(Object.assign(new Error("Table 'adminmicro.ip_dynamic_keys' doesn't exist"), { code: 'ER_NO_SUCH_TABLE', sql: 'SELECT ...' }));
    db.getConnection.mockResolvedValue(conn);
    const err = jest.spyOn(console, 'error').mockImplementation(() => {});
    try {
      const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, body());
      expect(res.status).toBe(500);
      expect(res.body).toEqual({ success: false, message: 'Server error' });
    } finally {
      err.mockRestore();
    }
  });
});

// ── Body handling (JSON-only error responses) ───────────────────────────
describe('request body handling', () => {
  test('malformed JSON → 400 JSON response', async () => {
    const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, null, { rawBody: '{"value":' });
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ success: false, message: 'Malformed JSON body' });
  });

  test('JSON array body → 400', async () => {
    const res = await signedPost(app, `${BASE}/EXAMPLE_KEY`, null, { rawBody: '["x"]' });
    expect(res.status).toBe(400);
  });

  test('non-JSON content type → 400', async () => {
    const ts  = now();
    const raw = 'value=x';
    const res = await request(app).post(`${BASE}/EXAMPLE_KEY`)
      .set('Content-Type', 'text/plain')
      .set('X-Admin-Timestamp', ts)
      .set('X-Admin-Signature', sign({ method: 'POST', path: `${BASE}/EXAMPLE_KEY`, timestamp: ts, rawBody: raw }))
      .send(raw);
    expect(res.status).toBe(400);
    expect(res.body.message).toBe('Content-Type must be application/json');
  });

  test('body over the raw limit → 413 JSON response', async () => {
    const res = await request(app).post(`${BASE}/EXAMPLE_KEY`)
      .set('Content-Type', 'application/json')
      .send(JSON.stringify({ value: 'x'.repeat(40 * 1024) }));
    expect(res.status).toBe(413);
    expect(res.body).toEqual({ success: false, message: 'Request body too large' });
  });

  test('unsupported method under this prefix → JSON 404 (after auth)', async () => {
    const ts = now();
    const res = await request(app).delete(`${BASE}/EXAMPLE_KEY`)
      .set('X-Admin-Timestamp', ts)
      .set('X-Admin-Signature', sign({ method: 'DELETE', path: `${BASE}/EXAMPLE_KEY`, timestamp: ts }));
    expect(res.status).toBe(404);
    expect(res.body).toEqual({ success: false, message: 'Not found' });
  });

  test('request bodies and secrets never reach the logs', async () => {
    const spies = ['log', 'warn', 'error'].map(m => jest.spyOn(console, m).mockImplementation(() => {}));
    try {
      mockRotation(null);
      await signedPost(app, `${BASE}/EXAMPLE_KEY`, { value: 'DUMMY_SECRET_VALUE_888', adminUser: 'admin_demo' });
      await signedPost(app, `${BASE}/EXAMPLE_KEY`, { value: 'DUMMY_SECRET_VALUE_888', adminUser: 'admin_demo' }, { secret: 'wrong' });
      await request(app).post(`${BASE}/EXAMPLE_KEY?value=DUMMY_SECRET_VALUE_888`).send('{}');
      const logged = spies.flatMap(s => s.mock.calls).flat().join(' ');
      expect(logged).not.toContain('DUMMY_SECRET_VALUE_888');
      expect(logged).not.toContain(SECRET);
      expect(logged).not.toContain(process.env.DYNAMIC_KEY_MASTER_KEY);
    } finally {
      spies.forEach(s => s.mockRestore());
    }
  });
});
