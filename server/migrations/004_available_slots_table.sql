-- ═══════════════════════════════════════════════════════════════
--  Migration 004 — ip_available_slots (renamed from ip_avilable_slots in DB)
--  Database : adminmicro
--
--  Actual table structure (confirmed via DESCRIBE):
--    available_slot_id  int(11)       PK AUTO_INCREMENT
--    booking_type       varchar(255)  NOT NULL
--    technician_slot_id int(11)       NULL
--    lab_slot_id        int(11)       NULL
--    slot_date          date          NOT NULL
--    slot_time          time          NOT NULL
--    is_available       int(11)       NULL
--    created_at         datetime      NOT NULL
--    updated_at         datetime      NOT NULL
--    deleted_at         datetime      NOT NULL
--
--  No DDL changes required. The 500 error on PUT /api/technicians/:id/slots
--  was caused by a spurious `created_by` column in the INSERT statement —
--  that column never existed in ip_technician_slots.
--  Fixed in technicianController.js saveSlots().
-- ═══════════════════════════════════════════════════════════════

-- Fix column defaults so INSERTs don't need to supply audit timestamps.
-- Safe to run multiple times (MODIFY is idempotent for these types).

ALTER TABLE ip_available_slots
  MODIFY COLUMN created_at datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  MODIFY COLUMN updated_at datetime NULL     DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
  MODIFY COLUMN deleted_at datetime NULL     DEFAULT NULL;
