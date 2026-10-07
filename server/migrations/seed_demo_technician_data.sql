-- Seed data for the demo technician (9111111111) — Play Store review.
-- Run AFTER add_demo_technician.sql.
-- Creates 3 patients, 5 past bookings (history tab) + 2 today (home tab).

-- ── 0. Resolve demo technician's IDs ────────────────────────────────────────
SET @tech_user_id = (
  SELECT user_id FROM ip_users
  WHERE user_mobile_no = '9111111111' AND user_active = 1 LIMIT 1
);
SET @tech_id = (
  SELECT technician_id FROM ip_technicians WHERE user_id = @tech_user_id LIMIT 1
);
SET @branch_id = (
  SELECT branch_id FROM ip_technicians WHERE technician_id = @tech_id LIMIT 1
);
-- Create a dedicated client record for the demo seed patients.
INSERT INTO ip_clients (client_name, client_mobile_no, client_reg_source, client_date_created, client_date_modified)
VALUES ('Demo Seed Client', '9800000000', 'mobile_app', NOW(), NOW());
SET @demo_client_id = LAST_INSERT_ID();

-- ── 1. Demo patients ─────────────────────────────────────────────────────────
INSERT INTO ip_patients (client_id, patient_name, patient_mobile, patient_gender, patient_age, patient_relation, created_by)
VALUES
  (@demo_client_id, 'Ravi Kumar',   '9800000001', 'Male',   34, 'Self',   'demo_seed'),
  (@demo_client_id, 'Priya Nair',   '9800000002', 'Female', 28, 'Self',   'demo_seed'),
  (@demo_client_id, 'Anbu Selvan',  '9800000003', 'Male',   52, 'Self',   'demo_seed');

SET @p1 = (SELECT patient_id FROM ip_patients WHERE patient_mobile = '9800000001' LIMIT 1);
SET @p2 = (SELECT patient_id FROM ip_patients WHERE patient_mobile = '9800000002' LIMIT 1);
SET @p3 = (SELECT patient_id FROM ip_patients WHERE patient_mobile = '9800000003' LIMIT 1);

-- ── 2. Past bookings (history tab — completed) ───────────────────────────────
INSERT INTO ip_bookings
  (booking_ref, client_id, branch_id, booking_date, booking_type, status,
   total_amount, discount_amount, amount_paid, amount_due,
   source_channel, collection_address, postal_code, city,
   patient_id, product_id, payment_status,
   start_datetime, end_datetime, created_at)
VALUES
  ('BK-DEMO-001', @demo_client_id, @branch_id, DATE_SUB(CURDATE(),INTERVAL 5 DAY), 'home_collection', 'completed',
   799, 0, 799, 0, 'mobile_app', '12, Anna Nagar, Chennai', '600040', 'Chennai',
   @p1, 0, 'paid',
   DATE_SUB(NOW(), INTERVAL 5 DAY), DATE_ADD(DATE_SUB(NOW(), INTERVAL 5 DAY), INTERVAL 1 HOUR), DATE_SUB(NOW(), INTERVAL 5 DAY)),

  ('BK-DEMO-002', @demo_client_id, @branch_id, DATE_SUB(CURDATE(),INTERVAL 4 DAY), 'home_collection', 'completed',
   450, 0, 450, 0, 'mobile_app', '5, T Nagar, Chennai', '600017', 'Chennai',
   @p2, 0, 'paid',
   DATE_SUB(NOW(), INTERVAL 4 DAY), DATE_ADD(DATE_SUB(NOW(), INTERVAL 4 DAY), INTERVAL 1 HOUR), DATE_SUB(NOW(), INTERVAL 4 DAY)),

  ('BK-DEMO-003', @demo_client_id, @branch_id, DATE_SUB(CURDATE(),INTERVAL 3 DAY), 'home_collection', 'completed',
   1200, 0, 1200, 0, 'mobile_app', '8, Velachery Main Rd, Chennai', '600042', 'Chennai',
   @p3, 0, 'paid',
   DATE_SUB(NOW(), INTERVAL 3 DAY), DATE_ADD(DATE_SUB(NOW(), INTERVAL 3 DAY), INTERVAL 1 HOUR), DATE_SUB(NOW(), INTERVAL 3 DAY)),

  ('BK-DEMO-004', @demo_client_id, @branch_id, DATE_SUB(CURDATE(),INTERVAL 2 DAY), 'home_collection', 'completed',
   350, 0, 0, 350, 'mobile_app', '3, Adyar, Chennai', '600020', 'Chennai',
   @p1, 0, 'unpaid',
   DATE_SUB(NOW(), INTERVAL 2 DAY), DATE_ADD(DATE_SUB(NOW(), INTERVAL 2 DAY), INTERVAL 1 HOUR), DATE_SUB(NOW(), INTERVAL 2 DAY)),

  ('BK-DEMO-005', @demo_client_id, @branch_id, DATE_SUB(CURDATE(),INTERVAL 1 DAY), 'home_collection', 'completed',
   600, 0, 600, 0, 'mobile_app', '22, Porur, Chennai', '600116', 'Chennai',
   @p2, 0, 'paid',
   DATE_SUB(NOW(), INTERVAL 1 DAY), DATE_ADD(DATE_SUB(NOW(), INTERVAL 1 DAY), INTERVAL 1 HOUR), DATE_SUB(NOW(), INTERVAL 1 DAY));

-- ── 3. Today's bookings (home tab) ───────────────────────────────────────────
INSERT INTO ip_bookings
  (booking_ref, client_id, branch_id, booking_date, booking_type, status,
   total_amount, discount_amount, amount_paid, amount_due,
   source_channel, collection_address, postal_code, city,
   patient_id, product_id, payment_status,
   start_datetime, end_datetime, created_at)
VALUES
  ('BK-DEMO-006', @demo_client_id, @branch_id, CURDATE(), 'home_collection', 'pending',
   799, 0, 799, 0, 'mobile_app', '15, Nungambakkam, Chennai', '600034', 'Chennai',
   @p3, 0, 'paid',
   NOW(), DATE_ADD(NOW(), INTERVAL 1 HOUR), NOW()),

  ('BK-DEMO-007', @demo_client_id, @branch_id, CURDATE(), 'home_collection', 'pending',
   500, 0, 0, 500, 'mobile_app', '7, Tambaram, Chennai', '600045', 'Chennai',
   @p1, 0, 'unpaid',
   NOW(), DATE_ADD(NOW(), INTERVAL 1 HOUR), NOW());

-- ── 4. ip_technician_collection rows ─────────────────────────────────────────
-- History: 5 completed jobs
INSERT INTO ip_technician_collection
  (booking_id, technician_id, technician_name, collection_status,
   collection_date, collection_address, patient_id, assigned_at, collected_at, completed_at, created_at, updated_at)
SELECT b.booking_id, @tech_id, 'Demo Technician', 'completed',
       b.booking_date, b.collection_address, b.patient_id,
       b.created_at,
       DATE_ADD(b.created_at, INTERVAL 1 HOUR),
       DATE_ADD(b.created_at, INTERVAL 2 HOUR),
       b.created_at, b.created_at
FROM ip_bookings b
WHERE b.booking_ref IN ('BK-DEMO-001','BK-DEMO-002','BK-DEMO-003','BK-DEMO-004','BK-DEMO-005');

-- Today: 1 assigned (pending), 1 en_route
INSERT INTO ip_technician_collection
  (booking_id, technician_id, technician_name, collection_status,
   collection_date, collection_address, patient_id, assigned_at, created_at, updated_at)
SELECT b.booking_id, @tech_id, 'Demo Technician', 'assigned',
       b.booking_date, b.collection_address, b.patient_id,
       NOW(), NOW(), NOW()
FROM ip_bookings b
WHERE b.booking_ref = 'BK-DEMO-006';

INSERT INTO ip_technician_collection
  (booking_id, technician_id, technician_name, collection_status,
   collection_date, collection_address, patient_id, assigned_at, created_at, updated_at)
SELECT b.booking_id, @tech_id, 'Demo Technician', 'en_route',
       b.booking_date, b.collection_address, b.patient_id,
       NOW(), NOW(), NOW()
FROM ip_bookings b
WHERE b.booking_ref = 'BK-DEMO-007';
