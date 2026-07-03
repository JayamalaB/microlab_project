-- ═══════════════════════════════════════════════════════════════
--  Migration 003 — Appointment scheduling (duration-based slots)
--  Run once via phpMyAdmin → SQL tab
-- ═══════════════════════════════════════════════════════════════

-- Adds appointment duration to each technician slot declaration.
-- NULL = no duration configured (old flow — no interval generation).
-- Values 15 / 30 / 40 trigger auto-generation of ip_avilable_slots rows.

ALTER TABLE ip_technician_slots
  ADD COLUMN IF NOT EXISTS duration_minutes TINYINT UNSIGNED NULL DEFAULT NULL
    COMMENT 'Appointment slot duration in minutes (15/30/40). NULL = old flow.'
  AFTER max_bookings;
