-- Run once on the production database.
-- Adds a soft-delete column to ip_users, matching the same deleted_at
-- pattern already used elsewhere in this schema (ip_bookings,
-- ip_available_slots, etc.) — a user is never physically removed, just
-- stamped with a timestamp. NULL DEFAULT NULL means every existing row is
-- automatically "not deleted", so nothing changes for current accounts
-- until this column is explicitly set.

ALTER TABLE ip_users
  ADD COLUMN IF NOT EXISTS deleted_at datetime NULL DEFAULT NULL;
