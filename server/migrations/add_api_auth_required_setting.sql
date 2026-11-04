-- Login enforcement switch for the routes and sockets the older app calls
-- without a token (middleware/rolloutAuth.js, socket/socketAuth.js).
--   'false' — no-token calls still work, and each is logged as [AUTH_ROLLOUT]
--   'true'  — no-token calls are refused
-- Starts 'false'. Turn it on only after the new app is rolled out and the
-- [AUTH_ROLLOUT] lines have stopped:
--   UPDATE ip_settings SET setting_value = 'true' WHERE setting_key = 'api_auth_required';
-- The server re-reads ip_settings every 5 minutes, so no restart is needed.
-- Safe to run more than once.
INSERT INTO ip_settings (setting_key, setting_value)
SELECT 'api_auth_required', 'false'
WHERE NOT EXISTS (SELECT 1 FROM ip_settings WHERE setting_key = 'api_auth_required');
