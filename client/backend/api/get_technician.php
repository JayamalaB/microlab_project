<?php

ini_set('display_errors', 0);
error_reporting(E_ALL);
ini_set('log_errors', 1);
ini_set('error_log', __DIR__ . '/logs/php_errors.log');
date_default_timezone_set('Asia/Kolkata');

$CLIENT_SERVER_SECRET = 'micro123';

$logDir  = __DIR__ . '/logs';
$logFile = $logDir . '/technician.log';
if (!file_exists($logDir)) mkdir($logDir, 0777, true);

// ── Logger ────────────────────────────────────────────────

function writeLog($lines) {
    global $logFile;
    $dateStr = date('d-m-Y H:i:s') . ' IST';
    $divider = str_repeat('-', 50);
    $entry   = "\n{$divider}\n[{$dateStr}]\n" . implode("\n", $lines) . "\n{$divider}\n";
    file_put_contents($logFile, $entry, FILE_APPEND);
}

// ── HMAC verify ───────────────────────────────────────────

function verifySecureId($mobile_no, $user_type, $timestamp, $receivedSecureId) {
    global $CLIENT_SERVER_SECRET;
    $message  = "{$mobile_no}|{$user_type}|{$timestamp}";
    $expected = hash_hmac('sha256', $message, $CLIENT_SERVER_SECRET);
    return hash_equals($expected, $receivedSecureId);
}

// ── Read request ──────────────────────────────────────────

$data      = json_decode(file_get_contents('php://input'), true);
$mobile_no = $data['mobile_no'] ?? '';
$user_type = $data['user_type'] ?? '';
$timestamp = $data['timestamp'] ?? '';
$secure_id = $data['secure_id'] ?? '';

$logLines = [
    'REQUEST',
    "  mobile_no : {$mobile_no}",
    "  user_type : {$user_type}",
    "  timestamp : {$timestamp}",
    "  secure_id : {$secure_id}",
];

header('Content-Type: application/json');

// ── Validation ────────────────────────────────────────────

if (empty($mobile_no) || empty($user_type) || empty($timestamp) || empty($secure_id)) {
    $response = ['status' => 'failure', 'msg' => 'Missing required fields'];
    $logLines[] = 'RESPONSE  status:400  body:' . json_encode($response);
    writeLog($logLines);
    http_response_code(400);
    echo json_encode($response);
    exit;
}

$ageSecs = time() - (int)$timestamp;
if ($ageSecs < 0 || $ageSecs > 300) {
    $response = ['status' => 'failure', 'msg' => "Request expired (age: {$ageSecs}s)"];
    $logLines[] = 'RESPONSE  status:401  body:' . json_encode($response);
    writeLog($logLines);
    http_response_code(401);
    echo json_encode($response);
    exit;
}

if (!verifySecureId($mobile_no, $user_type, $timestamp, $secure_id)) {
    $response = ['status' => 'failure', 'msg' => 'Invalid secure_id'];
    $logLines[] = 'RESPONSE  status:401  body:' . json_encode($response);
    writeLog($logLines);
    http_response_code(401);
    echo json_encode($response);
    exit;
}

// ── Known technician registry (source of truth for new inserts) ───────────────
// When a mobile is found here but NOT in DB → auto-create DB records.
// When a mobile is NOT here → reject (not registered).

$KNOWN_TECHNICIANS = [
    '7339535472' => [
        'name'               => 'Anbu Durai',
        'email'              => 'durai.blog@gmail.com',
        'branch_id'          => 7,
        'technician_code'    => 'TECH-C090',
        'specialization'     => 'lab testig team',
        'tech_photo'         => 'https://chat.neuralarc.com/uploads/user.jpeg',
        'tech_city'          => 'Coimbatore',
        'max_daily_bookings' => 8,
    ],
    '9999999999' => [
        'name'               => 'Suresh M',
        'email'              => 'suresh@microlab.com',
        'branch_id'          => 4,
        'technician_code'    => 'TECH-C091',
        'specialization'     => 'Sample Collection',
        'tech_photo'         => 'https://chat.neuralarc.com/uploads/user.jpeg',
        'tech_city'          => 'Coimbatore',
        'max_daily_bookings' => 8,
    ],
    '8888888888' => [
        'name'               => 'Priya S',
        'email'              => 'priya@microlab.com',
        'branch_id'          => 4,
        'technician_code'    => 'TECH-C092',
        'specialization'     => 'Urine & Sample Collection',
        'tech_photo'         => 'https://chat.neuralarc.com/uploads/user.jpeg',
        'tech_city'          => 'Coimbatore',
        'max_daily_bookings' => 8,
    ],
];

// Not in the known list → reject immediately, no DB hit needed
if (!isset($KNOWN_TECHNICIANS[$mobile_no])) {
    $response = ['status' => 'failure', 'msg' => 'Technician not registered. Contact admin.'];
    $logLines[] = 'RESPONSE  status:404  body:' . json_encode($response);
    writeLog($logLines);
    http_response_code(404);
    echo json_encode($response);
    exit;
}

$known = $KNOWN_TECHNICIANS[$mobile_no];

// ── DB connection ─────────────────────────────────────────

$db = new mysqli('localhost', 'adminmicro', 'adminmicro', 'adminmicro');
if ($db->connect_error) {
    $logLines[] = 'DB CONNECT ERROR: ' . $db->connect_error;
    writeLog($logLines);
    http_response_code(500);
    echo json_encode(['status' => 'failure', 'msg' => 'Database connection failed']);
    exit;
}
$db->set_charset('utf8mb4');

// ── Step 1: Check if user exists in ip_users ──────────────

$stmt = $db->prepare(
    "SELECT u.user_id, t.technician_id
     FROM ip_users u
     LEFT JOIN ip_technicians t ON t.user_id = u.user_id
     WHERE u.user_mobile_no = ? AND u.user_microlab_type = 'technician'
     LIMIT 1"
);
$stmt->bind_param('s', $mobile_no);
$stmt->execute();
$result = $stmt->get_result();
$existing = $result->fetch_assoc();
$stmt->close();

$userId       = null;
$technicianId = null;

if ($existing) {
    // ── Case 1: user exists in ip_users ──────────────────
    $userId = $existing['user_id'];
    $logLines[] = "DB: found ip_users user_id={$userId}";

    // Update last-modified timestamp
    $db->query("UPDATE ip_users SET user_date_modified = NOW() WHERE user_id = {$userId}");

    if ($existing['technician_id']) {
        // ── Case 1a: technician record also exists → update timestamp only ──
        $technicianId = $existing['technician_id'];
        $logLines[] = "DB: found ip_technicians technician_id={$technicianId} → timestamps updated";
        $db->query("UPDATE ip_technicians SET updated_at = NOW() WHERE technician_id = {$technicianId}");

    } else {
        // ── Case 1b: user exists but no technician row → insert ip_technicians ──
        $logLines[] = "DB: ip_technicians missing for user_id={$userId} → inserting";
        $stmt = $db->prepare(
            "INSERT INTO ip_technicians
               (user_id, branch_id, technician_code, specialization,
                tech_photo, tech_city, is_available, max_daily_bookings, technician_active)
             VALUES (?, ?, ?, ?, ?, ?, 1, ?, 1)"
        );
        $stmt->bind_param(
            'iissssi',
            $userId,
            $known['branch_id'],
            $known['technician_code'],
            $known['specialization'],
            $known['tech_photo'],
            $known['tech_city'],
            $known['max_daily_bookings']
        );
        $stmt->execute();
        $technicianId = $db->insert_id;
        $stmt->close();
        $logLines[] = "DB: ip_technicians inserted technician_id={$technicianId}";
    }

} else {
    // ── Case 2: new user → insert ip_users then ip_technicians ───────────────
    $logLines[] = "DB: mobile not found → inserting new records";

    $db->begin_transaction();
    try {
        $stmt = $db->prepare(
            "INSERT INTO ip_users
               (user_type, user_active, user_date_created, user_date_modified,
                user_name, user_mobile, user_mobile_no, user_email,
                user_microlab_type, user_branch_id, user_all_clients, user_password, role_id)
             VALUES (1, 1, NOW(), NOW(), ?, ?, ?, ?, 'technician', ?, 0, '', 3)"
        );
        $stmt->bind_param(
            'ssssi',
            $known['name'],
            $mobile_no,
            $mobile_no,
            $known['email'],
            $known['branch_id']
        );
        $stmt->execute();
        $userId = $db->insert_id;
        $stmt->close();
        $logLines[] = "DB: ip_users inserted user_id={$userId}";

        $stmt = $db->prepare(
            "INSERT INTO ip_technicians
               (user_id, branch_id, technician_code, specialization,
                tech_photo, tech_city, is_available, max_daily_bookings, technician_active)
             VALUES (?, ?, ?, ?, ?, ?, 1, ?, 1)"
        );
        $stmt->bind_param(
            'iissssi',
            $userId,
            $known['branch_id'],
            $known['technician_code'],
            $known['specialization'],
            $known['tech_photo'],
            $known['tech_city'],
            $known['max_daily_bookings']
        );
        $stmt->execute();
        $technicianId = $db->insert_id;
        $stmt->close();
        $logLines[] = "DB: ip_technicians inserted technician_id={$technicianId}";

        $db->commit();
    } catch (Exception $e) {
        $db->rollback();
        $logLines[] = 'DB INSERT ERROR: ' . $e->getMessage();
        writeLog($logLines);
        http_response_code(500);
        echo json_encode(['status' => 'failure', 'msg' => 'Failed to create technician record']);
        exit;
    }
}

// ── Step 2: Read fresh from DB (admin may have changed fields) ────────────────

$stmt = $db->prepare(
    "SELECT t.technician_id, t.user_id, t.branch_id, t.technician_code,
            t.specialization, t.tech_photo, t.tech_city, t.is_available, t.max_daily_bookings,
            u.user_name AS name, u.user_email AS email, u.user_mobile_no AS mobile
     FROM ip_technicians t
     JOIN ip_users u ON u.user_id = t.user_id
     WHERE t.technician_id = ?
     LIMIT 1"
);
$stmt->bind_param('i', $technicianId);
$stmt->execute();
$row = $stmt->get_result()->fetch_assoc();
$stmt->close();
$db->close();

if (!$row) {
    $logLines[] = 'POST-UPSERT READ FAILED — technician_id=' . $technicianId;
    writeLog($logLines);
    http_response_code(500);
    echo json_encode(['status' => 'failure', 'msg' => 'Failed to read technician after upsert']);
    exit;
}

// ── Return ────────────────────────────────────────────────

$technician = [
    'technician_id'      => (int)$row['technician_id'],
    'user_id'            => (int)$row['user_id'],
    'name'               => $row['name'],
    'mobile'             => $row['mobile'],
    'email'              => $row['email'],
    'branch_id'          => (int)$row['branch_id'],
    'technician_code'    => $row['technician_code'],
    'specialization'     => $row['specialization'],
    'tech_photo'         => $row['tech_photo'],
    'tech_city'          => $row['tech_city'],
    'is_available'       => (int)$row['is_available'],
    'max_daily_bookings' => (int)$row['max_daily_bookings'],
];

$response = ['status' => 'success', 'technician' => $technician];
$logLines[] = 'RESPONSE';
$logLines[] = '  status  : 200';
$logLines[] = '  body    : ' . json_encode($response);
writeLog($logLines);

echo json_encode($response);
