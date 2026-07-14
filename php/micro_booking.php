<?php

ini_set('display_errors', 0);
error_reporting(E_ALL);
ini_set('log_errors', 1);
ini_set('error_log', __DIR__ . '/logs/php_errors.log');
date_default_timezone_set('Asia/Kolkata');

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

$mobile_no   = $data['mobile_no']   ?? '';
$user_type   = $data['user_type']   ?? '';
$booking_ref = $data['booking_ref'] ?? '';

// ── Log incoming payload ──────────────────────────────────

$logLines = [
    'REQUEST',
    "  mobile_no    : {$mobile_no}",
    "  user_type    : {$user_type}",
    "  booking_ref  : {$booking_ref}",
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

if (empty($mobile_no) || empty($user_type) || empty($booking_ref)) {
    $response = ['status' => 'failure', 'msg' => 'mobile_no, user_type and booking_ref are required'];
    $logLines[] = 'RESPONSE  status:400  missing required fields';
    writeLog($logLines);
    http_response_code(400);
    echo json_encode($response);
    exit;
}

// ── Mock response ─────────────────────────────────────────
// Replace this section with real DB logic when client server is ready.

$mockBillId = 'BILL' . time();

if ($isNewPatient) {
    // Generate a mock patient_id for new patients
    $mockPatientId = rand(1000, 9999);
    $response = [
        'status'     => 'success',
        'patient_id' => $mockPatientId,
        'bill_id'    => $mockBillId,
    ];
    $logLines[] = "RESPONSE  status:201  new_patient_id={$mockPatientId}  bill_id={$mockBillId}";
} else {
    // Existing patient — echo back their patient_id
    $response = [
        'status'     => 'success',
        'patient_id' => $data['patient_id'],
        'bill_id'    => $mockBillId,
    ];
    $logLines[] = "RESPONSE  status:200  patient_id={$data['patient_id']}  bill_id={$mockBillId}";
}

writeLog($logLines);
echo json_encode($response);
