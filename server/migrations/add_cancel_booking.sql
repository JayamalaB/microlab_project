-- Cancellation settings (safe — skips if already present)

INSERT INTO ip_settings (setting_key, setting_value)
SELECT 'cancel_allowed_booking_statuses', 'pending,scheduled,confirmed'
WHERE NOT EXISTS (SELECT 1 FROM ip_settings WHERE setting_key = 'cancel_allowed_booking_statuses');

INSERT INTO ip_settings (setting_key, setting_value)
SELECT 'cancel_allowed_collection_statuses', 'assigned,en_route,arrived'
WHERE NOT EXISTS (SELECT 1 FROM ip_settings WHERE setting_key = 'cancel_allowed_collection_statuses');

INSERT INTO ip_settings (setting_key, setting_value)
SELECT 'cancel_charge_trigger_statuses', 'arrived'
WHERE NOT EXISTS (SELECT 1 FROM ip_settings WHERE setting_key = 'cancel_charge_trigger_statuses');

INSERT INTO ip_settings (setting_key, setting_value)
SELECT 'cancel_service_charge_amount', '50'
WHERE NOT EXISTS (SELECT 1 FROM ip_settings WHERE setting_key = 'cancel_service_charge_amount');

INSERT INTO ip_settings (setting_key, setting_value)
SELECT 'cancel_cutoff_minutes', '0'
WHERE NOT EXISTS (SELECT 1 FROM ip_settings WHERE setting_key = 'cancel_cutoff_minutes');

-- Add cancellation columns to ip_bookings
ALTER TABLE ip_bookings
  ADD COLUMN IF NOT EXISTS cancelled_at       DATETIME                                  NULL,
  ADD COLUMN IF NOT EXISTS cancelled_by       ENUM('customer','admin')                  NULL,
  ADD COLUMN IF NOT EXISTS cancellation_reason VARCHAR(255)                             NULL,
  ADD COLUMN IF NOT EXISTS refund_amount      DECIMAL(10,2)                             NULL,
  ADD COLUMN IF NOT EXISTS refund_status      ENUM('none','pending','processed')        NULL;
