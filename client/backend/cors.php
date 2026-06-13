<?php
// ── CORS + JSON headers ────────────────────────────────────────────────────
// Allows the Flutter app (any origin) to call this API over local network.

header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, Authorization');
header('Content-Type: application/json');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(200);
    exit;
}

// ── Helper: send JSON response ─────────────────────────────────────────────

function respond(bool $success, $data = null, string $message = '', int $code = 200): void {
    http_response_code($code);
    $body = ['success' => $success];
    if ($message !== '') $body['message'] = $message;
    if ($data !== null)   $body['data']    = $data;
    echo json_encode($body);
    exit;
}

// ── Helper: read JSON request body ────────────────────────────────────────

function requestBody(): array {
    $raw = file_get_contents('php://input');
    return json_decode($raw, true) ?? [];
}

// ── Helper: verify Bearer token from Authorization header ─────────────────
// Returns the customer_id if valid, or exits with 401.

function requireAuth(mysqli $db): int {
    $auth = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
    if (!str_starts_with($auth, 'Bearer ')) {
        respond(false, null, 'Unauthorized', 401);
    }
    $token = substr($auth, 7);
    $stmt  = $db->prepare('SELECT id FROM customers WHERE auth_token = ? LIMIT 1');
    $stmt->bind_param('s', $token);
    $stmt->execute();
    $row = $stmt->get_result()->fetch_assoc();
    $stmt->close();
    if (!$row) respond(false, null, 'Unauthorized', 401);
    return (int) $row['id'];
}
