<?php
// GET /api/branches.php
// Returns all lab branches.

require_once __DIR__ . '/../cors.php';
require_once __DIR__ . '/../config.php';

if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
    respond(false, null, 'Method not allowed', 405);
}

$db   = getDB();
$res  = $db->query('SELECT id, name, address FROM branches ORDER BY name ASC');
$rows = [];
while ($row = $res->fetch_assoc()) {
    $rows[] = $row;
}
$db->close();

respond(true, $rows);
