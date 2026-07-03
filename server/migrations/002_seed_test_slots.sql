-- ═══════════════════════════════════════════════════════════════
--  Migration 002 — Seed test slot data for home collection
--  Database : microlab_home
--  Run once via phpMyAdmin → SQL tab
--
--  What this does:
--    1. Inserts 5 time-slot definitions into the `slot` table
--    2. Generates available_time_slots rows for every active
--       branch × every slot × next 14 days (home_collection only)
--
--  Safe to re-run — uses INSERT IGNORE throughout.
-- ═══════════════════════════════════════════════════════════════


-- ── 1. Slot time definitions ─────────────────────────────────────
--  slot_time  = display label shown to patient ("7:00 AM")
--  start_time = actual TIME used for sorting and slot_time_value
--  end_time   = window closes (not currently enforced, kept for future)
-- ────────────────────────────────────────────────────────────────

INSERT IGNORE INTO slot (slot_time, start_time, end_time) VALUES
  ('7:00 AM',  '07:00:00', '09:00:00'),
  ('9:00 AM',  '09:00:00', '11:00:00'),
  ('11:00 AM', '11:00:00', '13:00:00'),
  ('1:00 PM',  '13:00:00', '15:00:00'),
  ('3:00 PM',  '15:00:00', '17:00:00');


-- ── 2. Available slots for every active branch × next 14 days ───
--  Generates rows using a cross join:
--    active branches × slot definitions × 14-day date series
--
--  Columns:
--    slot_id       — FK to slot table
--    branch_id     — FK to branches table
--    date          — collection date
--    slot_type     — always 'home_collection' here
--    slot_time     — copied from slot.start_time (TIME value)
--    max_users     — 10 patients per slot (adjust as needed)
--    booked_count  — starts at 0
--    is_available  — 1 = open for booking
-- ────────────────────────────────────────────────────────────────

INSERT IGNORE INTO available_time_slots
  (slot_id, branch_id, date, slot_type, slot_time,
   max_users, booked_count, is_available, created_at, updated_at)
SELECT
  s.slot_id,
  b.branch_id,
  dates.d,
  'home_collection',
  s.start_time,
  10,
  0,
  1,
  NOW(),
  NOW()
FROM slot s
CROSS JOIN branches b
CROSS JOIN (
  SELECT CURDATE() + INTERVAL  0 DAY AS d UNION ALL
  SELECT CURDATE() + INTERVAL  1 DAY       UNION ALL
  SELECT CURDATE() + INTERVAL  2 DAY       UNION ALL
  SELECT CURDATE() + INTERVAL  3 DAY       UNION ALL
  SELECT CURDATE() + INTERVAL  4 DAY       UNION ALL
  SELECT CURDATE() + INTERVAL  5 DAY       UNION ALL
  SELECT CURDATE() + INTERVAL  6 DAY       UNION ALL
  SELECT CURDATE() + INTERVAL  7 DAY       UNION ALL
  SELECT CURDATE() + INTERVAL  8 DAY       UNION ALL
  SELECT CURDATE() + INTERVAL  9 DAY       UNION ALL
  SELECT CURDATE() + INTERVAL 10 DAY       UNION ALL
  SELECT CURDATE() + INTERVAL 11 DAY       UNION ALL
  SELECT CURDATE() + INTERVAL 12 DAY       UNION ALL
  SELECT CURDATE() + INTERVAL 13 DAY
) AS dates
WHERE b.deleted_at IS NULL
  AND s.deleted_at IS NULL;


-- ── 3. Quick verification ────────────────────────────────────────
--  Run this SELECT after the inserts to confirm rows were created.
--  Should return one row per branch showing the count of slots.
-- ────────────────────────────────────────────────────────────────

SELECT
  b.name          AS branch_name,
  COUNT(*)        AS slot_rows_created
FROM available_time_slots ats
JOIN branches b ON b.branch_id = ats.branch_id
WHERE ats.slot_type = 'home_collection'
  AND ats.date >= CURDATE()
GROUP BY b.branch_id, b.name
ORDER BY b.branch_id;
