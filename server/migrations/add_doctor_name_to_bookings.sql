-- ⚠ REPLACED — DO NOT RUN. ip_bookings.doctor_name was replaced by
-- referring_doctor (add_referring_doctor_to_bookings.sql) and is removed by
-- drop_doctor_name_from_bookings.sql. Kept only as a record of history.
--
-- Add doctor_name column to ip_bookings for per-booking doctor referral tracking
ALTER TABLE ip_bookings
  ADD COLUMN doctor_name VARCHAR(150) NULL DEFAULT NULL AFTER notes;
