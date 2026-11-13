-- Home Collection service charge, decided when a technician accepts.
--
-- The customer no longer pays a service charge at booking ("collected on the
-- spot"). When a technician accepts, the charge is worked out from the
-- customer's booking location to the branch being offered, up and down
-- (one-way km × 2), and the ip_products row whose from_km–to_km range covers
-- that km is used. It is added to the bill when the technician arrives, and
-- the technician collects it on the spot.
--
--   service_charge_km      up-and-down km used to pick the product.
--   service_charge_status  NULL         booking made before this change — its
--                                       booking-time fare stays as it is
--                          'pending'    booked, no technician yet
--                          'calculated' technician accepted: product and fare
--                                       saved (home_collection_fare,
--                                       service_charge_product_id), not yet in
--                                       the total
--                          'applied'    technician arrived: fare added to
--                                       total_amount / amount_due
--                          'no_product' no product covers the km — no charge;
--                                       the technician adds a charge package
--
-- Only the visit's main booking carries the service charge (as before).
-- Run BEFORE restarting the server. Safe to run more than once.
ALTER TABLE ip_bookings
  ADD COLUMN IF NOT EXISTS service_charge_km     DECIMAL(8,2) NULL DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS service_charge_status VARCHAR(20)  NULL DEFAULT NULL;
