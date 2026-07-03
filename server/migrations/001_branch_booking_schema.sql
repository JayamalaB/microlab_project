-- ═══════════════════════════════════════════════════════════════
--  Migration 001 — Branch service areas + booking branch columns
--  Database : microlab_home
--  Run once via phpMyAdmin → SQL tab
-- ═══════════════════════════════════════════════════════════════


-- ── 1. branch_service_areas ─────────────────────────────────────
--  Maps each branch to the pincodes and place names it serves.
--  One row per pincode (or place) per branch.
--  Patient lookup: SELECT branch_id FROM branch_service_areas
--                  WHERE pincode = ? OR place_name = ?
-- ────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS branch_service_areas (
  id          INT(10) UNSIGNED NOT NULL AUTO_INCREMENT,
  branch_id   INT(10) UNSIGNED NOT NULL,
  pincode     VARCHAR(10)      NOT NULL,
  place_name  VARCHAR(150)         NULL DEFAULT NULL,
  created_at  DATETIME             NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME             NULL DEFAULT CURRENT_TIMESTAMP
                                        ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (id),

  -- fast lookup by pincode or place
  INDEX idx_bsa_pincode   (pincode),
  INDEX idx_bsa_place     (place_name),
  INDEX idx_bsa_branch    (branch_id),

  CONSTRAINT fk_bsa_branch
    FOREIGN KEY (branch_id) REFERENCES branches (branch_id)
    ON DELETE CASCADE ON UPDATE CASCADE

) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_general_ci;


-- ── 2. booking — new columns ─────────────────────────────────────
--  All nullable so every existing row and existing insert query
--  continues to work without any change.
-- ────────────────────────────────────────────────────────────────

ALTER TABLE booking

  -- which branch owns this booking (set at creation time)
  ADD COLUMN branch_id            INT(10) UNSIGNED NULL DEFAULT NULL
    AFTER patient_id_ref,

  -- the date the patient wants sample collected
  ADD COLUMN collection_date      DATE             NULL DEFAULT NULL
    AFTER booking_type,

  -- patient GPS at booking time (used by dispatch to rank technicians)
  ADD COLUMN collection_latitude  DECIMAL(10, 7)   NULL DEFAULT NULL
    AFTER notes_remarks,

  ADD COLUMN collection_longitude DECIMAL(10, 7)   NULL DEFAULT NULL
    AFTER collection_latitude,

  -- index for branch dashboard query (bookings per branch per date)
  ADD INDEX idx_bk_branch          (branch_id),
  ADD INDEX idx_bk_collection_date (collection_date),

  ADD CONSTRAINT fk_bk_branch
    FOREIGN KEY (branch_id) REFERENCES branches (branch_id)
    ON DELETE SET NULL ON UPDATE CASCADE;
