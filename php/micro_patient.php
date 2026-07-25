<?php

ini_set('display_errors', 0);
error_reporting(E_ALL);
ini_set('log_errors', 1);
ini_set('error_log', __DIR__ . '/logs/php_errors.log');
date_default_timezone_set('Asia/Kolkata');

$CLIENT_SERVER_SECRET = 'micro123';

$logDir  = __DIR__ . '/logs';
$logFile = $logDir . '/patient.log';
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

// ── Mock patient data ─────────────────────────────────────
// Replace with real DB query later.

$MOCK_PATIENTS = [
    '8056535850' => [
        [
            'patient_id'       => 1,
            'name'             => 'Sara',
            'gender'           => 'Female',
            'location'         => 'Peelamedu',
            'address'          => '342 Sirumangalam',
            'email'            => 'gpushpaganesan@gmail.com',
            'date_of_birth'    => '14-05-1998',
            'age'              => '27',
            'relation'         => 'Self',
            'health_condition' => 'Walker',
            'photo'            => 'https://test.neuralarc.com/api/uploads/user.jpeg',
        ],
    ],

    '9876543211' => [
        [
            'patient_id'       => 12,
            'name'             => 'Rahul Kumar',
            'gender'           => 'Male',
            'location'         => 'Gandhipuram',
            'address'          => '123 Cross Street, Coimbatore',
            'email'            => 'rahul@example.com',
            'date_of_birth'    => '10-08-1995',
            'age'              => '30',
            'relation'         => 'Self',
            'health_condition' => 'Healthy',
            'photo'            => 'https://test.neuralarc.com/api/uploads/user.jpeg',
        ],
        [
            'patient_id'       => 3,
            'name'             => 'Suresh Kumar',
            'gender'           => 'Male',
            'location'         => 'Gandhipuram',
            'address'          => '123 Cross Street, Coimbatore',
            'email'            => null,
            'date_of_birth'    => '15-03-1965',
            'age'              => '60',
            'relation'         => 'Father',
            'health_condition' => 'Diabetic',
            'photo'            => null,
        ],
        [
            'patient_id'       => 4,
            'name'             => 'Kavitha Kumar',
            'gender'           => 'Female',
            'location'         => 'Gandhipuram',
            'address'          => '123 Cross Street, Coimbatore',
            'email'            => null,
            'date_of_birth'    => '22-07-1968',
            'age'              => '57',
            'relation'         => 'Mother',
            'health_condition' => 'BP, Thyroid',
            'photo'            => null,
        ],
    ],
];

$patients = $MOCK_PATIENTS[$mobile_no] ?? [];

$response = ['status' => 'success', 'patient' => $patients];
$logLines[] = 'RESPONSE';
$logLines[] = '  status  : 200';
$logLines[] = '  body    : ' . json_encode($response);
writeLog($logLines);

echo json_encode($response);
