-- Renumbers EVERY existing booking (every source — mobile app "BK-...",
-- admin portal, and the separately-sourced "MLB..." rows) into one gapless,
-- purely numeric booking_ref sequence starting at 10000001, ordered by
-- booking_id (i.e. creation order), and sets future bookings up to continue
-- that same sequence with no gap and no collision risk.
--
-- ONLY booking_ref changes. booking_id (the real primary key — referenced
-- by ~15+ other tables: items, payments, technician collection, documents,
-- tracking, refunds, etc.) is never read for anything but ORDER BY here,
-- and is never written to. No other column on ip_bookings is touched. No
-- other table is touched.
--
-- Why the old "booking_id + a single fixed offset" approach (this file's
-- previous version) isn't used for the BACKFILL: that only produces a
-- perfectly gapless 10000001, 10000002, 10000003... sequence if booking_id
-- itself already has zero historical gaps (e.g. from a past booking
-- attempt that failed and rolled back — AUTO_INCREMENT never reclaims that
-- value, exactly like it already doesn't for booking_id today). Since that
-- can't be verified without querying the live table, step 1 below assigns
-- a true, gapless rank instead — guaranteed contiguous regardless of any
-- gaps in booking_id.
--
-- Uniqueness/concurrency for FUTURE bookings is still fully guaranteed:
-- bookingController.js (createBooking / createFamilyBooking /
-- createAdminBooking — already deployed, NO code change needed for this)
-- computes booking_ref = booking_id + a fixed offset read from
-- ip_settings. booking_id is MySQL's own AUTO_INCREMENT, so this inherits
-- that exact same atomic, race-proof uniqueness guarantee for free — no
-- new locking, no new counter table, two concurrent bookings can never be
-- assigned the same booking_ref.
--
-- Take a backup of ip_bookings (or at least the booking_ref column) before
-- running this — it rewrites every existing booking's externally-visible
-- reference number, for every source, with no exceptions, per explicit
-- confirmation.
--
-- IMPORTANT — server/config/settings.js caches ip_settings in memory
-- (refreshed every 5 minutes, or on restart). Restart the server right
-- after running this — otherwise any booking created before the cache
-- refreshes would compute with the stale/default offset (0), i.e.
-- booking_ref = booking_id with no offset, until the cache catches up.

-- 1. Assign a gapless sequential number to every existing row, in
-- booking_id order, via a MySQL/MariaDB running session-variable counter —
-- portable across MySQL/MariaDB versions (unlike ROW_NUMBER(), which needs
-- MySQL 8.0+/MariaDB 10.2+). @rn's final value after this statement is the
-- number just assigned to the highest-booking_id row.
SET @rn = 10000000;
UPDATE ip_bookings
SET booking_ref = (@rn := @rn + 1)
ORDER BY booking_id ASC;

-- 2. Persist an offset for FUTURE bookings so they continue immediately
-- after the last number just assigned above — computed from MAX(booking_id)
-- and @rn's final value (NOT from MIN(booking_id)), which is what keeps
-- future rows perfectly aligned even if booking_id has historical gaps:
-- a future booking's booking_id will be MAX(booking_id) + 1 (assuming no
-- gap at that exact point), so its booking_ref = MAX(booking_id) + 1 +
-- offset = @rn + 1 — the very next number after the backfill.
INSERT INTO ip_settings (setting_key, setting_value)
SELECT 'booking_ref_offset', CAST((@rn - MAX(booking_id)) AS CHAR)
FROM ip_bookings
ON DUPLICATE KEY UPDATE setting_value = VALUES(setting_value);

-- 3. Verify, before trusting the result: booking_ref must now be both
-- fully unique AND perfectly contiguous (MAX - MIN + 1 == COUNT).
-- Run this and confirm all three numbers make sense before moving on.
SELECT
  COUNT(*)                          AS total_bookings,
  COUNT(DISTINCT booking_ref)       AS distinct_refs,
  MIN(booking_ref + 0)              AS lowest_ref,
  MAX(booking_ref + 0)              AS highest_ref,
  (MAX(booking_ref + 0) - MIN(booking_ref + 0) + 1) AS expected_count_if_gapless
FROM ip_bookings;
