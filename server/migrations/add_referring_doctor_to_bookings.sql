-- ═══════════════════════════════════════════════════════════════════════════
--  ip_bookings.referring_doctor replaces ip_bookings.doctor_name
--
--  The server reads and writes referring_doctor. The apps are unchanged:
--  the API still takes `doctorName` and returns `doctor_name`.
--
--  Safe to run more than once, before or after drop_doctor_name_from_bookings.sql:
--    1. adds the column only when it isn't there yet;
--    2. copies doctor_name into it where referring_doctor is still empty, so
--       bookings made before the switch keep their doctor. Skipped when
--       doctor_name no longer exists.
--
--  Run BEFORE uploading the server code that uses referring_doctor.
--  Then run drop_doctor_name_from_bookings.sql.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE ip_bookings
  ADD COLUMN IF NOT EXISTS referring_doctor VARCHAR(150) NULL DEFAULT NULL;

-- Copy only while doctor_name still exists (a plain UPDATE would fail after the drop).
SET @has_doctor_name := (
  SELECT COUNT(*) FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ip_bookings' AND COLUMN_NAME = 'doctor_name'
);
SET @copy_sql := IF(@has_doctor_name > 0,
  'UPDATE ip_bookings SET referring_doctor = doctor_name
   WHERE referring_doctor IS NULL AND doctor_name IS NOT NULL AND TRIM(doctor_name) <> ''''',
  'SELECT ''doctor_name already removed - nothing to copy'' AS info');
PREPARE copy_stmt FROM @copy_sql;
EXECUTE copy_stmt;
DEALLOCATE PREPARE copy_stmt;
