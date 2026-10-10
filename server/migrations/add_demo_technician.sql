-- Demo technician account for Play Store review.
-- Mobile 9111111111, fixed OTP 1234 (bypass handled in authController).
-- Run once against the production/staging DB.

INSERT INTO ip_users
  (user_name, user_email, user_mobile_no, user_otp, user_otp_expiry,
   user_microlab_type, access_type,
   user_active, user_date_created, user_date_modified, user_password,
   user_type, user_all_clients, role_id)
VALUES
  ('Demo Technician', NULL, '9111111111', NULL, NULL,
   'technician', 'mobile_app',
   1, NOW(), NOW(), '',
   0, 0, 0);

-- Link a technician profile row so verifyOtp can resolve the technician_id.
INSERT INTO ip_technicians
  (user_id, branch_id, technician_code, specialization, tech_photo,
   tech_city, is_available, technician_active)
VALUES
  (LAST_INSERT_ID(), 7, 'DEMO-TECH', 'General', NULL,
   NULL, 1, 1);
