// dynamicKeyService.js — Phase 3.3 of Dynamic Key Management.
//
// Reads/writes ip_dynamic_keys (Phase 3.2) using this project's existing
// transaction pattern (db.getConnection() → beginTransaction() →
// connection.execute() → commit()/rollback() → release() — the same shape
// bookingController.js/technicianController.js already use everywhere
// else). All encryption/decryption is delegated entirely to
// server/utils/encryption.js (Phase 3.1) — this file implements no
// cryptography of its own.
//
// No caching (Phase 3.3 scope — deferred to a later phase), no HTTP
// endpoint, no fallback to process.env for any *managed* key. The master
// key itself is the one exception: it is read from
// process.env.DYNAMIC_KEY_MASTER_KEY, since it must exist outside the
// database it protects (see Phase 2's encryption design).
'use strict';
const db = require('../config/db');
const { encrypt, decrypt } = require('../utils/encryption');

class KeyNotFoundError extends Error {
  constructor(keyName) {
    super(`No active, non-expired key found for "${keyName}"`);
    this.name = 'KeyNotFoundError';
    this.keyName = keyName;
  }
}

class DynamicKeyServiceError extends Error {
  constructor(message) {
    super(message);
    this.name = 'DynamicKeyServiceError';
  }
}

// Another writer won the race for this key_name (duplicate active row,
// deadlock, or lock-wait timeout). Retryable. Subclasses
// DynamicKeyServiceError so callers that already catch that keep working.
class KeyConflictError extends DynamicKeyServiceError {
  constructor(keyName) {
    super(`Concurrent modification detected for "${keyName}" — retry`);
    this.name = 'KeyConflictError';
    this.keyName = keyName;
  }
}

// setKey() was given an expectedVersion that no longer matches the latest
// stored version — the caller is working from stale data.
class VersionConflictError extends DynamicKeyServiceError {
  constructor(keyName) {
    super(`Version conflict for "${keyName}"`);
    this.name = 'VersionConflictError';
    this.keyName = keyName;
  }
}

// Latest expiry FROM_UNIXTIME can represent on every supported MariaDB
// version (2038-01-19T03:14:07Z). See setKey().
const MAX_EXPIRES_AT_EPOCH = 2147483647;

// MariaDB/MySQL errors that mean "a concurrent writer got there first".
const CONCURRENCY_ERROR_CODES = new Set(['ER_DUP_ENTRY', 'ER_LOCK_DEADLOCK', 'ER_LOCK_WAIT_TIMEOUT']);
const CONCURRENCY_ERRNOS      = new Set([1062, 1213, 1205]);

function _isConcurrencyConflict(err) {
  return CONCURRENCY_ERROR_CODES.has(err.code) || CONCURRENCY_ERRNOS.has(err.errno);
}

// Reads the master key fresh on every call — never cached, never printed or
// logged. Format/length validation is encryption.js's job (it already
// throws EncryptionError on anything invalid); this function only confirms
// the variable is present at all, and never hashes, pads, truncates, or
// substitutes a fallback for a missing/invalid value.
function _getMasterKey() {
  const masterKey = process.env.DYNAMIC_KEY_MASTER_KEY;
  if (!masterKey) {
    throw new DynamicKeyServiceError('DYNAMIC_KEY_MASTER_KEY is not configured');
  }
  return masterKey;
}

// getKey(keyName) → decrypted plaintext of the current active, non-expired
// version. Throws KeyNotFoundError if no such row exists (missing, every
// version inactive, or the only active version has expired) — never
// returns undefined/null silently, never falls back to another dynamic key
// or to process.env.
async function getKey(keyName) {
  if (typeof keyName !== 'string' || keyName.length === 0) {
    throw new DynamicKeyServiceError('keyName must be a non-empty string');
  }
  const masterKey = _getMasterKey();

  // active_key_name (the generated column from Phase 3.2) is NULL unless
  // is_active=1, and equals key_name when it is — so this single equality
  // lookup against its unique index is both the active-row filter and the
  // fastest possible query shape, with no ORDER BY needed (at most one row
  // can ever match). Expiry is checked in the same query — an expired
  // "active" row is treated identically to no active row existing.
  const [rows] = await db.execute(
    `SELECT encrypted_value FROM ip_dynamic_keys
     WHERE active_key_name = ?
       AND (expires_at IS NULL OR expires_at > NOW())
     LIMIT 1`,
    [keyName]
  );
  const row = rows[0];
  if (!row) throw new KeyNotFoundError(keyName);

  // decrypt() already throws a generic, safe EncryptionError on any
  // failure (tampered payload, wrong master key, etc.) — rethrown as-is,
  // never wrapped with extra detail.
  return decrypt(row.encrypted_value, masterKey);
}

// getActiveEncryptedValue(keyName) → the raw encrypted_value string of the
// current active, non-expired version, exactly as stored. NOT decrypted and
// the master key is not used — callers that sign with the stored value
// itself (adminAuth.js / the Admin Panel) need the identical bytes. Same row
// selection as getKey(). Throws KeyNotFoundError when there is no such row.
// The returned string must be treated as a secret: never log or return it.
async function getActiveEncryptedValue(keyName) {
  if (typeof keyName !== 'string' || keyName.length === 0) {
    throw new DynamicKeyServiceError('keyName must be a non-empty string');
  }
  const [rows] = await db.execute(
    `SELECT encrypted_value FROM ip_dynamic_keys
     WHERE active_key_name = ?
       AND (expires_at IS NULL OR expires_at > NOW())
     LIMIT 1`,
    [keyName]
  );
  const value = rows[0]?.encrypted_value;
  if (typeof value !== 'string' || value.length === 0) throw new KeyNotFoundError(keyName);
  return value;
}

// setKey(keyName, plaintextValue, createdBy, expiresAt) → { keyName, version }
// Creates a new version and activates it; deactivates whatever was
// previously active for this key_name. Both writes happen in one
// transaction — if either fails, nothing is left half-done (Step 5).
//
// Race-condition handling: a SELECT ... FOR UPDATE on this key_name's
// existing rows (if any) is taken BEFORE computing the next version number,
// so a second, concurrent setKey() call for the SAME key_name blocks until
// this transaction commits or rolls back — plain `MAX(version)+1` without
// this lock is not race-safe, since two concurrent reads could both see the
// same max and both compute the same "next" version. This reliably
// serializes rotation of an ALREADY-EXISTING key. For the narrower edge
// case of two truly simultaneous very-first-ever creations of a brand-new
// key_name (no prior row to lock), the real backstop is the database-level
// uq_ip_dynamic_keys_active_key_name constraint from Phase 3.2: even if
// both transactions compute version=1, only one INSERT can succeed — the
// second is caught below and surfaced as one controlled, retryable error.
//
// expectedVersion (optional): if given, the write only proceeds when it
// equals the latest stored version for this key_name (0 = "key must not
// exist yet"); otherwise VersionConflictError. The check happens after the
// FOR UPDATE lock, so it can't race. Deadlocks, lock-wait timeouts, and
// duplicate-active-row errors all surface as KeyConflictError.
//
// expiresAt: null (never expires) or a JS Date — an absolute instant. It is
// stored via FROM_UNIXTIME(epochSeconds), which renders the instant in the
// MariaDB session time zone: the same basis NOW() uses in getKey()'s expiry
// check, so the comparison is correct regardless of Node's time zone.
// Restricted to [1970-01-01T00:00:00Z, 2038-01-19T03:14:07Z] because
// FROM_UNIXTIME returns NULL outside that range on older MariaDB — which
// would silently turn an expiring key into a never-expiring one.
async function setKey(keyName, plaintextValue, createdBy = null, expiresAt = null, expectedVersion = null) {
  if (typeof keyName !== 'string' || keyName.length === 0) {
    throw new DynamicKeyServiceError('keyName must be a non-empty string');
  }
  if (typeof plaintextValue !== 'string' || plaintextValue.length === 0) {
    throw new DynamicKeyServiceError('plaintextValue must be a non-empty string');
  }
  if (expectedVersion !== null && expectedVersion !== undefined
      && (!Number.isInteger(expectedVersion) || expectedVersion < 0)) {
    throw new DynamicKeyServiceError('expectedVersion must be a non-negative integer');
  }
  let expiresAtEpoch = null;
  if (expiresAt !== null && expiresAt !== undefined) {
    if (!(expiresAt instanceof Date) || Number.isNaN(expiresAt.getTime())) {
      throw new DynamicKeyServiceError('expiresAt must be a valid Date or null');
    }
    expiresAtEpoch = Math.floor(expiresAt.getTime() / 1000);
    if (expiresAtEpoch < 0 || expiresAtEpoch > MAX_EXPIRES_AT_EPOCH) {
      throw new DynamicKeyServiceError('expiresAt is outside the supported range');
    }
  }
  const masterKey = _getMasterKey();
  // Encrypt BEFORE opening a connection — an invalid master key or bad
  // plaintext fails fast, never touching the database at all.
  const encryptedValue = encrypt(plaintextValue, masterKey);

  const connection = await db.getConnection();
  try {
    await connection.beginTransaction();

    const [existingRows] = await connection.execute(
      `SELECT version FROM ip_dynamic_keys
       WHERE key_name = ?
       ORDER BY version DESC LIMIT 1
       FOR UPDATE`,
      [keyName]
    );
    const latestVersion = existingRows.length > 0 ? existingRows[0].version : 0;
    if (expectedVersion !== null && expectedVersion !== undefined && expectedVersion !== latestVersion) {
      throw new VersionConflictError(keyName);
    }
    const nextVersion = latestVersion + 1;

    await connection.execute(
      `UPDATE ip_dynamic_keys SET is_active = 0, updated_at = NOW()
       WHERE key_name = ? AND is_active = 1`,
      [keyName]
    );

    await connection.execute(
      `INSERT INTO ip_dynamic_keys
         (key_name, encrypted_value, is_active, version, created_by, expires_at, created_at)
       VALUES (?, ?, 1, ?, ?, FROM_UNIXTIME(?), NOW())`,
      [keyName, encryptedValue, nextVersion, createdBy, expiresAtEpoch]
    );

    await connection.commit();
    return { keyName, version: nextVersion };
  } catch (err) {
    await connection.rollback();
    if (err instanceof VersionConflictError) throw err;
    if (_isConcurrencyConflict(err)) throw new KeyConflictError(keyName);
    console.error(`[dynamicKeyService] setKey failed for key_name=${keyName}: ${err.message}`);
    throw err;
  } finally {
    connection.release();
  }
}

// ── Metadata-only reads (Admin API) ─────────────────────────────────────
// Neither function selects encrypted_value or calls decrypt() — they only
// ever return version bookkeeping, never secret material in any form.

// listKeyMetadata() → [{ keyName, activeVersion, latestVersion, expiresAt,
// updatedAt, updatedBy }], one entry per key_name. updatedAt/updatedBy are
// the latest version's created_at/created_by; expiresAt is the active
// version's (null when there is no active version).
async function listKeyMetadata() {
  const [rows] = await db.execute(
    `SELECT latest.key_name, latest.version AS latest_version,
            latest.created_at AS updated_at, latest.created_by AS updated_by,
            active.version AS active_version, active.expires_at
     FROM ip_dynamic_keys latest
     JOIN (SELECT key_name, MAX(version) AS max_version
           FROM ip_dynamic_keys GROUP BY key_name) m
       ON m.key_name = latest.key_name AND m.max_version = latest.version
     LEFT JOIN ip_dynamic_keys active ON active.active_key_name = latest.key_name
     ORDER BY latest.key_name`
  );
  return rows.map(r => ({
    keyName:       r.key_name,
    activeVersion: r.active_version ?? null,
    latestVersion: r.latest_version,
    expiresAt:     r.expires_at ?? null,
    updatedAt:     r.updated_at,
    updatedBy:     r.updated_by ?? null,
  }));
}

// getKeyVersions(keyName) → [{ version, isActive, createdAt, createdBy,
// expiresAt }], newest first. Empty array when the key doesn't exist.
async function getKeyVersions(keyName) {
  if (typeof keyName !== 'string' || keyName.length === 0) {
    throw new DynamicKeyServiceError('keyName must be a non-empty string');
  }
  const [rows] = await db.execute(
    `SELECT version, is_active, created_at, created_by, expires_at
     FROM ip_dynamic_keys
     WHERE key_name = ?
     ORDER BY version DESC`,
    [keyName]
  );
  return rows.map(r => ({
    version:   r.version,
    isActive:  r.is_active === 1 || r.is_active === true,
    createdAt: r.created_at,
    createdBy: r.created_by ?? null,
    expiresAt: r.expires_at ?? null,
  }));
}

module.exports = {
  getKey, getActiveEncryptedValue, setKey, listKeyMetadata, getKeyVersions,
  KeyNotFoundError, DynamicKeyServiceError, KeyConflictError, VersionConflictError,
  MAX_EXPIRES_AT_EPOCH,
};
