-- Technician booking alerts (scheduler/technicianReminderScheduler.js).
-- One timestamp per alert so each is sent at most once per booking:
--   reminder_sent_at      — "upcoming booking" reminder (default 60 min before)
--   late_alert_1_sent_at  — first late alert  (default 5 min after the time)
--   late_alert_2_sent_at  — second late alert (default 10 min after the time)
-- Safe to run more than once.
ALTER TABLE ip_technician_collection
  ADD COLUMN IF NOT EXISTS reminder_sent_at     DATETIME NULL DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS late_alert_1_sent_at DATETIME NULL DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS late_alert_2_sent_at DATETIME NULL DEFAULT NULL;
