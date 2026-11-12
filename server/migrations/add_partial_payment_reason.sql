-- Reason the technician enters when a customer pays only part of the amount
-- due (Manage Booking > Collect Payment). Single booking: stored on that
-- booking. Family visit: stored on every booking in the visit, whichever
-- member's payment was partial. A later partial payment replaces it. Sent to
-- the ASMX in payment_details at Handed to Lab.
-- Run BEFORE restarting the server — the visit sync reads this column.
-- Safe to run more than once.
ALTER TABLE ip_bookings
  ADD COLUMN IF NOT EXISTS partial_payment_reason VARCHAR(255) NULL DEFAULT NULL;
