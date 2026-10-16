-- External technician ID from ASMX TechnicianLoginCheck (technician.technician_id,
-- e.g. 262), kept separate from MicroLab's own ip_technicians.technician_id
-- primary key, which is never changed. Same idea as ip_patients.patient_id_ref.
--
-- authController.verifyOtp matches a technician by technician_id_ref first
-- (then by mobile) and stores it on each technician login. clientSync sends it
-- as technician_details.technician_id to the external API.
--
-- UNIQUE: one ASMX technician maps to at most one ip_technicians row
-- (NULLs allowed — local-fallback technicians have no external ID).
--
-- Apply BEFORE deploying the authController.js / clientSync.js that use it.

ALTER TABLE ip_technicians
  ADD COLUMN technician_id_ref VARCHAR(20) NULL AFTER technician_id,
  ADD UNIQUE KEY uq_ip_technicians_technician_id_ref (technician_id_ref);

-- Optional: set it now for the test technician instead of waiting for the
-- next login (check the technician_id first):
--   UPDATE ip_technicians SET technician_id_ref = '262' WHERE technician_id = 76;
