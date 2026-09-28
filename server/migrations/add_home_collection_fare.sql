-- Home Collection fare calculation (Branch → Customer distance-based pricing).
-- Additive only — no existing column renamed, dropped, or repurposed, and
-- ip_km_rates itself is reused as-is rather than duplicated into a new table.

-- ip_km_rates already carries rate_per_km + effective_from/is_active
-- versioning. base_fare/included_distance_km/max_service_distance_km are
-- added alongside it (not a separate table) so a rate revision changes all
-- of these together, under the same effective_from row, instead of the
-- per-km rate and the base fare ever drifting out of sync with each other.
-- All three are nullable: fareCalculator.js treats a NULL base_fare or
-- included_distance_km on the active row as "fare configuration incomplete"
-- and refuses to calculate rather than silently assuming 0 — see that
-- file's header comment. max_service_distance_km NULL means no service-area
-- cap is enforced (opt-in — this system never previously had a service-area
-- rule to reuse, so it isn't invented here; it's left as a configuration
-- decision for whoever maintains this table).
ALTER TABLE ip_km_rates
  ADD COLUMN base_fare DECIMAL(10,2) NULL COMMENT 'Flat fare covering included_distance_km',
  ADD COLUMN included_distance_km DECIMAL(6,2) NULL COMMENT 'Distance (km) covered by base_fare before per-km charging starts',
  ADD COLUMN max_service_distance_km DECIMAL(6,2) NULL COMMENT 'Optional hard cap in km; NULL = no cap enforced';

-- Persists the fare actually calculated and shown to the customer at
-- booking-creation time, keyed to the exact rate row used, so later
-- technician movement (or a future rate change) never changes an
-- already-confirmed booking's fare.
ALTER TABLE ip_bookings
  ADD COLUMN home_collection_fare DECIMAL(10,2) NULL COMMENT 'Branch→Customer distance-based fare, computed once at booking creation',
  ADD COLUMN home_collection_distance_km DECIMAL(6,2) NULL COMMENT 'Branch→Customer distance (km, Haversine) used for the fare above',
  ADD COLUMN km_rate_id INT UNSIGNED NULL COMMENT 'ip_km_rates.rate_id that priced this booking, for audit';
