// controllers/technicianController.js
//
// REST endpoints for technician availability and live-location data.
// Reads from technician_live_location which is kept current by bookingSocket.js
// via INSERT … ON DUPLICATE KEY UPDATE on every technician_online event.

const db = require('../config/db');

// ── GET /api/technicians/stats ────────────────────────────────────────────────
// Returns total / online / offline technician counts.
// Uses technician_live_location (one row per tech who has ever logged in).
exports.getStats = async (req, res) => {
  try {
    const [[row]] = await db.execute(`
      SELECT
        COUNT(*)                                                        AS total,
        SUM(CASE WHEN online_status = 'online'  THEN 1 ELSE 0 END)    AS online,
        SUM(CASE WHEN online_status = 'offline' THEN 1 ELSE 0 END)    AS offline
      FROM technician_live_location
    `);

    res.json({
      success: true,
      data: {
        total:   Number(row.total   ?? 0),
        online:  Number(row.online  ?? 0),
        offline: Number(row.offline ?? 0),
      },
    });
  } catch (e) {
    console.error('[technicianController.getStats]', e.message);
    res.status(500).json({ success: false, message: e.message });
  }
};

// ── GET /api/technicians/live ─────────────────────────────────────────────────
// Returns all currently-online technicians with their last-known coordinates.
// Only rows with valid GPS are included (latitude IS NOT NULL).
exports.getLive = async (req, res) => {
  try {
    const [rows] = await db.execute(`
      SELECT
        technician_id,
        socket_id,
        latitude,
        longitude,
        task_status,
        current_booking_id,
        last_ping_at,
        updated_at
      FROM technician_live_location
      WHERE online_status = 'online'
        AND latitude  IS NOT NULL
        AND longitude IS NOT NULL
      ORDER BY last_ping_at DESC
    `);

    res.json({ success: true, count: rows.length, data: rows });
  } catch (e) {
    console.error('[technicianController.getLive]', e.message);
    res.status(500).json({ success: false, message: e.message });
  }
};

// ── GET /api/technicians/all ──────────────────────────────────────────────────
// Returns every technician row with their current status — useful for an
// admin dashboard.  Sorted: online first, then by last_ping_at desc.
exports.getAll = async (req, res) => {
  try {
    const [rows] = await db.execute(`
      SELECT
        technician_id,
        online_status,
        task_status,
        current_booking_id,
        latitude,
        longitude,
        last_ping_at,
        updated_at
      FROM technician_live_location
      ORDER BY
        FIELD(online_status, 'online', 'offline'),
        last_ping_at DESC
    `);

    res.json({ success: true, count: rows.length, data: rows });
  } catch (e) {
    console.error('[technicianController.getAll]', e.message);
    res.status(500).json({ success: false, message: e.message });
  }
};
