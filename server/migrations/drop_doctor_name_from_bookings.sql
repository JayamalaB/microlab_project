-- ═══════════════════════════════════════════════════════════════════════════
--  Remove ip_bookings.doctor_name (replaced by referring_doctor)
--
--  IRREVERSIBLE: the column and its values are deleted.
--
--  Run in this order:
--    1. add_referring_doctor_to_bookings.sql  (adds referring_doctor, copies the values)
--    2. STEP A below: the check. It must return 0.
--    3. STEP B below: the drop.
--
--  Before STEP B, make sure nothing still reads doctor_name: the admin panel,
--  reports, exports. They must use referring_doctor, or they will break.
--  The server code in this repo no longer uses the column.
--
--  Safe to run again after the drop (DROP COLUMN IF EXISTS).
-- ═══════════════════════════════════════════════════════════════════════════

-- STEP A — doctor names that were NOT copied yet. Must be 0 before STEP B.
-- (Fails with "Unknown column" if doctor_name is already gone; then you're done.)
SELECT COUNT(*) AS not_copied_yet
FROM ip_bookings
WHERE doctor_name IS NOT NULL AND TRIM(doctor_name) <> ''
  AND (referring_doctor IS NULL OR TRIM(referring_doctor) = '');

-- STEP B — drop the old column.
ALTER TABLE ip_bookings
  DROP COLUMN IF EXISTS doctor_name;
