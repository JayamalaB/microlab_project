-- Database copies of 7 existing technician-related .log files, additive only
-- (the .log files keep writing exactly as before — see each logger function
-- in the source files listed below). Built from direct inspection of each
-- logger's actual call sites, not a generic/guessed schema — see each
-- table's comment for which file/function it mirrors and why its columns
-- are shaped the way they are.
--
-- booking_id/technician_id/mobile_masked columns are populated by
-- best-effort regex extraction out of the existing free-text log messages
-- (server/utils/dbLogger.js) — the message/details column always holds the
-- full text regardless, so a missed extraction loses an index, never data.

-- Mirrors bookingSocket.js's dlog() (24 call sites, writes dispatch.log) AND
-- its log() function (the richer duplicate-request/timeout/retry/skip/
-- accept/reject events that today are console-only and never reach
-- dispatch.log at all — see dbLogger.js's logDispatchEvent for the central
-- instrumentation point). logBlock() is intentionally NOT mirrored here: its
-- bookingId lives inside a free-text title rather than a parameter, and
-- every logBlock() call sits alongside a dlog()/log() call for the same
-- event at the same call site, so no unique structured event is lost.
-- No technician_id column: neither dlog() nor log() receives it as a
-- reliable parameter (it's often just a name in free text, e.g.
-- "tech=Suresh"), so a column that would be NULL on nearly every row was
-- deliberately left out rather than added and unused.
CREATE TABLE IF NOT EXISTS ip_dispatch_logs (
  id          BIGINT        AUTO_INCREMENT PRIMARY KEY,
  booking_id  INT           NULL,
  tag         VARCHAR(30)   NOT NULL,
  details     TEXT          NULL,
  created_at  DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  INDEX idx_ip_dispatch_logs_booking_id (booking_id),
  INDEX idx_ip_dispatch_logs_tag (tag),
  INDEX idx_ip_dispatch_logs_created_at (created_at)
);

-- Mirrors bookingSocket.js's clog() (21 call sites: collection_started,
-- sample_collected, handed_to_lab). event/level/booking_id/technician_id
-- are parsed out of the message (see dbLogger.js) since clog() itself only
-- ever receives one pre-formatted string, not structured fields.
CREATE TABLE IF NOT EXISTS ip_collection_logs (
  id            BIGINT      AUTO_INCREMENT PRIMARY KEY,
  booking_id    INT         NULL,
  technician_id INT         NULL,
  event         VARCHAR(30) NULL,
  level         ENUM('info','warn','error') NOT NULL DEFAULT 'info',
  message       TEXT        NULL,
  created_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  INDEX idx_ip_collection_logs_booking_id (booking_id),
  INDEX idx_ip_collection_logs_technician_id (technician_id),
  INDEX idx_ip_collection_logs_created_at (created_at)
);

-- Mirrors technicianController.js's otpLog() (21 call sites: generateBookingOtp
-- GENERATE/resendBookingOtp RESEND). Never stores the OTP value itself —
-- confirmed by inspection that otpLog() never logged it in the first place
-- (only otp.log, a different file/table, did — see ip_login_otp_logs below).
CREATE TABLE IF NOT EXISTS ip_otpinfo_logs (
  id              BIGINT      AUTO_INCREMENT PRIMARY KEY,
  booking_id      INT         NULL,
  technician_id   INT         NULL,
  event           VARCHAR(20) NULL,       -- GENERATE, RESEND
  mobile_masked   VARCHAR(15) NULL,
  level           ENUM('info','warn','error') NOT NULL DEFAULT 'info',
  message         TEXT        NULL,
  created_at      DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  INDEX idx_ip_otpinfo_logs_booking_id (booking_id),
  INDEX idx_ip_otpinfo_logs_technician_id (technician_id)
);

-- Mirrors technicianController.js's tlog() (only 8 call sites: getHistory,
-- cancelAssignedBooking — narrower than the file name suggests; most other
-- technician-controller actions use plain console.log, not tlog()).
CREATE TABLE IF NOT EXISTS ip_technician_logs (
  id            BIGINT      AUTO_INCREMENT PRIMARY KEY,
  technician_id INT         NULL,
  booking_id    INT         NULL,     -- only present on cancelAssignedBooking entries
  event         VARCHAR(30) NULL,     -- getHistory, cancelAssignedBooking
  level         ENUM('info','warn','error') NOT NULL DEFAULT 'info',
  message       TEXT        NULL,
  created_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  INDEX idx_ip_technician_logs_technician_id (technician_id),
  INDEX idx_ip_technician_logs_booking_id (booking_id)
);

-- Mirrors authController.js's writeLog() (login OTP, both customer and
-- technician roles share this file). The OTP value is NEVER stored here —
-- the source call site (authController.js sendOtp) is being edited as part
-- of this same change to stop including the raw value in the message at
-- all, so the file log and this table both lose the plaintext value
-- together, not just this table alone.
--
-- Named ip_login_otp_logs (not ip_otp_logs) — this schema already has an
-- unrelated, pre-existing ip_otp_logs table (different columns, not part of
-- this feature) that a plain CREATE TABLE IF NOT EXISTS ip_otp_logs would
-- have silently collided with instead of creating ours.
CREATE TABLE IF NOT EXISTS ip_login_otp_logs (
  id            BIGINT      AUTO_INCREMENT PRIMARY KEY,
  user_id       INT         NULL,
  mobile_masked VARCHAR(15) NULL,
  event         VARCHAR(20) NULL,     -- sendOtp, verifyOtp
  level         ENUM('info','warn','error') NOT NULL DEFAULT 'info',
  message       TEXT        NULL,
  created_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  INDEX idx_ip_login_otp_logs_user_id (user_id),
  INDEX idx_ip_login_otp_logs_created_at (created_at)
);

-- Mirrors clientSync.js's writeLog() (35 call sites: syncBookingToClient /
-- syncVisitCompletionToClient). initiator_type/action are reliably
-- extractable — every call site's message literally includes
-- "type=${initiator.type}" and/or "action=${...}" as-is.
CREATE TABLE IF NOT EXISTS ip_client_sync_logs (
  id              BIGINT      AUTO_INCREMENT PRIMARY KEY,
  booking_id      INT         NULL,
  technician_id   INT         NULL,   -- only present when initiator_type='technician'
  initiator_type  VARCHAR(15) NULL,   -- technician, customer
  action          VARCHAR(30) NULL,   -- collection_photo_added, package_added, visit_completed, etc.
  level           ENUM('info','warn','error') NOT NULL DEFAULT 'info',
  message         TEXT        NULL,
  created_at      DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  INDEX idx_ip_client_sync_logs_booking_id (booking_id),
  INDEX idx_ip_client_sync_logs_technician_id (technician_id),
  INDEX idx_ip_client_sync_logs_action (action)
);

-- Mirrors customerPush.js's writeLog() (9 call sites inside
-- sendToBookingOwner) — FCM push notifications to the customer, several of
-- which are triggered by technician-side milestones (Technician Assigned,
-- On the Way, Arrived).
CREATE TABLE IF NOT EXISTS ip_customer_push_logs (
  id            BIGINT      AUTO_INCREMENT PRIMARY KEY,
  booking_id    INT         NULL,
  mobile_masked VARCHAR(15) NULL,
  title         VARCHAR(100) NULL,
  status        ENUM('sent','failed','skipped') NULL,
  message       TEXT        NULL,
  created_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  INDEX idx_ip_customer_push_logs_booking_id (booking_id)
);
