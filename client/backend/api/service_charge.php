<?php
// GET /api/service_charge.php?pincode=600001&city=Chennai
// Returns the applicable service charge for the given location.

require_once __DIR__ . '/../cors.php';
require_once __DIR__ . '/../config.php';

if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
    respond(false, null, 'Method not allowed', 405);
}

$pincode = trim($_GET['pincode'] ?? '');
$city    = trim($_GET['city']    ?? '');
$db      = getDB();

// Try pincode-specific charge first, then city-level, then default.
if ($pincode !== '') {
    $stmt = $db->prepare('SELECT amount FROM service_charges WHERE pincode = ? LIMIT 1');
    $stmt->bind_param('s', $pincode);
    $stmt->execute();
    $row = $stmt->get_result()->fetch_assoc();
    $stmt->close();
    if ($row) {
        $db->close();
        respond(true, ['amount' => (float) $row['amount']]);
    }
}

if ($city !== '') {
    $stmt = $db->prepare('SELECT amount FROM service_charges WHERE city = ? AND pincode IS NULL LIMIT 1');
    $stmt->bind_param('s', $city);
    $stmt->execute();
    $row = $stmt->get_result()->fetch_assoc();
    $stmt->close();
    if ($row) {
        $db->close();
        respond(true, ['amount' => (float) $row['amount']]);
    }
}

// Default fallback
$row = $db->query('SELECT amount FROM service_charges WHERE pincode IS NULL AND city IS NULL LIMIT 1')->fetch_assoc();
$db->close();
respond(true, ['amount' => $row ? (float) $row['amount'] : 0.0]);
