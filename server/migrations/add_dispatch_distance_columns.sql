-- Branch distances for home-collection dispatch. Every distance is
-- CUSTOMER LOCATION → BRANCH LOCATION (straight line, one way), the same
-- measure as the fare's home_collection_distance_km — never technician GPS
-- and never branch-to-branch.
--
--   original_branch_id      the branch the booking started at. Written once,
--                           when dispatch first runs, and never overwritten
--                           (branch_id itself is changed to the serving
--                           branch when a technician accepts).
--   original_distance_km    customer → original branch.
--   served_branch_id        the branch whose technician accepted (dispatch
--                           fallback branch, or the technician's own branch
--                           for an admin assignment). Rewritten on every
--                           accept, so a reassignment shows the latest.
--   served_distance_km      customer → serving branch.
--   distance_difference_km  served − original, signed (negative when a nearer
--                           branch served).
--   extra_distance_km       the same, never below 0.
--
-- All NULL for bookings dispatched before this column existed. Nothing reads
-- them for the fare or payments — the fare stays as calculated at booking.
-- Family visits: every booking in the visit gets the same values.
--
-- Run BEFORE restarting the server. Without it dispatch still works; only
-- these values are not saved (logged as skipped). Safe to run more than once.
ALTER TABLE ip_bookings
  ADD COLUMN IF NOT EXISTS original_branch_id     INT(11)      NULL DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS original_distance_km   DECIMAL(8,2) NULL DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS served_branch_id       INT(11)      NULL DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS served_distance_km     DECIMAL(8,2) NULL DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS distance_difference_km DECIMAL(8,2) NULL DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS extra_distance_km      DECIMAL(8,2) NULL DEFAULT NULL;
