-- Tracks which technician cancelled an already-accepted job, and why, so it
-- survives being re-dispatched to (and possibly re-cancelled by) someone else.
-- ip_technician_collection cannot hold this: it's keyed one-row-per-booking
-- and gets deleted/overwritten on re-dispatch, so any "cancelled" state
-- written there is lost the moment a new technician accepts.
ALTER TABLE ip_bookings
  ADD COLUMN technician_cancelled_by  INT NULL,
  ADD COLUMN technician_cancel_reason VARCHAR(30) NULL,
  ADD COLUMN technician_cancel_note   TEXT NULL,
  ADD COLUMN technician_cancelled_at  DATETIME NULL;

CREATE INDEX idx_ip_bookings_tech_cancelled_by ON ip_bookings(technician_cancelled_by);
