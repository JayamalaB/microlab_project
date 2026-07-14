-- Add bill_id to ip_bookings (stores client server's bill reference)
ALTER TABLE ip_bookings
  ADD COLUMN IF NOT EXISTS bill_id VARCHAR(100) NULL DEFAULT NULL;

-- Client sync behaviour settings (URLs and keys stay in .env)
INSERT IGNORE INTO ip_settings (setting_key, setting_value) VALUES
  ('client_sync_enabled',      'true'),
  ('client_sync_timeout_ms',   '10000'),
  ('client_sync_retry_enabled','true'),
  ('client_sync_max_retries',  '3');
