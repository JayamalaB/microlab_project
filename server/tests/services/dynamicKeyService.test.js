// Tests server/services/dynamicKeyService.js — Phase 3.3 of Dynamic Key
// Management. Dummy test values only (TEST_DYNAMIC_KEY / DUMMY_VALUE_00x),
// never a real secret. Uses the real server/utils/encryption.js (Phase 3.1)
// — no crypto is mocked here, only the DB layer, so these tests prove the
// real encrypt/decrypt round-trip through the service, not a stand-in.
jest.mock('../../config/db');
const db = require('../../config/db');
const { createMockConnection } = require('../helpers/mockConnection');
const {
  getKey, setKey, KeyNotFoundError, DynamicKeyServiceError,
} = require('../../services/dynamicKeyService');
const { decrypt } = require('../../utils/encryption');

const KEY_NAME = 'TEST_DYNAMIC_KEY';
const REAL_MASTER_KEY = process.env.DYNAMIC_KEY_MASTER_KEY; // set in tests/setupEnv.js

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.getConnection.mockReset();
});

describe('getKey — read path', () => {
  test('Test 2 — returns the decrypted plaintext of the active key', async () => {
    const { encrypt } = require('../../utils/encryption');
    const encrypted = encrypt('DUMMY_VALUE_001', REAL_MASTER_KEY);
    db.execute.mockResolvedValueOnce([[{ encrypted_value: encrypted }]]);

    const result = await getKey(KEY_NAME);
    expect(result).toBe('DUMMY_VALUE_001');

    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toContain('active_key_name = ?');
    expect(sql).toContain('expires_at IS NULL OR expires_at > NOW()');
    expect(params).toEqual([KEY_NAME]);
  });

  test('Test 6 — missing key throws a controlled KeyNotFoundError, never returns undefined', async () => {
    db.execute.mockResolvedValueOnce([[]]);
    await expect(getKey('DOES_NOT_EXIST')).rejects.toBeInstanceOf(KeyNotFoundError);
  });

  test('Test 5 — an expired active row is treated as not found', async () => {
    // The query itself excludes expired rows (expires_at > NOW()), so the
    // mock simply returns no rows — exactly what the real WHERE clause
    // would produce for an expired-but-otherwise-active row.
    db.execute.mockResolvedValueOnce([[]]);
    await expect(getKey(KEY_NAME)).rejects.toBeInstanceOf(KeyNotFoundError);
  });

  test('Test 7 — a tampered encrypted_value fails decryption safely, no plaintext/detail leaked', async () => {
    const { encrypt } = require('../../utils/encryption');
    const encrypted = encrypt('DUMMY_VALUE_001', REAL_MASTER_KEY);
    const [iv, authTag, ct] = encrypted.split(':');
    const ctBuf = Buffer.from(ct, 'base64');
    ctBuf[0] ^= 0xff; // flip one byte
    const tampered = `${iv}:${authTag}:${ctBuf.toString('base64')}`;

    db.execute.mockResolvedValueOnce([[{ encrypted_value: tampered }]]);

    let caught;
    try { await getKey(KEY_NAME); } catch (e) { caught = e; }
    expect(caught).toBeDefined();
    expect(caught.message).toBe('Decryption failed'); // encryption.js's generic message, nothing more
    expect(caught.message).not.toContain('DUMMY_VALUE_001');
  });

  test('invalid/missing master key fails safely without ever reaching the database query result', async () => {
    const original = process.env.DYNAMIC_KEY_MASTER_KEY;
    delete process.env.DYNAMIC_KEY_MASTER_KEY;
    try {
      await expect(getKey(KEY_NAME)).rejects.toBeInstanceOf(DynamicKeyServiceError);
    } finally {
      process.env.DYNAMIC_KEY_MASTER_KEY = original;
    }
  });

  test('rejects an empty/non-string keyName before any DB call', async () => {
    await expect(getKey('')).rejects.toBeInstanceOf(DynamicKeyServiceError);
    expect(db.execute).not.toHaveBeenCalled();
  });
});

describe('setKey — create / rotate path', () => {
  test('Test 1 + Test 8 — creating the first version stores ciphertext, never the plaintext', async () => {
    const conn = createMockConnection();
    conn.execute
      .mockResolvedValueOnce([[]])    // FOR UPDATE — no existing rows
      .mockResolvedValueOnce([{}])    // UPDATE deactivate (no-op, nothing was active)
      .mockResolvedValueOnce([{ insertId: 1 }]); // INSERT
    db.getConnection.mockResolvedValue(conn);

    const result = await setKey(KEY_NAME, 'DUMMY_VALUE_001', 'test-admin', null);
    expect(result).toEqual({ keyName: KEY_NAME, version: 1 });

    const insertCall = conn.execute.mock.calls[2];
    const storedEncryptedValue = insertCall[1][1]; // (key_name, encrypted_value, ...)
    expect(storedEncryptedValue).not.toBe('DUMMY_VALUE_001');
    expect(storedEncryptedValue).not.toContain('DUMMY_VALUE_001');
    // Round-trips back to the original via the real decrypt() — proves it's
    // genuinely encrypted, not just a different-looking string.
    expect(decrypt(storedEncryptedValue, REAL_MASTER_KEY)).toBe('DUMMY_VALUE_001');

    expect(conn.commit).toHaveBeenCalled();
    expect(conn.rollback).not.toHaveBeenCalled();
    expect(conn.release).toHaveBeenCalled();
  });

  test('Test 3 + Test 4 — rotating deactivates the previous version and activates version 2', async () => {
    const conn = createMockConnection();
    conn.execute
      .mockResolvedValueOnce([[{ version: 1 }]]) // FOR UPDATE — version 1 already exists
      .mockResolvedValueOnce([{ affectedRows: 1 }]) // UPDATE deactivate version 1
      .mockResolvedValueOnce([{ insertId: 2 }]); // INSERT version 2
    db.getConnection.mockResolvedValue(conn);

    const result = await setKey(KEY_NAME, 'DUMMY_VALUE_002');
    expect(result).toEqual({ keyName: KEY_NAME, version: 2 });

    const deactivateCall = conn.execute.mock.calls[1];
    expect(deactivateCall[0]).toContain('is_active = 0');
    expect(deactivateCall[0]).toContain('is_active = 1'); // WHERE clause targets the currently-active row
    expect(deactivateCall[1]).toEqual([KEY_NAME]);

    const insertCall = conn.execute.mock.calls[2];
    expect(insertCall[1][2]).toBe(2); // version param
  });

  test('version increments are computed via SELECT ... FOR UPDATE, not a bare MAX()', async () => {
    const conn = createMockConnection();
    conn.execute
      .mockResolvedValueOnce([[{ version: 4 }]])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{ insertId: 99 }]);
    db.getConnection.mockResolvedValue(conn);

    await setKey(KEY_NAME, 'DUMMY_VALUE_005');
    const selectCall = conn.execute.mock.calls[0];
    expect(selectCall[0]).toContain('FOR UPDATE');
    expect(selectCall[0]).toContain('ORDER BY version DESC');
  });

  test('transaction rollback — an INSERT failure leaves nothing committed, old row untouched', async () => {
    const conn = createMockConnection();
    conn.execute
      .mockResolvedValueOnce([[{ version: 1 }]])
      .mockResolvedValueOnce([{}]) // deactivate succeeds
      .mockRejectedValueOnce(new Error('simulated DB failure on insert'));
    db.getConnection.mockResolvedValue(conn);

    await expect(setKey(KEY_NAME, 'DUMMY_VALUE_002')).rejects.toThrow('simulated DB failure on insert');
    expect(conn.rollback).toHaveBeenCalled();
    expect(conn.commit).not.toHaveBeenCalled();
    expect(conn.release).toHaveBeenCalled();
  });

  test('concurrent rotation — a unique-constraint violation on the active-row insert is surfaced as one controlled, retryable error', async () => {
    const conn = createMockConnection();
    const dupError = new Error("Duplicate entry 'TEST_DYNAMIC_KEY' for key 'uq_ip_dynamic_keys_active_key_name'");
    dupError.code = 'ER_DUP_ENTRY';
    conn.execute
      .mockResolvedValueOnce([[]])
      .mockResolvedValueOnce([{}])
      .mockRejectedValueOnce(dupError);
    db.getConnection.mockResolvedValue(conn);

    let caught;
    try {
      await setKey(KEY_NAME, 'DUMMY_VALUE_001');
    } catch (e) {
      caught = e;
    }
    expect(caught).toBeInstanceOf(DynamicKeyServiceError);
    expect(caught.message).toMatch(/[Cc]oncurrent/);
    expect(conn.rollback).toHaveBeenCalled();
  });

  test('rejects empty plaintext or keyName before ever opening a connection', async () => {
    await expect(setKey('', 'DUMMY_VALUE_001')).rejects.toBeInstanceOf(DynamicKeyServiceError);
    await expect(setKey(KEY_NAME, '')).rejects.toBeInstanceOf(DynamicKeyServiceError);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('invalid master key fails before opening a connection or touching the DB at all', async () => {
    const original = process.env.DYNAMIC_KEY_MASTER_KEY;
    delete process.env.DYNAMIC_KEY_MASTER_KEY;
    try {
      await expect(setKey(KEY_NAME, 'DUMMY_VALUE_001')).rejects.toBeInstanceOf(DynamicKeyServiceError);
      expect(db.getConnection).not.toHaveBeenCalled();
    } finally {
      process.env.DYNAMIC_KEY_MASTER_KEY = original;
    }
  });
});

describe('secret leakage check', () => {
  test('neither getKey nor setKey ever calls console.log with the plaintext or master key', async () => {
    const logSpy = jest.spyOn(console, 'log').mockImplementation(() => {});
    try {
      const conn = createMockConnection();
      conn.execute
        .mockResolvedValueOnce([[]])
        .mockResolvedValueOnce([{}])
        .mockResolvedValueOnce([{ insertId: 1 }]);
      db.getConnection.mockResolvedValue(conn);
      await setKey(KEY_NAME, 'DUMMY_VALUE_001');

      const { encrypt } = require('../../utils/encryption');
      const encrypted = encrypt('DUMMY_VALUE_001', REAL_MASTER_KEY);
      db.execute.mockResolvedValueOnce([[{ encrypted_value: encrypted }]]);
      await getKey(KEY_NAME);

      const allLoggedText = logSpy.mock.calls.flat().join(' ');
      expect(allLoggedText).not.toContain('DUMMY_VALUE_001');
      expect(allLoggedText).not.toContain(REAL_MASTER_KEY);
    } finally {
      logSpy.mockRestore();
    }
  });
});

// ── Phase 4.3 additions ─────────────────────────────────────────────────
const {
  listKeyMetadata, getKeyVersions, KeyConflictError, VersionConflictError,
} = require('../../services/dynamicKeyService');

function connWithLatestVersion(latestVersion) {
  const conn = createMockConnection();
  conn.execute
    .mockResolvedValueOnce([latestVersion === null ? [] : [{ version: latestVersion }]])
    .mockResolvedValueOnce([{}])
    .mockResolvedValueOnce([{ insertId: 1 }]);
  db.getConnection.mockResolvedValue(conn);
  return conn;
}

describe('setKey — expectedVersion (Phase 4.3)', () => {
  test('matching expectedVersion rotates normally', async () => {
    connWithLatestVersion(2);
    await expect(setKey(KEY_NAME, 'DUMMY_VALUE_003', 'admin_demo', null, 2))
      .resolves.toEqual({ keyName: KEY_NAME, version: 3 });
  });

  test('expectedVersion 0 means "must not exist yet" — succeeds for a new key', async () => {
    connWithLatestVersion(null);
    await expect(setKey(KEY_NAME, 'DUMMY_VALUE_001', 'admin_demo', null, 0))
      .resolves.toEqual({ keyName: KEY_NAME, version: 1 });
  });

  test('stale expectedVersion → VersionConflictError, rolled back, nothing written', async () => {
    const conn = connWithLatestVersion(3);
    await expect(setKey(KEY_NAME, 'DUMMY_VALUE_004', 'admin_demo', null, 2))
      .rejects.toBeInstanceOf(VersionConflictError);
    expect(conn.rollback).toHaveBeenCalled();
    expect(conn.commit).not.toHaveBeenCalled();
    expect(conn.execute).toHaveBeenCalledTimes(1); // only the FOR UPDATE read — no UPDATE/INSERT
    expect(conn.release).toHaveBeenCalled();
  });

  test('non-integer expectedVersion is rejected before opening a connection', async () => {
    await expect(setKey(KEY_NAME, 'DUMMY_VALUE_001', 'admin_demo', null, 1.5))
      .rejects.toBeInstanceOf(DynamicKeyServiceError);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('omitting expectedVersion keeps the original behaviour (no version check)', async () => {
    connWithLatestVersion(7);
    await expect(setKey(KEY_NAME, 'DUMMY_VALUE_008')).resolves.toEqual({ keyName: KEY_NAME, version: 8 });
  });
});

describe('setKey — concurrency error mapping (Phase 4.3)', () => {
  test.each([
    ['ER_LOCK_DEADLOCK', 1213],
    ['ER_LOCK_WAIT_TIMEOUT', 1205],
    ['ER_DUP_ENTRY', 1062],
  ])('%s → KeyConflictError (still a DynamicKeyServiceError)', async (code, errno) => {
    const conn = createMockConnection();
    const dbErr = Object.assign(new Error('simulated'), { code, errno });
    conn.execute
      .mockResolvedValueOnce([[]])
      .mockResolvedValueOnce([{}])
      .mockRejectedValueOnce(dbErr);
    db.getConnection.mockResolvedValue(conn);

    let caught;
    try { await setKey(KEY_NAME, 'DUMMY_VALUE_001'); } catch (e) { caught = e; }
    expect(caught).toBeInstanceOf(KeyConflictError);
    expect(caught).toBeInstanceOf(DynamicKeyServiceError);
    expect(conn.rollback).toHaveBeenCalled();
  });
});

describe('listKeyMetadata / getKeyVersions (Phase 4.3) — metadata only', () => {
  test('listKeyMetadata maps rows and never selects encrypted_value', async () => {
    db.execute.mockResolvedValueOnce([[{
      key_name: 'EXAMPLE_KEY', latest_version: 3, active_version: 3,
      expires_at: null, updated_at: '2026-10-07 15:00:00', updated_by: 'admin_demo',
    }]]);
    const keys = await listKeyMetadata();
    expect(keys).toEqual([{
      keyName: 'EXAMPLE_KEY', activeVersion: 3, latestVersion: 3,
      expiresAt: null, updatedAt: '2026-10-07 15:00:00', updatedBy: 'admin_demo',
    }]);
    expect(db.execute.mock.calls[0][0]).not.toContain('encrypted_value');
  });

  test('listKeyMetadata reports activeVersion null when no version is active', async () => {
    db.execute.mockResolvedValueOnce([[{
      key_name: 'EXAMPLE_KEY', latest_version: 2, active_version: null,
      expires_at: null, updated_at: '2026-10-07 15:00:00', updated_by: null,
    }]]);
    const [entry] = await listKeyMetadata();
    expect(entry.activeVersion).toBeNull();
  });

  test('getKeyVersions maps rows newest-first and never selects encrypted_value', async () => {
    db.execute.mockResolvedValueOnce([[
      { version: 2, is_active: 1, created_at: '2026-10-07 15:00:00', created_by: 'admin_demo', expires_at: null },
      { version: 1, is_active: 0, created_at: '2026-10-06 14:00:00', created_by: 'admin_demo', expires_at: null },
    ]]);
    const versions = await getKeyVersions('EXAMPLE_KEY');
    expect(versions).toEqual([
      { version: 2, isActive: true,  createdAt: '2026-10-07 15:00:00', createdBy: 'admin_demo', expiresAt: null },
      { version: 1, isActive: false, createdAt: '2026-10-06 14:00:00', createdBy: 'admin_demo', expiresAt: null },
    ]);
    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).not.toContain('encrypted_value');
    expect(sql).toContain('ORDER BY version DESC');
    expect(params).toEqual(['EXAMPLE_KEY']);
  });

  test('getKeyVersions returns an empty array for an unknown key', async () => {
    db.execute.mockResolvedValueOnce([[]]);
    await expect(getKeyVersions('DOES_NOT_EXIST')).resolves.toEqual([]);
  });
});

// ── Phase 4.4: expiresAt ─────────────────────────────────────────────────
describe('setKey — expiresAt (Phase 4.4)', () => {
  const { MAX_EXPIRES_AT_EPOCH } = require('../../services/dynamicKeyService');
  const insertCall = (conn) => conn.execute.mock.calls[2];

  test('a Date is stored as epoch seconds through FROM_UNIXTIME(?)', async () => {
    const conn = connWithLatestVersion(null);
    const instant = new Date(Date.UTC(2030, 0, 1, 0, 0, 0));
    await setKey(KEY_NAME, 'DUMMY_VALUE_001', 'admin_demo', instant);
    const [sql, params] = insertCall(conn);
    expect(sql).toContain('FROM_UNIXTIME(?)');
    expect(params[4]).toBe(Date.UTC(2030, 0, 1) / 1000);
  });

  test('null / omitted expiresAt binds NULL (FROM_UNIXTIME(NULL) is NULL → never expires)', async () => {
    const conn = connWithLatestVersion(null);
    await setKey(KEY_NAME, 'DUMMY_VALUE_001');
    expect(insertCall(conn)[1][4]).toBeNull();
  });

  test.each([
    ['a string', '2030-01-01T00:00:00Z'],
    ['an invalid Date', new Date('not a date')],
    ['a number', 1893456000],
  ])('rejects %s before opening a connection', async (_label, bad) => {
    await expect(setKey(KEY_NAME, 'DUMMY_VALUE_001', 'admin_demo', bad)).rejects.toBeInstanceOf(DynamicKeyServiceError);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('rejects instants FROM_UNIXTIME cannot represent (pre-1970, post-2038)', async () => {
    await expect(setKey(KEY_NAME, 'X', 'a', new Date(Date.UTC(1969, 11, 31)))).rejects.toThrow(/supported range/);
    await expect(setKey(KEY_NAME, 'X', 'a', new Date((MAX_EXPIRES_AT_EPOCH + 1) * 1000))).rejects.toThrow(/supported range/);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('getKey()\'s expiry check is unchanged (compares against NOW())', async () => {
    db.execute.mockResolvedValueOnce([[]]);
    await expect(getKey(KEY_NAME)).rejects.toBeInstanceOf(KeyNotFoundError);
    expect(db.execute.mock.calls[0][0]).toContain('expires_at IS NULL OR expires_at > NOW()');
  });
});
