-- TEMPORARY — Phase 1 "Dynamic Key Management" proof of concept only.
-- Not a production secrets table. Proves one thing: the backend can read a
-- changed DB value on the very next request, with no backend restart and
-- no code change — the actual "key" stored here is always a dummy test
-- value (TEST_DYNAMIC_KEY / OLD_KEY_123 / NEW_KEY_456), never a real secret.
--
-- Deliberately separate from ip_key_rotations (the Jayamala/CLIENT_SERVER_SECRET
-- table) and from ip_settings (single-row-per-key, no active/inactive
-- versioning) — neither fits this POC's "multiple rows per key_name, only
-- one active at a time" requirement, so a new table was used rather than
-- repurposing either.
CREATE TABLE IF NOT EXISTS ip_test_dynamic_keys (
  id         INT          AUTO_INCREMENT PRIMARY KEY,
  key_name   VARCHAR(100) NOT NULL,
  key_value  VARCHAR(255) NOT NULL,
  is_active  TINYINT(1)   NOT NULL DEFAULT 1,
  created_at DATETIME     NOT NULL DEFAULT NOW(),
  updated_at DATETIME     NULL,
  INDEX idx_ip_test_dynamic_keys_name_active (key_name, is_active)
);

-- Seed data matching the Phase 1 test plan exactly (dummy values only).
INSERT INTO ip_test_dynamic_keys (key_name, key_value, is_active, created_at)
VALUES ('TEST_DYNAMIC_KEY', 'OLD_KEY_123', 1, NOW());
