-- ═══════════════════════════════════════════════════════════════════════════
--  check_schema.sql: READ-ONLY. Changes nothing.
--
--  Lists every column / table added by the migrations in this folder and
--  shows whether it exists in the CURRENT database: 'ok' or 'MISSING'.
--  MISSING rows come first; the last column names the migration to run.
--
--  How to use: phpMyAdmin → select the database the server uses
--  (DB_NAME in server/.env) → SQL tab → paste this → Go.
--
--  When you add a migration, add its columns here too.
--
--  If the first result below says 'information_schema' or another wrong name,
--  STOP: click the MicroLab database in phpMyAdmin's left panel first (or add
--  `USE <db_name>;` as the first line). Otherwise every row shows MISSING.
-- ═══════════════════════════════════════════════════════════════════════════

-- Which database is being checked. It must be the one the server uses.
SELECT DATABASE() AS checking_database;

SELECT
  CASE WHEN c.COLUMN_NAME IS NULL THEN 'MISSING' ELSE 'ok' END AS status,
  e.tbl        AS table_name,
  e.col        AS column_name,
  e.migration  AS run_this_migration
FROM (
  -- ── November 2026 ─────────────────────────────────────────────────────────
  SELECT 'ip_technician_slot_branches' AS tbl, 'tech_slot_id' AS col, 'add_technician_slot_branches.sql' AS migration
  UNION ALL SELECT 'ip_technician_slot_branches',   'branch_id',              'add_technician_slot_branches.sql'
  UNION ALL SELECT 'ip_bookings',                   'original_branch_id',     'add_dispatch_distance_columns.sql'
  UNION ALL SELECT 'ip_bookings',                   'original_distance_km',   'add_dispatch_distance_columns.sql'
  UNION ALL SELECT 'ip_bookings',                   'served_branch_id',       'add_dispatch_distance_columns.sql'
  UNION ALL SELECT 'ip_bookings',                   'served_distance_km',     'add_dispatch_distance_columns.sql'
  UNION ALL SELECT 'ip_bookings',                   'distance_difference_km', 'add_dispatch_distance_columns.sql'
  UNION ALL SELECT 'ip_bookings',                   'extra_distance_km',      'add_dispatch_distance_columns.sql'
  UNION ALL SELECT 'ip_bookings',                   'service_charge_km',      'add_service_charge_on_accept.sql'
  UNION ALL SELECT 'ip_bookings',                   'service_charge_status',  'add_service_charge_on_accept.sql'
  UNION ALL SELECT 'ip_booking_additional_charges', 'charge_id',              'add_booking_additional_charges.sql'
  UNION ALL SELECT 'ip_bookings',                   'service_charge_product_id', 'add_service_charge_product_id_to_bookings.sql'
  UNION ALL SELECT 'ip_bookings',                   'referring_doctor',       'add_referring_doctor_to_bookings.sql'
  UNION ALL SELECT 'ip_bookings',                   'partial_payment_reason', 'add_partial_payment_reason.sql'
  -- ── October 2026 ──────────────────────────────────────────────────────────
  UNION ALL SELECT 'ip_technician_collection', 'reminder_sent_at',     'add_technician_alert_columns.sql'
  UNION ALL SELECT 'ip_technician_collection', 'late_alert_1_sent_at', 'add_technician_alert_columns.sql'
  UNION ALL SELECT 'ip_technician_collection', 'late_alert_2_sent_at', 'add_technician_alert_columns.sql'
  UNION ALL SELECT 'ip_bookings',              'additional_charge_amount', 'add_booking_additional_charge.sql'
  UNION ALL SELECT 'ip_bookings',              'additional_charge_reason', 'add_booking_additional_charge.sql'
  UNION ALL SELECT 'ip_branches',              'branch_code',          'add_ip_branches_branch_code.sql'
  UNION ALL SELECT 'ip_technicians',           'branch_ids',           'add_technician_asmx_branches.sql'
  UNION ALL SELECT 'ip_technicians',           'default_branch_id',    'add_technician_asmx_branches.sql'
  UNION ALL SELECT 'ip_technicians',           'technician_id_ref',    'add_technician_id_ref.sql'
  UNION ALL SELECT 'ip_branch_lookup_logs',    'id',                   'create_ip_branch_lookup_logs.sql'
  UNION ALL SELECT 'ip_report_status_log',     'bill_id',              'create_ip_report_status_log.sql'
  UNION ALL SELECT 'ip_asmx_logs',             'request_payload',      'create_ip_asmx_logs.sql'
  UNION ALL SELECT 'ip_dynamic_keys',          'encrypted_value',      'create_dynamic_keys_table.sql'
  UNION ALL SELECT 'ip_dispatch_logs',         'tag',                  'create_log_tables.sql'
  UNION ALL SELECT 'ip_collection_logs',       'event',                'create_log_tables.sql'
  UNION ALL SELECT 'ip_otpinfo_logs',          'event',                'create_log_tables.sql'
  UNION ALL SELECT 'ip_technician_logs',       'event',                'create_log_tables.sql'
  UNION ALL SELECT 'ip_client_sync_logs',      'id',                   'create_log_tables.sql'
  UNION ALL SELECT 'ip_customer_push_logs',    'id',                   'create_log_tables.sql'
  UNION ALL SELECT 'ip_otp_logs',              'id',                   'create_log_tables.sql'
  UNION ALL SELECT 'ip_login_otp_logs',        'id',                   'create_log_tables.sql'
  -- ── September 2026 and earlier ────────────────────────────────────────────
  UNION ALL SELECT 'ip_bookings',              'home_collection_fare',        'add_home_collection_fare.sql'
  UNION ALL SELECT 'ip_bookings',              'home_collection_distance_km', 'add_home_collection_fare.sql'
  UNION ALL SELECT 'ip_bookings',              'km_rate_id',                  'add_home_collection_fare.sql'
  UNION ALL SELECT 'ip_users',                 'deleted_at',                  'add_ip_users_deleted_at.sql'
  UNION ALL SELECT 'ip_bookings',              'technician_cancelled_by',     '006_add_technician_cancel_history.sql'
  UNION ALL SELECT 'ip_bookings',              'technician_cancel_reason',    '006_add_technician_cancel_history.sql'
  UNION ALL SELECT 'ip_bookings',              'technician_cancel_note',      '006_add_technician_cancel_history.sql'
  UNION ALL SELECT 'ip_bookings',              'technician_cancelled_at',     '006_add_technician_cancel_history.sql'
  UNION ALL SELECT 'ip_bookings',              'reschedule_count',            '005_add_reschedule.sql'
  UNION ALL SELECT 'ip_bookings',              'client_sync_status',          'add_client_sync_columns.sql'
  UNION ALL SELECT 'ip_bookings',              'bill_id',                     'add_bill_id_and_sync_settings.sql'
  UNION ALL SELECT 'ip_bookings',              'cancelled_at',                'add_cancel_booking.sql'
  UNION ALL SELECT 'ip_bookings',              'cancelled_by',                'add_cancel_booking.sql'
  UNION ALL SELECT 'ip_bookings',              'cancellation_reason',         'add_cancel_booking.sql'
  UNION ALL SELECT 'ip_bookings',              'refund_amount',               'add_cancel_booking.sql'
  UNION ALL SELECT 'ip_bookings',              'refund_status',               'add_cancel_booking.sql'
  UNION ALL SELECT 'ip_prescription_requests', 'request_id',                  'create_prescription_requests.sql'
  UNION ALL SELECT 'ip_technician_slots',      'duration_minutes',            '003_appointment_scheduling.sql'
) AS e
LEFT JOIN information_schema.COLUMNS c
  ON  c.TABLE_SCHEMA = DATABASE()
  AND c.TABLE_NAME   = e.tbl
  AND c.COLUMN_NAME  = e.col
ORDER BY (c.COLUMN_NAME IS NULL) DESC, e.migration, e.tbl, e.col;

-- Extra check: refund_status must allow 'initiated'.
-- If the result does NOT contain 'initiated', run add_refund_status_initiated.sql.
SELECT COLUMN_TYPE AS refund_status_type
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'ip_bookings' AND COLUMN_NAME = 'refund_status';

-- Extra check: settings rows the code expects (missing rows fall back to defaults,
-- so these are informational only).
SELECT setting_key, setting_value
FROM ip_settings
WHERE setting_key IN ('api_auth_required', 'client_sync_enabled', 'additional_charge_max',
                      'booking_ref_offset', 'family_booking_max_members', 'branch_lookup_days');
