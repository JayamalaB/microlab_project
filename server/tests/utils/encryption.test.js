// Tests server/utils/encryption.js — AES-256-GCM encrypt/decrypt utility.
// Phase 3.1 of Dynamic Key Management: an isolated crypto utility, no DB,
// no process.env coupling inside the utility itself (the test master key
// below is a stand-in for what a future caller would read from
// process.env.DYNAMIC_KEY_MASTER_KEY).
const { encrypt, decrypt, EncryptionError } = require('../../utils/encryption');

// Dummy 32-byte base64 keys, test-only — never a real production master key.
const MASTER_KEY_A = process.env.DYNAMIC_KEY_MASTER_KEY; // set in tests/setupEnv.js
const MASTER_KEY_B = 'I6B7M9YTP8Ei0wAvZlusTZGkG9fz+j8LDnPnhtM+72o=';

describe('Test 1 — basic encryption', () => {
  test('ciphertext is not equal to plaintext', () => {
    const ciphertext = encrypt('OLD_KEY_123', MASTER_KEY_A);
    expect(ciphertext).not.toBe('OLD_KEY_123');
    expect(ciphertext).toEqual(expect.any(String));
  });
});

describe('Test 2 — basic decryption', () => {
  test('original === decrypted', () => {
    const ciphertext = encrypt('OLD_KEY_123', MASTER_KEY_A);
    const decrypted  = decrypt(ciphertext, MASTER_KEY_A);
    expect(decrypted).toBe('OLD_KEY_123');
  });
});

describe('Test 3 — different IVs', () => {
  test('encrypting the same plaintext twice produces different ciphertexts', () => {
    const first  = encrypt('OLD_KEY_123', MASTER_KEY_A);
    const second = encrypt('OLD_KEY_123', MASTER_KEY_A);
    expect(first).not.toBe(second);

    // Confirms it's specifically the IV segment that differs (format is
    // "iv:authTag:ciphertext") — not just incidental ciphertext variance.
    const [ivA] = first.split(':');
    const [ivB] = second.split(':');
    expect(ivA).not.toBe(ivB);

    // Both still decrypt to the same original value regardless.
    expect(decrypt(first, MASTER_KEY_A)).toBe('OLD_KEY_123');
    expect(decrypt(second, MASTER_KEY_A)).toBe('OLD_KEY_123');
  });
});

describe('Test 4 — wrong master key', () => {
  test('decryption fails when the wrong key is supplied', () => {
    const ciphertext = encrypt('OLD_KEY_123', MASTER_KEY_A);
    expect(() => decrypt(ciphertext, MASTER_KEY_B)).toThrow(EncryptionError);
    expect(() => decrypt(ciphertext, MASTER_KEY_B)).toThrow('Decryption failed');
  });
});

describe('Test 5 — tampered ciphertext', () => {
  test('modifying one byte of the ciphertext fails decryption', () => {
    const ciphertext = encrypt('OLD_KEY_123', MASTER_KEY_A);
    const [iv, authTag, ct] = ciphertext.split(':');

    // Flip one byte of the ciphertext segment.
    const ctBuf = Buffer.from(ct, 'base64');
    ctBuf[0] = ctBuf[0] ^ 0xff;
    const tampered = `${iv}:${authTag}:${ctBuf.toString('base64')}`;

    expect(() => decrypt(tampered, MASTER_KEY_A)).toThrow(EncryptionError);
  });
});

describe('Test 6 — tampered authentication tag', () => {
  test('modifying the auth tag fails decryption', () => {
    const ciphertext = encrypt('OLD_KEY_123', MASTER_KEY_A);
    const [iv, authTag, ct] = ciphertext.split(':');

    const tagBuf = Buffer.from(authTag, 'base64');
    tagBuf[0] = tagBuf[0] ^ 0xff;
    const tampered = `${iv}:${tagBuf.toString('base64')}:${ct}`;

    expect(() => decrypt(tampered, MASTER_KEY_A)).toThrow(EncryptionError);
  });
});

describe('Test 7 — invalid IV', () => {
  test('a structurally wrong-length IV fails decryption without touching the cipher', () => {
    const ciphertext = encrypt('OLD_KEY_123', MASTER_KEY_A);
    const [, authTag, ct] = ciphertext.split(':');

    const badIv = Buffer.from([1, 2, 3]).toString('base64'); // wrong length, not 12 bytes
    const tampered = `${badIv}:${authTag}:${ct}`;

    expect(() => decrypt(tampered, MASTER_KEY_A)).toThrow(EncryptionError);
  });

  test('a garbled (non-base64-shaped) payload fails safely, not a crash', () => {
    expect(() => decrypt('not-a-valid-payload', MASTER_KEY_A)).toThrow(EncryptionError);
    expect(() => decrypt('a:b', MASTER_KEY_A)).toThrow(EncryptionError); // wrong segment count
  });
});

describe('Test 8 — empty plaintext', () => {
  // Decision: reject empty plaintext outright, matching this project's
  // existing convention of validating required input at the boundary
  // (e.g. authController's mobile-number regex check) rather than silently
  // encrypting an empty string.
  test('encrypt() rejects an empty string with a controlled validation error', () => {
    expect(() => encrypt('', MASTER_KEY_A)).toThrow(EncryptionError);
    expect(() => encrypt('', MASTER_KEY_A)).toThrow('plaintext must be a non-empty string');
  });

  test('encrypt() rejects non-string plaintext the same way', () => {
    expect(() => encrypt(null, MASTER_KEY_A)).toThrow(EncryptionError);
    expect(() => encrypt(undefined, MASTER_KEY_A)).toThrow(EncryptionError);
    expect(() => encrypt(12345, MASTER_KEY_A)).toThrow(EncryptionError);
  });
});

describe('Test 9 — invalid master key', () => {
  test('a key of the wrong length produces a controlled validation error, not a crash', () => {
    const tooShort = Buffer.from('short').toString('base64');
    expect(() => encrypt('OLD_KEY_123', tooShort)).toThrow(EncryptionError);
    expect(() => encrypt('OLD_KEY_123', tooShort)).toThrow(/32 bytes/);
  });

  test('a non-base64-shaped key produces a controlled validation error', () => {
    expect(() => encrypt('OLD_KEY_123', 'not valid base64 at all!!')).toThrow(EncryptionError);
  });

  test('an empty or missing master key is rejected, never silently defaulted', () => {
    expect(() => encrypt('OLD_KEY_123', '')).toThrow(EncryptionError);
    expect(() => encrypt('OLD_KEY_123', null)).toThrow(EncryptionError);
    expect(() => encrypt('OLD_KEY_123', undefined)).toThrow(EncryptionError);
  });

  // Explicit "no silent hash/truncate" requirement: a too-long key must
  // also be rejected, not quietly truncated to 32 bytes.
  test('a key longer than 32 bytes is rejected, never silently truncated', () => {
    const tooLong = Buffer.alloc(48, 7).toString('base64');
    expect(() => encrypt('OLD_KEY_123', tooLong)).toThrow(/32 bytes/);
  });
});

describe('Test 10 — unicode', () => {
  test('a unicode value round-trips correctly', () => {
    const value = 'test-value-தமிழ்';
    const ciphertext = encrypt(value, MASTER_KEY_A);
    expect(decrypt(ciphertext, MASTER_KEY_A)).toBe(value);
  });

  test('emoji and mixed-script content also round-trips correctly', () => {
    const value = '🔑 secret-ключ-密钥';
    const ciphertext = encrypt(value, MASTER_KEY_A);
    expect(decrypt(ciphertext, MASTER_KEY_A)).toBe(value);
  });
});

describe('Secret leakage check', () => {
  test('a thrown EncryptionError never contains the plaintext, master key, or ciphertext', () => {
    const plaintext   = 'OLD_KEY_123';
    const ciphertext  = encrypt(plaintext, MASTER_KEY_A);

    let errorMessage = '';
    try {
      decrypt(ciphertext, MASTER_KEY_B); // wrong key — guaranteed to throw
    } catch (e) {
      errorMessage = e.message;
    }

    expect(errorMessage).toBe('Decryption failed'); // generic, not detailed
    expect(errorMessage).not.toContain(plaintext);
    expect(errorMessage).not.toContain(MASTER_KEY_A);
    expect(errorMessage).not.toContain(MASTER_KEY_B);
    expect(errorMessage).not.toContain(ciphertext);
  });

  test('every failure mode produces the exact same generic message — no mode-specific detail leaks', () => {
    const ciphertext = encrypt('OLD_KEY_123', MASTER_KEY_A);
    const [iv, authTag, ct] = ciphertext.split(':');

    const wrongKeyMsg = (() => { try { decrypt(ciphertext, MASTER_KEY_B); } catch (e) { return e.message; } })();
    const badPayloadMsg = (() => { try { decrypt('garbage', MASTER_KEY_A); } catch (e) { return e.message; } })();
    const tamperedTagBuf = Buffer.from(authTag, 'base64'); tamperedTagBuf[0] ^= 0xff;
    const tamperedTagMsg = (() => { try { decrypt(`${iv}:${tamperedTagBuf.toString('base64')}:${ct}`, MASTER_KEY_A); } catch (e) { return e.message; } })();

    expect(wrongKeyMsg).toBe('Decryption failed');
    expect(badPayloadMsg).toBe('Decryption failed');
    expect(tamperedTagMsg).toBe('Decryption failed');
  });

  test('neither function ever calls console.log/console.error with sensitive content', () => {
    const logSpy = jest.spyOn(console, 'log').mockImplementation(() => {});
    const errSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
    try {
      const secret = 'VERY_SENSITIVE_VALUE_7788';
      const ct = encrypt(secret, MASTER_KEY_A);
      decrypt(ct, MASTER_KEY_A);
      try { decrypt(ct, MASTER_KEY_B); } catch (_) {}
      try { encrypt('', MASTER_KEY_A); } catch (_) {}

      expect(logSpy).not.toHaveBeenCalled();
      expect(errSpy).not.toHaveBeenCalled();
    } finally {
      logSpy.mockRestore();
      errSpy.mockRestore();
    }
  });
});
