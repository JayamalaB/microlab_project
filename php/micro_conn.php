<?php

ini_set('display_errors', 0);
error_reporting(E_ALL);
ini_set('log_errors', 1);
ini_set('error_log', __DIR__ . '/logs/php_errors.log');
date_default_timezone_set('Asia/Kolkata');

$CLIENT_SERVER_SECRET = 'replace_with_shared_secret_agreed_with_client_server';

$logDir  = __DIR__ . '/logs';
$logFile = $logDir . '/receiver.log';
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

// ── DB check ──────────────────────────────────────────────

$conn = new mysqli('localhost', 'microlab_home', 'microlab_home', 'microlab_home');
if ($conn->connect_error) {
    http_response_code(500);
    echo json_encode(['status' => 'failure', 'msg' => 'DB connection failed']);
    exit;
}

// Fix: compare incoming user_type case-insensitively;
// DB stores 'Technician' (capital T), so use that for the column match.
if (strtolower($user_type) === 'technician') {
    $db_type = 'Technician';
    $stmt    = $conn->prepare('SELECT user_id FROM users WHERE mobile_no = ? AND user_type = ?');
    if (!$stmt) {
        http_response_code(500);
        echo json_encode(['status' => 'failure', 'msg' => 'Prepare failed: ' . $conn->error]);
        exit;
    }
    $stmt->bind_param('ss', $mobile_no, $db_type);
} else {
    $stmt = $conn->prepare('SELECT user_id FROM users WHERE mobile_no = ?');
    if (!$stmt) {
        http_response_code(500);
        echo json_encode(['status' => 'failure', 'msg' => 'Prepare failed: ' . $conn->error]);
        exit;
    }
    $stmt->bind_param('s', $mobile_no);
}

if (!$stmt->execute()) {
    http_response_code(500);
    echo json_encode(['status' => 'failure', 'msg' => 'Execute failed: ' . $stmt->error]);
    exit;
}

$stmt->store_result();
$found = ($stmt->num_rows > 0);
$stmt->close();
$conn->close();

// ── Response ──────────────────────────────────────────────

if (!$found) {
    $response = ['status' => 'failure', 'msg' => 'Mobile Not Available'];
} else {
    $response = ['status' => 'success', 'msg' => 'Mobile No Available'];
}

$logLines[] = 'RESPONSE  body:' . json_encode($response);
writeLog($logLines);

echo json_encode($response);
