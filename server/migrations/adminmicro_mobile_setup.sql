-- Run this on the adminmicro database before deploying the updated server
-- Safe to run multiple times (uses IF NOT EXISTS / ADD COLUMN IF NOT EXISTS style)

-- 0. Add doc_status to ip_booking_documents (prescription workflow)
ALTER TABLE `ip_booking_documents`
  ADD COLUMN IF NOT EXISTS `doc_status` varchar(50) DEFAULT 'pending_review';

-- 1. Add mobile-auth columns to ip_users
ALTER TABLE `ip_users`
  ADD COLUMN IF NOT EXISTS `client_id`    int(11)      DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS `session_id`   varchar(255) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS `is_logged_in` tinyint(1)   DEFAULT 0,
  ADD COLUMN IF NOT EXISTS `access_type`  varchar(50)  DEFAULT 'mobile_app';

-- 2. Create patient_prescription table (mobile prescription uploads)
CREATE TABLE IF NOT EXISTS `patient_prescription` (
  `patient_prescription_id` int(11)      NOT NULL AUTO_INCREMENT,
  `patient_id`              int(11)      DEFAULT NULL,
  `patient_id_ref`          int(11)      DEFAULT NULL,
  `branch_id`               int(11)      DEFAULT NULL,
  `booking_id`              int(11)      DEFAULT NULL,
  `test_mode`               varchar(50)  DEFAULT 'home_collection',
  `booking_mode`            varchar(50)  DEFAULT 'mobile_app',
  `prescription_status`     varchar(50)  DEFAULT 'pending_review',
  `presc_image_url`         text         DEFAULT NULL,
  `presc_image_count`       int(11)      DEFAULT 0,
  `created_at`              datetime     NOT NULL DEFAULT current_timestamp(),
  `updated_at`              datetime     DEFAULT NULL ON UPDATE current_timestamp(),
  PRIMARY KEY (`patient_prescription_id`),
  KEY `idx_booking_id` (`booking_id`),
  KEY `idx_patient_id` (`patient_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
