-- Run once on the production database.
-- Adds bill_id and client_sync_status to ip_bookings.

ALTER TABLE ip_bookings
  ADD COLUMN IF NOT EXISTS bill_id VARCHAR(50) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS client_sync_status ENUM('pending','synced','failed') DEFAULT NULL;
