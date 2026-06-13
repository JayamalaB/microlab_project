<?php
// GET /api/tests.php
// Returns all active tests and packages.
// Query params: ?type=single|package  ?category=<name>

require_once __DIR__ . '/../cors.php';
require_once __DIR__ . '/../config.php';

if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
    respond(false, null, 'Method not allowed', 405);
}

$db = getDB();

// Build WHERE clause from optional filters
$where  = ['1=1'];
$params = [];
$types  = '';

if (!empty($_GET['type'])) {
    $where[]  = 'type = ?';
    $params[] = $_GET['type'];
    $types   .= 's';
}
if (!empty($_GET['category'])) {
    $where[]  = 'category = ?';
    $params[] = $_GET['category'];
    $types   .= 's';
}

$sql  = 'SELECT * FROM tests WHERE ' . implode(' AND ', $where) . ' ORDER BY name ASC';
$stmt = $db->prepare($sql);
if ($params) {
    $stmt->bind_param($types, ...$params);
}
$stmt->execute();
$result = $stmt->get_result();

$tests = [];
while ($row = $result->fetch_assoc()) {
    $tests[] = $row;
}
$stmt->close();
$db->close();

respond(true, $tests);
