// dynamicKeyAdminController.js — Dynamic Key Admin API (Phase 4.3).
//
// Metadata-only by design: no handler here ever returns a plaintext value,
// an encrypted_value, or any value-derived preview. Writes accept a
// plaintext value and hand it straight to dynamicKeyService.setKey(), which
// encrypts it — this file never encrypts, decrypts, or logs it.
//
// adminUser is recorded as created_by. It is asserted by the Admin Portal;
// the HMAC signature proves the request came from the portal, not which
// person is using it.
'use strict';
const {
  setKey, listKeyMetadata, getKeyVersions,
  KeyConflictError, VersionConflictError, MAX_EXPIRES_AT_EPOCH,
} = require('../services/dynamicKeyService');

const KEY_NAME_RE           = /^[A-Z][A-Z0-9_]{0,99}$/;
const MAX_VALUE_BYTES       = 4096;
const MAX_ADMIN_USER_CHARS  = 100; // ip_dynamic_keys.created_by is VARCHAR(100)

// Infrastructure/authentication secrets that must never be managed through
// this API (they bootstrap or authenticate the system itself).
const DENIED_KEY_NAMES = new Set([
  'DYNAMIC_KEY_MASTER_KEY',
  'DYNAMIC_KEY_ADMIN_HMAC_SECRET',
  'JWT_SECRET',
  'CLIENT_SERVER_SECRET',
  'ADMIN_WEBHOOK_SECRET',
  'RAZORPAY_WEBHOOK_SECRET',
  'RAZORPAY_KEY_SECRET',
  'DB_PASS',
  'CHATBOT_DB_PASSWORD',
]);

// expiresAt: ISO-8601 with seconds and an explicit zone — "Z" or "±HH:MM",
// e.g. 2027-01-01T00:00:00+05:30 or 2027-01-01T00:00:00.000Z. Timezone-less
// values are rejected rather than read in the server's zone. Parsed field by
// field (not Date.parse), so impossible dates like Feb 30 are rejected
// instead of silently rolling over into March.
const EXPIRES_AT_RE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?(?:Z|([+-])(\d{2}):(\d{2}))$/;

// Returns a Date, or null when the string isn't a valid timestamp.
function _parseExpiresAt(str) {
  const m = EXPIRES_AT_RE.exec(str);
  if (!m) return null;
  const [, y, mo, d, h, mi, s, frac, sign, oh, om] = m;
  const [Y, M, D, H, MI, S] = [y, mo, d, h, mi, s].map(Number);
  if (M < 1 || M > 12) return null;
  const daysInMonth = new Date(Date.UTC(Y, M, 0)).getUTCDate();
  if (D < 1 || D > daysInMonth || H > 23 || MI > 59 || S > 59) return null;

  let offsetMinutes = 0;
  if (sign) {
    const [OH, OM] = [Number(oh), Number(om)];
    if (OH > 14 || OM > 59) return null;
    offsetMinutes = (sign === '+' ? 1 : -1) * (OH * 60 + OM);
  }
  const millis = frac ? Number(frac.padEnd(3, '0')) : 0;
  return new Date(Date.UTC(Y, M - 1, D, H, MI, S, millis) - offsetMinutes * 60000);
}

function _fail(res, status, message) {
  return res.status(status).json({ success: false, message });
}

// Returns an error message, or null when the key name is acceptable.
function _keyNameError(keyName) {
  if (typeof keyName !== 'string' || !KEY_NAME_RE.test(keyName)) return 'Invalid key name';
  if (DENIED_KEY_NAMES.has(keyName)) return 'This key cannot be managed through the Dynamic Key API';
  return null;
}

function _serverError(res, operation, keyName, err) {
  // Name/code only — never err.message, which can carry query details.
  console.error(`[dynamicKeyAdmin] ${operation} failed  key_name=${keyName ?? '-'}  error=${err.name}${err.code ? ` code=${err.code}` : ''}`);
  return _fail(res, 500, 'Server error');
}

// GET /api/admin/dynamic-keys
exports.listKeys = async (req, res) => {
  try {
    const keys = await listKeyMetadata();
    res.json({ success: true, keys });
  } catch (err) {
    _serverError(res, 'listKeys', null, err);
  }
};

// GET /api/admin/dynamic-keys/:keyName
exports.getKey = async (req, res) => {
  const { keyName } = req.params;
  const nameError = _keyNameError(keyName);
  if (nameError) return _fail(res, 400, nameError);

  try {
    const versions = await getKeyVersions(keyName);
    if (versions.length === 0) return _fail(res, 404, 'Key not found');
    res.json({ success: true, keyName, versions });
  } catch (err) {
    _serverError(res, 'getKey', keyName, err);
  }
};

// POST /api/admin/dynamic-keys/:keyName  { value, adminUser, expiresAt?, expectedVersion? }
exports.setKey = async (req, res) => {
  const { keyName } = req.params;
  const nameError = _keyNameError(keyName);
  if (nameError) return _fail(res, 400, nameError);

  const { value, adminUser, expiresAt, expectedVersion } = req.body;

  if (typeof value !== 'string' || value.length === 0) {
    return _fail(res, 400, 'value is required');
  }
  if (Buffer.byteLength(value, 'utf8') > MAX_VALUE_BYTES) {
    return _fail(res, 400, 'Value exceeds maximum allowed size');
  }
  if (typeof adminUser !== 'string' || adminUser.trim().length === 0) {
    return _fail(res, 400, 'adminUser is required');
  }
  if (adminUser.length > MAX_ADMIN_USER_CHARS) {
    return _fail(res, 400, `adminUser must be at most ${MAX_ADMIN_USER_CHARS} characters`);
  }
  let expiresAtDate = null;
  if (expiresAt !== undefined && expiresAt !== null) {
    expiresAtDate = typeof expiresAt === 'string' ? _parseExpiresAt(expiresAt) : null;
    if (!expiresAtDate) return _fail(res, 400, 'Invalid expiresAt');
    // Past expiry rejected: the version would be unusable the moment it's created.
    if (expiresAtDate.getTime() <= Date.now()) {
      return _fail(res, 400, 'expiresAt must be in the future');
    }
    if (Math.floor(expiresAtDate.getTime() / 1000) > MAX_EXPIRES_AT_EPOCH) {
      return _fail(res, 400, 'expiresAt must be on or before 2038-01-19T03:14:07Z');
    }
  }
  if (expectedVersion !== undefined && expectedVersion !== null
      && (!Number.isInteger(expectedVersion) || expectedVersion < 0)) {
    return _fail(res, 400, 'expectedVersion must be a non-negative integer');
  }

  try {
    const result = await setKey(keyName, value, adminUser, expiresAtDate, expectedVersion ?? null);
    res.json({ success: true, keyName: result.keyName, version: result.version });
  } catch (err) {
    if (err instanceof VersionConflictError) return _fail(res, 409, 'Version conflict');
    if (err instanceof KeyConflictError)     return _fail(res, 409, 'Concurrent modification — retry');
    _serverError(res, 'setKey', keyName, err);
  }
};
