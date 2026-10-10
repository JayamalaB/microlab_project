// Tests server/middleware/adminHmacAuth.js — the reusable HMAC admin-auth
// middleware, with the Phase 4.3 raw-body signing contract:
//   HMAC-SHA256(secret, `${METHOD}|${PATH}|${TIMESTAMP}|${sha256(rawBody)}`)
// Requests are sent as raw strings so the exact signed bytes are known.
const crypto  = require('crypto');
const express = require('express');
const request = require('supertest');
const { createAdminHmacAuth, rawBodyCapture } = require('../../middleware/adminHmacAuth');

// adminAuth.js (booking-admin) signs with the active ADMIN_PORTAL_SECRET encrypted_value.
jest.mock('../../services/dynamicKeyService', () => ({ getActiveEncryptedValue: jest.fn() }));
const { getActiveEncryptedValue } = require('../../services/dynamicKeyService');

const SECRET_ENV_VAR = 'TEST_ADMIN_HMAC_SECRET';
const SECRET         = 'test-only-hmac-secret-not-real';

function buildApp() {
  const app = express();
  app.use(rawBodyCapture());
  const auth = createAdminHmacAuth({ secretEnvVar: SECRET_ENV_VAR });
  app.get('/api/admin/dynamic-keys', auth, (req, res) => res.json({ success: true, via: 'GET' }));
  app.post('/api/admin/dynamic-keys/:keyName', auth, (req, res) =>
    res.json({ success: true, via: 'POST', keyName: req.params.keyName }));
  return app;
}

// What a client computes: hash the exact bytes it is about to send.
function sign({ method, path, timestamp, rawBody = '', secret = SECRET }) {
  const bodyHash = crypto.createHash('sha256').update(rawBody, 'utf8').digest('hex');
  return crypto.createHmac('sha256', secret)
    .update(`${method.toUpperCase()}|${path}|${timestamp}|${bodyHash}`)
    .digest('hex');
}

const now = () => Math.floor(Date.now() / 1000).toString();
const POST_PATH = '/api/admin/dynamic-keys/TEST_DYNAMIC_KEY';
const BODY = '{"value":"DUMMY_VALUE_001"}';

function postRaw(app, { signature, timestamp, rawBody = BODY, path = POST_PATH }) {
  return request(app).post(path)
    .set('Content-Type', 'application/json')
    .set('X-Admin-Signature', signature)
    .set('X-Admin-Timestamp', timestamp)
    .send(rawBody);
}

beforeEach(() => { process.env[SECRET_ENV_VAR] = SECRET; });
afterEach(() => { delete process.env[SECRET_ENV_VAR]; });

describe('valid signatures are accepted', () => {
  test('GET with an empty body', async () => {
    const ts = now();
    const res = await request(buildApp()).get('/api/admin/dynamic-keys')
      .set('X-Admin-Signature', sign({ method: 'GET', path: '/api/admin/dynamic-keys', timestamp: ts }))
      .set('X-Admin-Timestamp', ts);
    expect(res.status).toBe(200);
  });

  test('POST whose signature covers the exact raw body bytes', async () => {
    const ts = now();
    const res = await postRaw(buildApp(), { timestamp: ts, signature: sign({ method: 'POST', path: POST_PATH, timestamp: ts, rawBody: BODY }) });
    expect(res.status).toBe(200);
    expect(res.body.keyName).toBe('TEST_DYNAMIC_KEY');
  });

  test('upper-case hex signatures are accepted (hex is case-insensitive)', async () => {
    const ts = now();
    const sig = sign({ method: 'POST', path: POST_PATH, timestamp: ts, rawBody: BODY }).toUpperCase();
    const res = await postRaw(buildApp(), { timestamp: ts, signature: sig });
    expect(res.status).toBe(200);
  });
});

describe('raw-body contract: any byte change breaks the signature', () => {
  test('same JSON with keys in a different order is rejected (bytes differ)', async () => {
    const ts = now();
    const signedBody = '{"value":"X","note":"y"}';
    const sentBody   = '{"note":"y","value":"X"}';
    const res = await postRaw(buildApp(), { timestamp: ts, rawBody: sentBody, signature: sign({ method: 'POST', path: POST_PATH, timestamp: ts, rawBody: signedBody }) });
    expect(res.status).toBe(403);
  });

  test('extra whitespace in the sent body is rejected', async () => {
    const ts = now();
    const res = await postRaw(buildApp(), { timestamp: ts, rawBody: '{"value": "DUMMY_VALUE_001"}', signature: sign({ method: 'POST', path: POST_PATH, timestamp: ts, rawBody: BODY }) });
    expect(res.status).toBe(403);
  });

  test('a modified value in the body is rejected', async () => {
    const ts = now();
    const res = await postRaw(buildApp(), { timestamp: ts, rawBody: '{"value":"DUMMY_VALUE_999"}', signature: sign({ method: 'POST', path: POST_PATH, timestamp: ts, rawBody: BODY }) });
    expect(res.status).toBe(403);
  });
});

describe('missing / malformed credentials', () => {
  test('missing signature → 403', async () => {
    const res = await request(buildApp()).get('/api/admin/dynamic-keys').set('X-Admin-Timestamp', now());
    expect(res.status).toBe(403);
    expect(res.body.message).toBe('Admin credentials missing');
  });

  test('missing timestamp → 403', async () => {
    const res = await request(buildApp()).get('/api/admin/dynamic-keys').set('X-Admin-Signature', 'a'.repeat(64));
    expect(res.status).toBe(403);
    expect(res.body.message).toBe('Admin credentials missing');
  });

  test.each([
    ['non-numeric', 'not-a-number'],
    ['decimal', '1760000000.5'],
    ['negative', '-1760000000'],
    ['trailing garbage', '1760000000abc'],
    ['leading space', ' 1760000000'],
    ['13 digits', '1760000000000'],
  ])('%s timestamp → 403', async (_label, badTs) => {
    const res = await request(buildApp()).get('/api/admin/dynamic-keys')
      .set('X-Admin-Signature', sign({ method: 'GET', path: '/api/admin/dynamic-keys', timestamp: badTs }))
      .set('X-Admin-Timestamp', badTs);
    expect(res.status).toBe(403);
    expect(res.body.message).toBe('Request timestamp expired');
  });

  test('timestamp 10 minutes old → 403', async () => {
    const ts = (Math.floor(Date.now() / 1000) - 600).toString();
    const res = await request(buildApp()).get('/api/admin/dynamic-keys')
      .set('X-Admin-Signature', sign({ method: 'GET', path: '/api/admin/dynamic-keys', timestamp: ts }))
      .set('X-Admin-Timestamp', ts);
    expect(res.status).toBe(403);
  });

  test('timestamp 10 minutes in the future → 403', async () => {
    const ts = (Math.floor(Date.now() / 1000) + 600).toString();
    const res = await request(buildApp()).get('/api/admin/dynamic-keys')
      .set('X-Admin-Signature', sign({ method: 'GET', path: '/api/admin/dynamic-keys', timestamp: ts }))
      .set('X-Admin-Timestamp', ts);
    expect(res.status).toBe(403);
  });

  test('timestamp 299s old is still inside the window → accepted', async () => {
    const ts = (Math.floor(Date.now() / 1000) - 299).toString();
    const res = await request(buildApp()).get('/api/admin/dynamic-keys')
      .set('X-Admin-Signature', sign({ method: 'GET', path: '/api/admin/dynamic-keys', timestamp: ts }))
      .set('X-Admin-Timestamp', ts);
    expect(res.status).toBe(200);
  });

  test('wrong (well-formed) signature → 403', async () => {
    const ts = now();
    const res = await postRaw(buildApp(), { timestamp: ts, signature: sign({ method: 'POST', path: POST_PATH, timestamp: ts, rawBody: BODY, secret: 'some-other-secret' }) });
    expect(res.status).toBe(403);
    expect(res.body.message).toBe('Invalid admin signature');
  });

  test.each([
    ['too short', 'abc'],
    ['too long', 'a'.repeat(128)],
    ['non-hex, right length', 'z'.repeat(64)],
  ])('%s signature → 403 without crashing', async (_label, badSig) => {
    const res = await postRaw(buildApp(), { timestamp: now(), signature: badSig });
    expect(res.status).toBe(403);
    expect(res.body.message).toBe('Invalid admin signature');
  });
});

describe('method / path binding', () => {
  test('signed as GET, sent as POST → 403', async () => {
    const ts = now();
    const res = await postRaw(buildApp(), { timestamp: ts, signature: sign({ method: 'GET', path: POST_PATH, timestamp: ts, rawBody: BODY }) });
    expect(res.status).toBe(403);
  });

  test('signed for a different key name in the path → 403', async () => {
    const ts = now();
    const res = await postRaw(buildApp(), { timestamp: ts, signature: sign({ method: 'POST', path: '/api/admin/dynamic-keys/OTHER_KEY', timestamp: ts, rawBody: BODY }) });
    expect(res.status).toBe(403);
  });
});

describe('configuration safety', () => {
  test('the configured secretEnvVar is the one used', async () => {
    process.env.SOME_OTHER_SECRET = 'other';
    const ts = now();
    // Signed with a different secret's value → rejected.
    const res = await postRaw(buildApp(), { timestamp: ts, signature: sign({ method: 'POST', path: POST_PATH, timestamp: ts, rawBody: BODY, secret: 'other' }) });
    expect(res.status).toBe(403);
    delete process.env.SOME_OTHER_SECRET;
  });

  test('missing secret env var → 500, never accepts', async () => {
    delete process.env[SECRET_ENV_VAR];
    const res = await request(buildApp()).get('/api/admin/dynamic-keys');
    expect(res.status).toBe(500);
    expect(res.body.message).toBe('Server misconfiguration');
  });

  test('fails closed when rawBodyCapture did not run (never treats it as an empty body)', async () => {
    const app = express();
    app.get('/x', createAdminHmacAuth({ secretEnvVar: SECRET_ENV_VAR }), (req, res) => res.json({ ok: true }));
    const ts = now();
    const res = await request(app).get('/x')
      .set('X-Admin-Signature', sign({ method: 'GET', path: '/x', timestamp: ts }))
      .set('X-Admin-Timestamp', ts);
    expect(res.status).toBe(500);
  });

  test('rawBodyCapture refuses to run after another body parser consumed the body', async () => {
    const app = express();
    app.use(express.json());
    app.use(rawBodyCapture());
    app.post('/x', (req, res) => res.json({ ok: true }));
    const res = await request(app).post('/x').set('Content-Type', 'application/json').send('{"a":1}');
    expect(res.status).toBe(500);
    expect(res.body.message).toBe('Server misconfiguration');
  });

  test('the module still uses crypto.timingSafeEqual', () => {
    const src = require('fs').readFileSync(require.resolve('../../middleware/adminHmacAuth'), 'utf8');
    expect(src).toContain('timingSafeEqual');
  });
});

describe('existing booking-admin authentication (adminAuth.js) is untouched', () => {
  test('adminAuth.js still contains its original bookingId|timestamp scheme', () => {
    const src = require('fs').readFileSync(require.resolve('../../middleware/adminAuth'), 'utf8');
    expect(src).toContain('`${bookingId}|${timestamp}`');
    expect(src).toContain('ADMIN_PORTAL_SECRET');
    expect(src).toContain('timingSafeEqual');
  });

  test('adminAuth.js still accepts a correctly signed booking-dispatch request', async () => {
    const adminAuth = require('../../middleware/adminAuth');
    getActiveEncryptedValue.mockResolvedValue('test-admin-portal-secret');
    const app = express();
    app.use(express.json());
    app.post('/api/bookings/:bookingId/dispatch', adminAuth, (req, res) => res.json({ success: true }));
    const bookingId = '70102';
    const ts  = now();
    const sig = crypto.createHmac('sha256', 'test-admin-portal-secret').update(`${bookingId}|${ts}`).digest('hex');
    const res = await request(app).post(`/api/bookings/${bookingId}/dispatch`)
      .set('X-Admin-Signature', sig).set('X-Admin-Timestamp', ts);
    expect(res.status).toBe(200);
    expect(getActiveEncryptedValue).toHaveBeenCalledWith('ADMIN_PORTAL_SECRET');
  });
});

describe('secret leakage', () => {
  test('logs never contain the secret, the signature, or the request body', async () => {
    const logSpy  = jest.spyOn(console, 'log').mockImplementation(() => {});
    const warnSpy = jest.spyOn(console, 'warn').mockImplementation(() => {});
    try {
      const ts  = now();
      const sig = sign({ method: 'POST', path: POST_PATH, timestamp: ts, rawBody: BODY });
      await postRaw(buildApp(), { timestamp: ts, signature: sig });
      await postRaw(buildApp(), { timestamp: ts, signature: 'b'.repeat(64) });
      const logged = [...logSpy.mock.calls, ...warnSpy.mock.calls].flat().join(' ');
      expect(logged).not.toContain(SECRET);
      expect(logged).not.toContain(sig);
      expect(logged).not.toContain('DUMMY_VALUE_001');
    } finally {
      logSpy.mockRestore();
      warnSpy.mockRestore();
    }
  });
});
