-- A record of every reschedule, so the technician app's History can show a
-- "Rescheduled" tab. ip_bookings.status is NOT changed for this — a
-- rescheduled booking is still pending / scheduled / assigned, which is what
-- dispatch and the scheduler read.
--
--   rescheduled_by = 'customer'   customer moved it (bookingController.
--       rescheduleBooking). If a technician had accepted it, their
--       ip_technician_collection row is deleted and the booking re-dispatched —
--       this row is the only record of which technician had it and when.
--   rescheduled_by = 'technician' the assigned technician moved it to one of
--       their own free times (technicianController.rescheduleAssignedBooking);
--       they keep the job.
--
-- One row per booking per reschedule (each family member's booking gets its
-- own row). Written best effort — a reschedule never fails because of it —
-- and read by technicianController.getHistory.
-- Until it exists both keep working as before, so this can be applied before
-- or after the code is deployed. Run once on the database. Reschedules made
-- before it existed are not recorded anywhere and will not appear.

CREATE TABLE IF NOT EXISTS ip_booking_reschedules (
  reschedule_id   INT          NOT NULL AUTO_INCREMENT,
  booking_id      INT          NOT NULL,
  -- The technician who was assigned at the time (NULL: nobody had accepted yet).
  technician_id   INT          NULL DEFAULT NULL,
  old_date        DATE         NULL DEFAULT NULL,
  old_slot_label  VARCHAR(40)  NULL DEFAULT NULL,
  new_date        DATE         NULL DEFAULT NULL,
  new_slot_label  VARCHAR(40)  NULL DEFAULT NULL,
  rescheduled_by  VARCHAR(20)  NOT NULL DEFAULT 'customer', -- 'customer' | 'technician'
  rescheduled_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (reschedule_id),
  KEY idx_technician (technician_id, rescheduled_at),
  KEY idx_booking (booking_id)
);

-- In case an earlier copy of this table was created without the column.
ALTER TABLE ip_booking_reschedules
  ADD COLUMN IF NOT EXISTS rescheduled_by VARCHAR(20) NOT NULL DEFAULT 'customer' AFTER new_slot_label;
