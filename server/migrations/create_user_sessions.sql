-- One mobile number, two roles: lets the same person stay logged in to the
-- customer app AND the technician app at the same time.
--
-- Before this, ip_users held ONE login token, ONE logged-in flag and ONE push
-- (FCM) token per mobile, so logging in to one app logged the other one out,
-- and push notifications went to whichever app registered last.
-- ip_user_sessions keeps one row per user per role instead.
--
-- services/userSessions.js reads and writes this table. Until it exists the
-- server keeps working the old way (one session per number, technician
-- numbers can't log in as customer), so this can be applied before or after
-- the code is deployed. Run once on the database.

CREATE TABLE IF NOT EXISTS ip_user_sessions (
  session_row_id INT          NOT NULL AUTO_INCREMENT,
  user_id        INT          NOT NULL,
  role           ENUM('customer', 'technician') NOT NULL,
  auth_token     VARCHAR(1024) DEFAULT NULL,
  token_expiry   DATETIME     DEFAULT NULL,
  fcm_token      VARCHAR(512) DEFAULT NULL,
  is_logged_in   TINYINT(1)   NOT NULL DEFAULT 0,
  -- Set when a customer who is also a technician deletes their customer
  -- account: that number can't log in to the customer app again, but the
  -- technician login keeps working.
  closed_at      DATETIME     DEFAULT NULL,
  updated_at     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (session_row_id),
  UNIQUE KEY uq_user_role (user_id, role),
  KEY idx_user (user_id)
);

-- Copy every current login and push token across, under the role the account
-- has today, so nobody is logged out or stops getting notifications.
INSERT INTO ip_user_sessions (user_id, role, auth_token, token_expiry, fcm_token, is_logged_in)
SELECT u.user_id,
       IF(u.user_microlab_type = 'technician', 'technician', 'customer'),
       u.user_auth_token,
       u.user_token_expiry,
       u.user_notification_token,
       IFNULL(u.is_logged_in, 0)
FROM ip_users u
WHERE u.deleted_at IS NULL
  AND (u.user_auth_token IS NOT NULL OR u.user_notification_token IS NOT NULL)
ON DUPLICATE KEY UPDATE user_id = ip_user_sessions.user_id; -- already copied: keep it

-- Who uploaded a prescription, recorded at upload time ('customer' or
-- 'technician'), so the app's "Customer / Technician" tag stays correct for a
-- person who has both roles. Old rows stay NULL and are worked out from the
-- uploader's account as before.
ALTER TABLE ip_booking_documents
  ADD COLUMN IF NOT EXISTS uploaded_by_role VARCHAR(20) NULL DEFAULT NULL;
