-- Add doctor_name column to ip_bookings for per-booking doctor referral tracking
ALTER TABLE ip_bookings
  ADD COLUMN doctor_name VARCHAR(150) NULL DEFAULT NULL AFTER notes;
