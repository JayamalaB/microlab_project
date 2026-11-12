-- Add service_charge_product_id to ip_bookings.
-- For home_collection bookings, stores the ip_products row used to price the
-- service charge (round-trip km range lookup replacing the ip_km_rates formula).
-- NULL for lab_visit bookings and all bookings created before this migration.
ALTER TABLE ip_bookings
  ADD COLUMN service_charge_product_id INT NULL DEFAULT NULL
  AFTER home_collection_distance_km;
