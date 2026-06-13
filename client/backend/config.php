<?php
// ── Database Configuration ─────────────────────────────────────────────────
// Adjust these values to match your XAMPP MySQL setup.

define('DB_HOST', 'localhost');
define('DB_USER', 'root');
define('DB_PASS', '');           // default XAMPP: empty
define('DB_NAME', 'microlab_home');

function getDB(): mysqli {
    $conn = new mysqli(DB_HOST, DB_USER, DB_PASS, DB_NAME);
    if ($conn->connect_error) {
        http_response_code(500);
        echo json_encode(['success' => false, 'message' => 'DB connection failed: ' . $conn->connect_error]);
        exit;
    }
    $conn->set_charset('utf8mb4');
    return $conn;
}
