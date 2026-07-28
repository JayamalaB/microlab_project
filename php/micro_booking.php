<?php

ini_set('display_errors', 0);
error_reporting(E_ALL);
ini_set('log_errors', 1);
ini_set('error_log', __DIR__ . '/logs/php_errors.log');
date_default_timezone_set('Asia/Kolkata');

$CLIENT_SERVER_SECRET = 'micro123';

$logDir  = __DIR__ . '/logs';
$logFile = $logDir . '/booking_sync.log';
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

header('Content-Type: application/json');

$raw  = file_get_contents('php://input');
$data = json_decode($raw, true);

if (!$data) {
    $response = ['status' => 'failure', 'msg' => 'Invalid JSON body'];
    writeLog(['REQUEST: invalid JSON', 'raw: ' . substr($raw, 0, 300)]);
    http_response_code(400);
    echo json_encode($response);
    exit;
}

$mobile_no        = $data['mobile_no']        ?? '';
$user_type        = $data['user_type']        ?? '';
$timestamp        = $data['timestamp']        ?? '';
$secure_id        = $data['secure_id']        ?? '';
$booking_ref      = $data['booking_ref']      ?? '';
$booking_status   = $data['booking_status']   ?? 'pending';
$existing_bill_id = $data['existing_bill_id'] ?? null;

// ── Verify secure_id ──────────────────────────────────────

if (empty($mobile_no) || empty($user_type) || empty($timestamp) || empty($secure_id)) {
    $response = ['status' => 'failure', 'msg' => 'Missing required fields'];
    writeLog(['REQUEST: missing required fields', 'raw: ' . substr($raw, 0, 300)]);
    http_response_code(400);
    echo json_encode($response);
    exit;
}

$ageSecs = time() - (int)$timestamp;
if ($ageSecs < 0 || $ageSecs > 300) {
    $response = ['status' => 'failure', 'msg' => "Request expired (age: {$ageSecs}s)"];
    writeLog(["REQUEST: expired timestamp  age={$ageSecs}s  mobile={$mobile_no}"]);
    http_response_code(401);
    echo json_encode($response);
    exit;
}

if (!verifySecureId($mobile_no, $user_type, $timestamp, $secure_id)) {
    $response = ['status' => 'failure', 'msg' => 'Invalid secure_id'];
    writeLog(["REQUEST: invalid secure_id  mobile={$mobile_no}"]);
    http_response_code(401);
    echo json_encode($response);
    exit;
}

// ── Log incoming payload ──────────────────────────────────

$logLines = [
    'REQUEST',
    "  mobile_no    : {$mobile_no}",
    "  user_type    : {$user_type}",
    "  timestamp    : {$timestamp}",
    "  booking_ref  : {$booking_ref}",
    "  booking_status: {$booking_status}",
    "  existing_bill: " . ($existing_bill_id ?? 'none'),
    "  booking_type : " . ($data['booking_type'] ?? ''),
    "  slot_date    : " . ($data['slot_details']['date'] ?? ''),
    "  slot_time    : " . ($data['slot_details']['time'] ?? ''),
];

// Patient — new or existing
if (!empty($data['patient_id'])) {
    $logLines[] = "  patient      : EXISTING  patient_id={$data['patient_id']}";
    $isNewPatient = false;
} elseif (!empty($data['patient_details'])) {
    $pd = $data['patient_details'];
    $logLines[] = "  patient      : NEW";
    $logLines[] = "    name           : " . ($pd['name']             ?? '');
    $logLines[] = "    mobile         : " . ($pd['mobile']           ?? '');
    $logLines[] = "    gender         : " . ($pd['gender']           ?? '');
    $logLines[] = "    relation       : " . ($pd['relation']         ?? '');
    $logLines[] = "    date_of_birth  : " . ($pd['date_of_birth']    ?? '');
    $logLines[] = "    age            : " . ($pd['age']              ?? '');
    $logLines[] = "    email          : " . ($pd['email']            ?? '');
    $logLines[] = "    location       : " . ($pd['location']         ?? '');
    $logLines[] = "    address        : " . ($pd['address']          ?? '');
    $logLines[] = "    health_cond    : " . ($pd['health_condition'] ?? '');
    $logLines[] = "    photo          : " . ($pd['photo']            ?? 'none');
    $isNewPatient = true;
} else {
    $response = ['status' => 'failure', 'msg' => 'patient_id or patient_details required'];
    $logLines[] = 'RESPONSE  status:400  missing patient info';
    writeLog($logLines);
    http_response_code(400);
    echo json_encode($response);
    exit;
}

// Tests
if (!empty($data['blood_test_list'])) {
    foreach ($data['blood_test_list'] as $t) {
        $docFlag = $t['document_required'] === 'yes' ? " [doc:{$t['document']}]" : '';
        $logLines[] = "  test         : id={$t['id']}  name={$t['name']}  price={$t['price']}{$docFlag}";
    }
}

// Payment
if (!empty($data['payment_details'])) {
    $pd = $data['payment_details'];
    $logLines[] = "  payment      : total={$pd['total_amount']}  paid={$pd['paid_amount']}  type={$pd['payment_type']}  razorpay={$pd['razorpay_payment_id']}";
}

// ── Validation ────────────────────────────────────────────

if (empty($booking_ref)) {
    $response = ['status' => 'failure', 'msg' => 'booking_ref is required'];
    $logLines[] = 'RESPONSE  status:400  missing booking_ref';
    writeLog($logLines);
    http_response_code(400);
    echo json_encode($response);
    exit;
}

// ── Response ──────────────────────────────────────────────
// Use explicit action field sent by Node.js server:
//   new_booking    → create new bill
//   cancel         → acknowledge cancellation, return existing bill_id
//   reschedule     → update slot, return existing bill_id
//   payment_update → update payment info, return existing bill_id
//   update/retry   → generic update, return existing bill_id

$action = $data['action'] ?? (empty($existing_bill_id) ? 'new_booking' : 'update');
$logLines[] = "  action       : {$action}";

if ($action === 'new_booking') {
    $newBillId = 'BILL' . time();
    if ($isNewPatient) {
        $mockPatientId = rand(1000, 9999);
        $response = [
            'status'     => 'success',
            'patient_id' => $mockPatientId,
            'bill_id'    => $newBillId,
            'action'     => 'created',
        ];
        $logLines[] = "RESPONSE  status:201  action=created  new_patient_id={$mockPatientId}  bill_id={$newBillId}";
    } else {
        $response = [
            'status'     => 'success',
            'patient_id' => $data['patient_id'],
            'bill_id'    => $newBillId,
            'action'     => 'created',
        ];
        $logLines[] = "RESPONSE  status:200  action=created  patient_id={$data['patient_id']}  bill_id={$newBillId}";
    }

} elseif ($action === 'cancel') {
    $response = [
        'status'  => 'success',
        'bill_id' => $existing_bill_id,
        'action'  => 'cancelled',
    ];
    $logLines[] = "RESPONSE  status:200  action=cancelled  bill_id=" . ($existing_bill_id ?? 'none');

} elseif ($action === 'reschedule') {
    $response = [
        'status'     => 'success',
        'bill_id'    => $existing_bill_id,
        'patient_id' => $data['patient_id'] ?? null,
        'action'     => 'rescheduled',
    ];
    $logLines[] = "RESPONSE  status:200  action=rescheduled  bill_id={$existing_bill_id}";

} elseif ($action === 'payment_update') {
    $response = [
        'status'     => 'success',
        'bill_id'    => $existing_bill_id,
        'patient_id' => $data['patient_id'] ?? null,
        'action'     => 'payment_updated',
    ];
    $logLines[] = "RESPONSE  status:200  action=payment_updated  bill_id={$existing_bill_id}";

} else {
    // Generic update (retry / unknown)
    $response = [
        'status'     => 'success',
        'bill_id'    => $existing_bill_id,
        'patient_id' => $data['patient_id'] ?? null,
        'action'     => 'updated',
    ];
    $logLines[] = "RESPONSE  status:200  action=updated  bill_id={$existing_bill_id}";
}

writeLog($logLines);
echo json_encode($response);
