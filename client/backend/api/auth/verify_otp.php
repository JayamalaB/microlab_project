<?php
// POST /api/auth/verify_otp.php
// Body: { "mobile": "9876543210", "otp": "1234", "role": "customer" | "technician" }
// Returns: { auth_token, user_id, role, name }

require_once __DIR__ . '/../../cors.php';
require_once __DIR__ . '/../../config.php';

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    respond(false, null, 'Method not allowed', 405);
}

$body   = requestBody();
$mobile = trim($body['mobile'] ?? '');
$otp    = trim($body['otp']    ?? '');
$role   = trim($body['role']   ?? 'customer');

if ($mobile === '' || $otp === '') {
    respond(false, null, 'mobile and otp are required', 422);
}

$db = getDB();

// Verify OTP
$stmt = $db->prepare(
    'SELECT id FROM otp_logs WHERE mobile = ? AND otp = ? AND role = ? AND expires_at > NOW() LIMIT 1'
);
$stmt->bind_param('sss', $mobile, $otp, $role);
$stmt->execute();
$log = $stmt->get_result()->fetch_assoc();
$stmt->close();

if (!$log) {
    respond(false, null, 'Invalid or expired OTP', 401);
}

// Delete used OTP
$del = $db->prepare('DELETE FROM otp_logs WHERE mobile = ?');
$del->bind_param('s', $mobile);
$del->execute();
$del->close();

// Upsert customer/technician record
// Adjust the table and column names below if your schema differs.
$token = bin2hex(random_bytes(32));

if ($role === 'technician') {
    $stmt = $db->prepare('SELECT id, name FROM technicians WHERE mobile = ? LIMIT 1');
    $stmt->bind_param('s', $mobile);
    $stmt->execute();
    $user = $stmt->get_result()->fetch_assoc();
    $stmt->close();

    if (!$user) {
        respond(false, null, 'Technician not registered', 403);
    }

    $upd = $db->prepare('UPDATE technicians SET auth_token = ? WHERE id = ?');
    $upd->bind_param('si', $token, $user['id']);
    $upd->execute();
    $upd->close();

    respond(true, [
        'auth_token' => $token,
        'user_id'    => $user['id'],
        'name'       => $user['name'],
        'role'       => 'technician',
    ]);
} else {
    // customer / vip_customer
    $stmt = $db->prepare('SELECT id, name, role FROM customers WHERE mobile = ? LIMIT 1');
    $stmt->bind_param('s', $mobile);
    $stmt->execute();
    $user = $stmt->get_result()->fetch_assoc();
    $stmt->close();

    if (!$user) {
        // Auto-register new customer
        $ins = $db->prepare(
            'INSERT INTO customers (mobile, name, role, auth_token) VALUES (?, ?, ?, ?)'
        );
        $name    = 'User';
        $newRole = 'customer';
        $ins->bind_param('ssss', $mobile, $name, $newRole, $token);
        $ins->execute();
        $userId = (int) $db->insert_id;
        $ins->close();

        respond(true, [
            'auth_token' => $token,
            'user_id'    => $userId,
            'name'       => $name,
            'role'       => $newRole,
        ]);
    } else {
        $upd = $db->prepare('UPDATE customers SET auth_token = ? WHERE id = ?');
        $upd->bind_param('si', $token, $user['id']);
        $upd->execute();
        $upd->close();

        respond(true, [
            'auth_token' => $token,
            'user_id'    => $user['id'],
            'name'       => $user['name'],
            'role'       => $user['role'],
        ]);
    }
}
$db->close();
