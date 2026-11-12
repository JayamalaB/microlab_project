-- Charge packages the technician adds on site (Manage Booking → Add charge
-- package). Replaces the typed amount + reason: the technician picks one or
-- more products from ip_products, each with an optional reason.
--   One row per package added; removing one sets deleted_at.
--   product_name / test_code / price are copied from ip_products when added,
--   so a later price change never alters a visit already billed.
--   ip_bookings.additional_charge_amount stays the booking's total extra
--   charge (these rows + any older typed charge), already inside
--   total_amount, so payments work unchanged.
--   At Handed to Lab each row goes to the ASMX as its own test line in
--   blood_test_list (clientSync.js), like the customer's service charge.
-- Run BEFORE restarting the server — the technician booking screen, the
-- legacy additional-charge endpoint and the visit sync read this table.
-- Safe to run more than once.
CREATE TABLE IF NOT EXISTS ip_booking_additional_charges (
  charge_id      INT(11)        NOT NULL AUTO_INCREMENT,
  booking_id     INT(11)        NOT NULL,
  product_id     INT(11)        NOT NULL,
  product_name   VARCHAR(255)   NOT NULL,
  test_code      VARCHAR(100)   DEFAULT NULL,
  price          DECIMAL(10,2)  NOT NULL DEFAULT 0,
  reason         VARCHAR(255)   DEFAULT NULL,
  technician_id  INT(11)        DEFAULT NULL,
  created_at     DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  deleted_at     DATETIME       DEFAULT NULL,
  PRIMARY KEY (charge_id),
  KEY idx_booking_active (booking_id, deleted_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
