<?php
// GET /api/slots.php
// Returns available time slots.
// Query param: ?date=YYYY-MM-DD (optional, for future availability logic)

require_once __DIR__ . '/../cors.php';
require_once __DIR__ . '/../config.php';

if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
    respond(false, null, 'Method not allowed', 405);
}

$db  = getDB();
// Adjust table/column names to match your schema.
// Expected columns: id, label, time, active (1/0)
$res  = $db->query('SELECT id, label, time FROM time_slots WHERE active = 1 ORDER BY id ASC');
$rows = [];
while ($row = $res->fetch_assoc()) {
    $rows[] = $row;
}
$db->close();

respond(true, $rows);
