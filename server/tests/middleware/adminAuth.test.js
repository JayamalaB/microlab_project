// Tests server/middleware/adminAuth.js — the booking-admin HMAC check used by
// POST /api/bookings/admin and POST /api/bookings/:bookingId/dispatch.
// The HMAC secret is the active ADMIN_PORTAL_SECRET row's encrypted_value,
// used exactly as stored (no decryption):
//   X-Admin-Signature = hex( HMAC-SHA256( encrypted_value, `${bookingId}|${timestamp}` ) )
// Dummy values only.
jest.mock('../../config/db');
jest.mock('../../utils/encryption', () => {
  const actual = jest.requireActual('../../utils/encryption');
  return { ...actual, decrypt: jest.fn(actual.decrypt) };
});
jest.mock('../../services/dynamicKeyService', () => {
  const actual = jest.requireActual('../../services/dynamicKeyService');
  return { ...actual, getKey: jest.fn(), getActiveEncryptedValue: jest.fn() };
});
const crypto  = require('crypto');
const express = require('express');
const request = require('supertest');
const db      = require('../../config/db');
const encryption = require('../../utils/encryption');
const dynamicKeyService = require('../../services/dynamicKeyService');
const { KeyNotFoundError } = dynamicKeyService;
const adminAuth = require('../../middleware/adminAuth');

const { getActiveEncryptedValue, getKey } = dynamicKeyService;
const realGetActiveEncryptedValue = jest.requireActual('../../services/dynamicKeyService').getActiveEncryptedValue;

const PLAINTEXT = 'test-only-admin-portal-secret';
// What the row really holds: an AES-256-GCM payload "iv:tag:ciphertext".
const STORED = encryption.encrypt(PLAINTEXT, process.env.DYNAMIC_KEY_MASTER_KEY);

const now = () => Math.floor(Date.now() / 1000).toString();
const sign = (bookingId, ts, secret = STORED) =>
  crypto.createHmac('sha256', secret).update(`${bookingId}|${ts}`).digest('hex');

function buildApp() {
  const app = express();
  app.use(express.json());
  app.post('/api/bookings/admin', adminAuth, (req, res) => res.status(201).json({ success: true, reached: 'create' }));
  app.post('/api/bookings/:bookingId/dispatch', adminAuth, (req, res) => res.json({ success: true, reached: 'dispatch' }));
  return app;
}

function post(path, { signature, timestamp } = {}) {
  const req = request(buildApp()).post(path).send({ clientId: 1, patientId: 86 });
  if (signature !== undefined) req.set('X-Admin-Signature', signature);
  if (timestamp !== undefined) req.set('X-Admin-Timestamp', timestamp);
  return req;
}

let logSpy, warnSpy, errorSpy;
const allLogs = () => [logSpy, warnSpy, errorSpy]
  .flatMap(s => s.mock.calls.map(args => args.join(' ')))
  .join('\n');

beforeEach(() => {
  getActiveEncryptedValue.mockReset().mockResolvedValue(STORED);
  getKey.mockReset();
  encryption.decrypt.mockClear();
  db.execute.mockReset();
  logSpy   = jest.spyOn(console, 'log').mockImplementation(() => {});
  warnSpy  = jest.spyOn(console, 'warn').mockImplementation(() => {});
  errorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
});
afterEach(() => {
  jest.restoreAllMocks();
  delete process.env.ADMIN_PORTAL_SECRET;
});

describe('valid signatures (signed with the stored encrypted_value)', () => {
  test('1. correct signature for /:bookingId/dispatch → next()', async () => {
    const ts  = now();
    const res = await post('/api/bookings/70102/dispatch', { timestamp: ts, signature: sign('70102', ts) });
    expect(res.status).toBe(200);
    expect(res.body.reached).toBe('dispatch');
  });

  test('2. correct signature for /admin (empty bookingId, "|timestamp") → next()', async () => {
    const ts  = now();
    const res = await post('/api/bookings/admin', { timestamp: ts, signature: sign('', ts) });
    expect(res.status).toBe(201);
    expect(res.body.reached).toBe('create');
  });

  test('2b. same HMAC as PHP hash_hmac("sha256", "id|ts", $encrypted_value)', async () => {
    // Fixed known-answer: the stored value is used as raw string bytes.
    const fixedStored = 'AAAAAAAAAAAAAAAA:BBBBBBBBBBBBBBBBBBBBBB==:CCCC';
    const expected = crypto.createHmac('sha256', Buffer.from(fixedStored, 'utf8')).update('70102|1791380000').digest('hex');
    expect(sign('70102', '1791380000', fixedStored)).toBe(expected);
  });
});

describe('no decryption is performed', () => {
  test('3. decrypt() and getKey() are never called', async () => {
    const ts = now();
    await post('/api/bookings/70102/dispatch', { timestamp: ts, signature: sign('70102', ts) });
    expect(encryption.decrypt).not.toHaveBeenCalled();
    expect(getKey).not.toHaveBeenCalled();
  });

  test('4. a signature made with the PLAINTEXT secret is rejected', async () => {
    const ts  = now();
    const res = await post('/api/bookings/70102/dispatch', { timestamp: ts, signature: sign('70102', ts, PLAINTEXT) });
    expect(res.status).toBe(403);
    expect(res.body).toEqual({ success: false, message: 'Invalid admin signature' });
  });

  test('5. works without DYNAMIC_KEY_MASTER_KEY', async () => {
    const original = process.env.DYNAMIC_KEY_MASTER_KEY;
    delete process.env.DYNAMIC_KEY_MASTER_KEY;
    try {
      const ts  = now();
      const res = await post('/api/bookings/70102/dispatch', { timestamp: ts, signature: sign('70102', ts) });
      expect(res.status).toBe(200);
    } finally {
      process.env.DYNAMIC_KEY_MASTER_KEY = original;
    }
  });
});

describe('rejections (unchanged responses)', () => {
  test('6. wrong signature → 403 "Invalid admin signature"', async () => {
    const ts  = now();
    const res = await post('/api/bookings/70102/dispatch', { timestamp: ts, signature: sign('70102', ts, 'some-other-secret') });
    expect(res.status).toBe(403);
    expect(res.body).toEqual({ success: false, message: 'Invalid admin signature' });
  });

  test('7. signature for a different bookingId → 403', async () => {
    const ts  = now();
    const res = await post('/api/bookings/70102/dispatch', { timestamp: ts, signature: sign('70103', ts) });
    expect(res.status).toBe(403);
  });

  test('8. missing headers → 403 "Admin credentials missing", secret not read', async () => {
    const ts = now();
    for (const headers of [{}, { timestamp: ts }, { signature: sign('', ts) }]) {
      const res = await post('/api/bookings/admin', headers);
      expect(res.status).toBe(403);
      expect(res.body).toEqual({ success: false, message: 'Admin credentials missing' });
    }
    expect(getActiveEncryptedValue).not.toHaveBeenCalled();
  });

  test('9. expired timestamp (past or future) → 403 "Request timestamp expired", secret not read', async () => {
    for (const ts of [String(Number(now()) - 301), String(Number(now()) + 301), 'not-a-number']) {
      const res = await post('/api/bookings/70102/dispatch', { timestamp: ts, signature: sign('70102', ts) });
      expect(res.status).toBe(403);
      expect(res.body).toEqual({ success: false, message: 'Request timestamp expired' });
    }
    expect(getActiveEncryptedValue).not.toHaveBeenCalled();
  });

  test('10. timestamp inside the ±300s window is accepted', async () => {
    const ts  = String(Number(now()) - 290);
    const res = await post('/api/bookings/70102/dispatch', { timestamp: ts, signature: sign('70102', ts) });
    expect(res.status).toBe(200);
  });

  test('11. invalid / bad-length signature → 403 without exception', async () => {
    const ts = now();
    for (const bad of ['abc', 'zz'.repeat(32), 'a'.repeat(63), sign('70102', ts) + 'ab']) {
      const res = await post('/api/bookings/70102/dispatch', { timestamp: ts, signature: bad });
      expect(res.status).toBe(403);
      expect(res.body.message).toBe('Invalid admin signature');
    }
  });
});

describe('secret unavailable → 500 "Server misconfiguration" (fail closed)', () => {
  const failures = [
    ['12. no active / non-expired row (KeyNotFoundError)', () => new KeyNotFoundError('ADMIN_PORTAL_SECRET')],
    ['13. DB error', () => Object.assign(new Error('connect ECONNREFUSED 127.0.0.1:3306 SENSITIVE_DB_DETAIL'), { code: 'ECONNREFUSED' })],
  ];

  test.each(failures)('%s', async (_label, makeErr) => {
    const err = makeErr();
    getActiveEncryptedValue.mockRejectedValueOnce(err);
    const ts  = now();
    const res = await post('/api/bookings/70102/dispatch', { timestamp: ts, signature: sign('70102', ts) });

    expect(res.status).toBe(500);
    expect(res.headers['content-type']).toMatch(/application\/json/);
    expect(res.body).toEqual({ success: false, message: 'Server misconfiguration' });
    expect(res.body.reached).toBeUndefined();
    const logs = allLogs();
    expect(logs).toContain(err.name);
    expect(logs).not.toContain(err.message);
  });
});

describe('secret source', () => {
  test('14. reads exactly "ADMIN_PORTAL_SECRET", once per request', async () => {
    const ts = now();
    await post('/api/bookings/70102/dispatch', { timestamp: ts, signature: sign('70102', ts) });
    expect(getActiveEncryptedValue).toHaveBeenCalledTimes(1);
    expect(getActiveEncryptedValue).toHaveBeenCalledWith('ADMIN_PORTAL_SECRET');
  });

  test('15. process.env.ADMIN_PORTAL_SECRET is ignored', async () => {
    process.env.ADMIN_PORTAL_SECRET = 'old-env-value-must-be-ignored';
    const ts = now();
    const withEnv = await post('/api/bookings/70102/dispatch', { timestamp: ts, signature: sign('70102', ts, 'old-env-value-must-be-ignored') });
    expect(withEnv.status).toBe(403);
    const withStored = await post('/api/bookings/70102/dispatch', { timestamp: ts, signature: sign('70102', ts) });
    expect(withStored.status).toBe(200);
  });

  test('16. logs never contain the stored value, the plaintext or the signature', async () => {
    const ts   = now();
    const good = sign('70102', ts);
    const bad  = sign('70102', ts, 'some-other-secret');
    await post('/api/bookings/70102/dispatch', { timestamp: ts, signature: good });
    await post('/api/bookings/70102/dispatch', { timestamp: ts, signature: bad });
    await post('/api/bookings/admin', { timestamp: ts, signature: sign('', ts) });
    const logs = allLogs();
    expect(logs.length).toBeGreaterThan(0);
    expect(logs).not.toContain(STORED);
    expect(logs).not.toContain(PLAINTEXT);
    expect(logs).not.toContain(good);
    expect(logs).not.toContain(bad);
  });
});

describe('integration — real getActiveEncryptedValue(), DB mocked', () => {
  beforeEach(() => { getActiveEncryptedValue.mockImplementation(realGetActiveEncryptedValue); });

  test('17. active row → request signed with its encrypted_value succeeds', async () => {
    db.execute.mockResolvedValue([[{ encrypted_value: STORED }]]);
    const ts  = now();
    const res = await post('/api/bookings/admin', { timestamp: ts, signature: sign('', ts) });
    expect(res.status).toBe(201);

    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toContain('active_key_name = ?');
    expect(sql).toContain('expires_at IS NULL OR expires_at > NOW()');
    expect(params).toEqual(['ADMIN_PORTAL_SECRET']);
    expect(encryption.decrypt).not.toHaveBeenCalled();
  });

  test('18. no active / non-expired row → 500', async () => {
    db.execute.mockResolvedValue([[]]);
    const ts  = now();
    const res = await post('/api/bookings/admin', { timestamp: ts, signature: sign('', ts) });
    expect(res.status).toBe(500);
    expect(res.body).toEqual({ success: false, message: 'Server misconfiguration' });
  });

  test('19. rotation: after a new version, the old stored value is rejected', async () => {
    const rotated = encryption.encrypt(PLAINTEXT, process.env.DYNAMIC_KEY_MASTER_KEY); // fresh IV → new string
    expect(rotated).not.toBe(STORED);
    db.execute.mockResolvedValue([[{ encrypted_value: rotated }]]);
    const ts = now();
    const oldSig = await post('/api/bookings/70102/dispatch', { timestamp: ts, signature: sign('70102', ts, STORED) });
    expect(oldSig.status).toBe(403);
    const newSig = await post('/api/bookings/70102/dispatch', { timestamp: ts, signature: sign('70102', ts, rotated) });
    expect(newSig.status).toBe(200);
  });
});
