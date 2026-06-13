<?php
// POST /api/auth/send_otp.php
// Body: { "mobile": "9876543210", "role": "customer" | "technician" }
// Returns OTP in response (dev mode — swap with SMS gateway for production).

require_once __DIR__ . '/../../cors.php';
require_once __DIR__ . '/../../config.php';

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    respond(false, null, 'Method not allowed', 405);
}

$body   = requestBody();
$mobile = trim($body['mobile'] ?? '');
$role   = trim($body['role']   ?? 'customer');

if (!preg_match('/^[6-9]\d{9}$/', $mobile)) {
    respond(false, null, 'Invalid mobile number', 422);
}

$db = getDB();

// Remove existing OTPs for this number
$del = $db->prepare('DELETE FROM otp_logs WHERE mobile = ?');
$del->bind_param('s', $mobile);
$del->execute();
$del->close();

// Generate 4-digit OTP valid for 5 minutes
$otp     = str_pad((string) random_int(1000, 9999), 4, '0', STR_PAD_LEFT);
$expires = date('Y-m-d H:i:s', time() + 300);

$stmt = $db->prepare('INSERT INTO otp_logs (mobile, otp, role, expires_at) VALUES (?, ?, ?, ?)');
$stmt->bind_param('ssss', $mobile, $otp, $role, $expires);
if (!$stmt->execute()) {
    respond(false, null, 'Could not generate OTP', 500);
}
$stmt->close();
$db->close();

// TODO: replace the line below with your SMS gateway call in production.
respond(true, ['otp' => $otp], 'OTP sent');
