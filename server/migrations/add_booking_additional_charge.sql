-- Technician-entered additional charge (Manage Booking → Payment).
-- One additional charge per booking, entered on site with a reason:
--   additional_charge_amount — rupees, already included in total_amount
--                               (Updated Total = Existing Total + Additional Charge)
--   additional_charge_reason — the technician's reason, sent to the ASMX
--                               with the visit at Handed to Lab
-- Existing bookings get 0 / NULL, so nothing changes for them.
-- Run BEFORE restarting the server — the visit sync and the family list read
-- these columns. Safe to run more than once.
ALTER TABLE ip_bookings
  ADD COLUMN IF NOT EXISTS additional_charge_amount DECIMAL(10,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS additional_charge_reason VARCHAR(255) NULL DEFAULT NULL;

-- Upper limit for one booking's additional charge (rupees).
INSERT INTO ip_settings (setting_key, setting_value)
SELECT 'additional_charge_max', '1000'
WHERE NOT EXISTS (SELECT 1 FROM ip_settings WHERE setting_key = 'additional_charge_max');
