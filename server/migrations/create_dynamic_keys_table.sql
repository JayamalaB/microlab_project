-- Phase 3.2 of Dynamic Key Management — production storage for encrypted,
-- versioned, admin-rotatable application keys. No real secret is seeded or
-- touched here; this is schema only. See server/utils/encryption.js (Phase
-- 3.1) for the encryption scheme this table is built to hold.
--
-- Deliberately separate from:
--   - ip_key_rotations  (the pre-existing Jayamala/CLIENT_SERVER_SECRET
--     rotation table — single-purpose, external-party workflow, not a
--     general key store; see Phase 2's investigation)
--   - ip_settings       (flat setting_key/setting_value, no versioning, no
--     encryption, used for non-secret operational flags)
--   - ip_test_dynamic_keys (Phase 1's throwaway proof-of-concept table —
--     plaintext dummy values only, not production-shaped)
--
-- encrypted_value stores the WHOLE self-contained payload produced by
-- utils/encryption.js's encrypt(): "<ivBase64>:<authTagBase64>:<ciphertextBase64>".
-- No separate iv/auth_tag columns — the utility was deliberately designed
-- (Phase 3.1) to produce one self-contained string specifically so a single
-- column could hold it; decrypt() needs nothing beyond this string plus the
-- master key (which is never stored here, or anywhere in this database —
-- it lives only in process.env.DYNAMIC_KEY_MASTER_KEY, Phase 3.3+).
--
-- active_key_name + its UNIQUE index is how "only one active version per
-- key_name" is enforced — not an application-level check, a database
-- constraint. MySQL/MariaDB have no native partial/filtered unique index
-- (unlike e.g. Postgres's `CREATE UNIQUE INDEX ... WHERE is_active`), so
-- this is the standard portable workaround: a generated column that is
-- NULL whenever is_active=0, and equals key_name whenever is_active=1.
-- Unique indexes in MySQL/MariaDB never count NULLs against each other, so
-- any number of inactive (NULL) rows coexist freely, but two rows can never
-- both be the active version of the same key_name — this is enforced
-- atomically by the storage engine itself, immune to the same class of
-- race condition this session's dispatch-duplicate fix addressed
-- elsewhere: two concurrent "activate" writes cannot both succeed, even if
-- application code never wraps them in a transaction. Phase 3.3's service
-- should still use a transaction for the insert+deactivate pair (for
-- consistency, not for uniqueness — this index is the real safety net).
CREATE TABLE IF NOT EXISTS ip_dynamic_keys (
  id              BIGINT        AUTO_INCREMENT PRIMARY KEY,
  key_name        VARCHAR(100)  NOT NULL,
  encrypted_value TEXT          NOT NULL,
  is_active       TINYINT(1)    NOT NULL DEFAULT 1,
  version         INT           NOT NULL,
  created_at      DATETIME      NOT NULL DEFAULT NOW(),
  updated_at      DATETIME      NULL,
  created_by      VARCHAR(100)  NULL,
  expires_at      DATETIME      NULL,
  active_key_name VARCHAR(100)  GENERATED ALWAYS AS (IF(is_active = 1, key_name, NULL)) VIRTUAL,

  UNIQUE KEY uq_ip_dynamic_keys_active_key_name (active_key_name),
  INDEX idx_ip_dynamic_keys_key_name_version (key_name, version)
);
