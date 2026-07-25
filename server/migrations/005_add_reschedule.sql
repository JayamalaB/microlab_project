-- Add reschedule_count to ip_bookings
ALTER TABLE ip_bookings ADD COLUMN reschedule_count INT NOT NULL DEFAULT 0;

-- Settings for reschedule rules
INSERT INTO ip_settings (setting_key, setting_value) VALUES
  ('reschedule_enabled_home',               'true'),
  ('reschedule_enabled_lab',                'true'),
  ('reschedule_max_count_home',             '2'),
  ('reschedule_max_count_lab',              '2'),
  ('reschedule_min_notice_hours_home',      '0'),
  ('reschedule_min_notice_hours_lab',       '0'),
  ('reschedule_allowed_collection_statuses','assigned')
ON DUPLICATE KEY UPDATE setting_value = VALUES(setting_value);
