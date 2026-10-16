-- ip_branches.branch_code — the branch code used by the external ASMX system
-- (TechnicianLoginCheck branch_id / default_branch_id, e.g. "07"; the
-- visit_completed payload's branch_id). branch_id is unchanged and stays the
-- internal key referenced by every other table.
--
-- Safe to run if the column already exists (IF NOT EXISTS).
-- Apply BEFORE deploying the code that reads it (services/branchCodes.js).

ALTER TABLE ip_branches
  ADD COLUMN IF NOT EXISTS branch_code VARCHAR(20) NULL AFTER branch_id,
  ADD INDEX  IF NOT EXISTS idx_ip_branches_branch_code (branch_code);

-- Then fill branch_code for every branch with the code the ASMX uses, e.g.:
--   UPDATE ip_branches SET branch_code = '07' WHERE branch_id = 7;
--
-- Check: every active branch has a code, and no code is used twice.
--   SELECT branch_id, branch_name, branch_code FROM ip_branches WHERE deleted_at IS NULL ORDER BY branch_id;
--   SELECT branch_code, COUNT(*) c FROM ip_branches WHERE deleted_at IS NULL AND branch_code IS NOT NULL
--   GROUP BY branch_code HAVING c > 1;
