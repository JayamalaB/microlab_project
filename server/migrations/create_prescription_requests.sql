-- Prescription requests: patient uploads prescription without knowing which test to book.
-- Admin/technician reviews and advises. May convert to a booking later.
CREATE TABLE IF NOT EXISTS ip_prescription_requests (
  request_id            INT           AUTO_INCREMENT PRIMARY KEY,
  patient_id            INT           NOT NULL,
  client_id             INT           NOT NULL,
  file_paths            JSON          NOT NULL,         -- array of uploaded file URLs
  notes                 TEXT          NULL,             -- optional note from customer
  status                ENUM('pending','reviewed','converted') NOT NULL DEFAULT 'pending',
  admin_notes           TEXT          NULL,             -- advice/action from admin or technician
  converted_booking_id  INT           NULL,             -- set when request converts to a booking
  reviewed_by           INT           NULL,             -- ip_users.user_id of reviewer
  reviewed_at           DATETIME      NULL,
  created_at            DATETIME      NOT NULL DEFAULT NOW(),

  INDEX idx_patient (patient_id),
  INDEX idx_client  (client_id),
  INDEX idx_status  (status)
);
