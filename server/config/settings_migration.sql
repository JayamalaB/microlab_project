-- Insert booking edit rules into the existing ip_settings table (safe — skips if already present)

INSERT INTO ip_settings (setting_key, setting_value)
SELECT 'booking_edit_block_if_paid', 'true'
WHERE NOT EXISTS (SELECT 1 FROM ip_settings WHERE setting_key = 'booking_edit_block_if_paid');

INSERT INTO ip_settings (setting_key, setting_value)
SELECT 'booking_edit_block_collection_statuses', 'en_route,arrived,collection_started,sample_collected,handed_to_lab'
WHERE NOT EXISTS (SELECT 1 FROM ip_settings WHERE setting_key = 'booking_edit_block_collection_statuses');

-- Family booking settings

ALTER TABLE ip_bookings
  ADD COLUMN IF NOT EXISTS visit_group_id VARCHAR(50) NULL DEFAULT NULL
  COMMENT 'Links multiple bookings in the same family/group visit';

INSERT INTO ip_settings (setting_key, setting_value)
SELECT 'family_booking_enabled', 'true'
WHERE NOT EXISTS (SELECT 1 FROM ip_settings WHERE setting_key = 'family_booking_enabled');

INSERT INTO ip_settings (setting_key, setting_value)
SELECT 'family_booking_max_members', '4'
WHERE NOT EXISTS (SELECT 1 FROM ip_settings WHERE setting_key = 'family_booking_max_members');
