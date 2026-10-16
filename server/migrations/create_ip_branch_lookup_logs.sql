-- One row per customer branch lookup (GET /api/branches/lookup,
-- branchController.lookupBranch): what the customer sent, how the branch was
-- chosen, and which branch (branch_id + branch_code) was returned. Mirrors
-- logs/branch.log, which keeps the full step-by-step detail.
--
-- result:       resolved | no_match | error
-- match_reason: PINCODE_EXACT | GPS_NEAREST | CITY_LIKE | NAME_LIKE (resolved only)
--
-- Purged after 90 days by scheduler/logRetentionSweep.js, like the other
-- ip_*_logs tables. Apply BEFORE deploying the code that writes it.

CREATE TABLE IF NOT EXISTS ip_branch_lookup_logs (
  id             BIGINT        AUTO_INCREMENT PRIMARY KEY,
  result         ENUM('resolved','no_match','error') NOT NULL,
  input_method   VARCHAR(30)   NULL,     -- Current Live Location / Manual Address/Pincode / Unknown
  match_reason   VARCHAR(20)   NULL,
  input_pincode  VARCHAR(10)   NULL,
  input_place    VARCHAR(150)  NULL,
  input_lat      DECIMAL(10,7) NULL,
  input_lng      DECIMAL(10,7) NULL,
  branch_id      INT           NULL,
  branch_code    VARCHAR(20)   NULL,
  branch_name    VARCHAR(150)  NULL,
  is_fallback    TINYINT(1)    NOT NULL DEFAULT 0,
  message        TEXT          NULL,
  created_at     DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  INDEX idx_ip_branch_lookup_logs_created_at (created_at),
  INDEX idx_ip_branch_lookup_logs_branch_id  (branch_id),
  INDEX idx_ip_branch_lookup_logs_result     (result)
);
