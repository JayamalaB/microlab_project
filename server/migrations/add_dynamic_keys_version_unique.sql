-- Phase 4.3 — enforce one row per (key_name, version) in ip_dynamic_keys.
--
-- dynamicKeyService.setKey() computes the next version under a
-- SELECT ... FOR UPDATE lock, but the existing (key_name, version) index is
-- not unique, so nothing at the database level prevented two rows with the
-- same version. This replaces that index with a UNIQUE one in a single
-- ALTER, so the table is never without an index on (key_name, version) —
-- the FOR UPDATE lookup in setKey() keeps using it.
--
-- STEP 1 — run this read-only check first. It must return zero rows:
--
--   SELECT key_name, version, COUNT(*) AS copies
--   FROM ip_dynamic_keys
--   GROUP BY key_name, version
--   HAVING COUNT(*) > 1;
--
-- If it returns any rows, STOP and report them — do not delete or edit data
-- to make this migration pass. (If you run step 2 anyway, MariaDB refuses
-- to add the unique key and the ALTER fails without changing any rows.)
--
-- STEP 2 — apply:
ALTER TABLE ip_dynamic_keys
  ADD UNIQUE KEY uq_ip_dynamic_keys_key_name_version (key_name, version),
  DROP INDEX idx_ip_dynamic_keys_key_name_version;
