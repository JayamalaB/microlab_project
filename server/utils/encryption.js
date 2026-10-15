// encryption.js — AES-256-GCM authenticated encryption, Node's built-in
// `crypto` only (no external dependency, no custom cryptographic primitive).
//
// Phase 3.1 of Dynamic Key Management: this is an isolated, reusable utility
// — it does not read process.env itself and does not touch any database.
// The future Dynamic Key Service (Phase 3.2+) is the caller that reads
// process.env.DYNAMIC_KEY_MASTER_KEY and passes it in here.
//
// ── Master key format ───────────────────────────────────────────────────
// Base64-encoded, MUST decode to exactly 32 bytes (256 bits) — e.g.
//   DYNAMIC_KEY_MASTER_KEY=<32-byte-base64-key>
// An incorrectly-sized key is a hard validation error. It is never silently
// hashed, padded, or truncated to "make it fit" — a wrong-length key is a
// configuration mistake that must surface immediately, not be masked.
//
// ── IV ───────────────────────────────────────────────────────────────────
// 12 random bytes (96 bits — the standard/recommended size for GCM),
// generated fresh via crypto.randomBytes() on every single encrypt() call.
// Never reused across calls, never derived from anything predictable.
//
// ── Authentication tag ──────────────────────────────────────────────────
// GCM's standard 16-byte (128-bit) tag, produced by cipher.getAuthTag() and
// verified by decipher.setAuthTag() — this is what makes the encryption
// "authenticated": any single-byte change to the ciphertext, IV, or tag
// makes decryption fail outright rather than silently returning corrupted
// or partial plaintext.
//
// ── Encrypted payload format ────────────────────────────────────────────
// A single self-contained string: "<ivB64>:<authTagB64>:<ciphertextB64>".
// decrypt() needs nothing beyond this string plus the master key — chosen
// over a JSON envelope so it stays a simple value a single DB column can
// hold later (Phase 3.2), without over-engineering beyond what Phase 3.1
// actually needs today.
'use strict';
const crypto = require('crypto');

const ALGORITHM      = 'aes-256-gcm';
const KEY_BYTES       = 32; // 256-bit key
const IV_BYTES        = 12; // 96-bit IV — standard for GCM
const AUTH_TAG_BYTES  = 16; // 128-bit tag — Node's GCM default

class EncryptionError extends Error {
  constructor(message) {
    super(message);
    this.name = 'EncryptionError';
  }
}

// Validation only — never transforms an invalid key into a usable one.
function _decodeMasterKey(masterKey) {
  if (typeof masterKey !== 'string' || masterKey.length === 0) {
    throw new EncryptionError('Master key must be a non-empty base64 string');
  }
  const keyBuffer = Buffer.from(masterKey, 'base64');
  if (keyBuffer.length !== KEY_BYTES) {
    throw new EncryptionError(
      `Master key must decode to exactly ${KEY_BYTES} bytes (256 bits) — got ${keyBuffer.length}`
    );
  }
  return keyBuffer;
}

// encrypt(plaintext, masterKey) → "<ivB64>:<authTagB64>:<ciphertextB64>"
function encrypt(plaintext, masterKey) {
  if (typeof plaintext !== 'string' || plaintext.length === 0) {
    throw new EncryptionError('plaintext must be a non-empty string');
  }
  const key = _decodeMasterKey(masterKey);
  const iv  = crypto.randomBytes(IV_BYTES);

  const cipher    = crypto.createCipheriv(ALGORITHM, key, iv);
  const encrypted = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  const authTag   = cipher.getAuthTag();

  return `${iv.toString('base64')}:${authTag.toString('base64')}:${encrypted.toString('base64')}`;
}

// decrypt(encryptedData, masterKey) → original plaintext string.
// Every failure path — tampered ciphertext, tampered/wrong-length IV,
// tampered/wrong-length auth tag, wrong master key, malformed payload —
// collapses to the same generic EncryptionError('Decryption failed').
// Deliberately uninformative: it never reveals which part was wrong, never
// echoes the master key, the ciphertext, or any underlying Node crypto
// error detail (which can otherwise leak buffer-shaped information).
function decrypt(encryptedData, masterKey) {
  const key = _decodeMasterKey(masterKey);

  if (typeof encryptedData !== 'string') {
    throw new EncryptionError('Decryption failed');
  }
  const parts = encryptedData.split(':');
  if (parts.length !== 3) {
    throw new EncryptionError('Decryption failed');
  }
  const [ivB64, authTagB64, ciphertextB64] = parts;

  let iv, authTag, ciphertext;
  try {
    iv         = Buffer.from(ivB64, 'base64');
    authTag    = Buffer.from(authTagB64, 'base64');
    ciphertext = Buffer.from(ciphertextB64, 'base64');
  } catch {
    throw new EncryptionError('Decryption failed');
  }

  // Fail fast on a structurally wrong IV/tag before ever touching the
  // decipher — covers Test 7 (invalid IV) without relying on GCM itself to
  // catch a length mismatch.
  if (iv.length !== IV_BYTES || authTag.length !== AUTH_TAG_BYTES) {
    throw new EncryptionError('Decryption failed');
  }

  try {
    const decipher = crypto.createDecipheriv(ALGORITHM, key, iv);
    decipher.setAuthTag(authTag);
    // GCM verifies the auth tag inside final() — a tampered ciphertext,
    // tampered tag, or wrong key all throw here, never returning partial
    // or corrupted plaintext.
    const decrypted = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
    return decrypted.toString('utf8');
  } catch {
    throw new EncryptionError('Decryption failed');
  }
}

module.exports = { encrypt, decrypt, EncryptionError };
