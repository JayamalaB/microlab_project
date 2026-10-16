-- Stores the technician's branches exactly as the ASMX TechnicianLoginCheck
-- returns them, alongside the existing ip_technicians.branch_id (the local
-- branch used by dispatch, which keeps coming from default_branch_id).
--
--   branch_ids        — every ASMX branch code for the technician, e.g. ["03","04","07"]
--   default_branch_id — the ASMX default branch code, e.g. "07"
--
-- Both are written by authController.verifyOtp on each technician login and
-- are informational only: dispatch still reads branch_id alone.
--
-- Apply BEFORE deploying the authController.js that writes these columns.

ALTER TABLE ip_technicians
  ADD COLUMN branch_ids        JSON        NULL AFTER branch_id,
  ADD COLUMN default_branch_id VARCHAR(10) NULL AFTER branch_ids;
