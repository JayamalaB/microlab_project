// controllers/technicianController.js
//
// REST endpoints for technician availability and live-location data.
// Reads from ip_technician_live_location which is kept current by bookingSocket.js
// via INSERT … ON DUPLICATE KEY UPDATE on every technician_online event.

const db = require('../config/db');

// Converts "HH:MM:SS" TIME strings to appointment slot array "HH:MM:00"
function _generateIntervals(startTime, endTime, durationMinutes) {
  const toMin = t => { const [h, m] = t.split(':').map(Number); return h * 60 + m; };
  const startMin = toMin(startTime);
  const endMin   = toMin(endTime);
  const times = [];
  for (let t = startMin; t < endMin; t += durationMinutes) {
    const h = String(Math.floor(t / 60)).padStart(2, '0');
    const m = String(t % 60).padStart(2, '0');
    times.push(`${h}:${m}:00`);
  }
  return times;
}

// ── GET /api/technicians/:technicianId/profile ───────────────────────────────
exports.getProfile = async (req, res) => {
  const { technicianId } = req.params;
  console.log(`\n👤 [GET PROFILE] technician_id=${technicianId}`);
  try {
    const [[profile]] = await db.execute(
      `SELECT u.user_name, u.user_email, u.user_mobile_no,
              t.technician_id, t.branch_id, t.technician_code, t.specialization,
              t.tech_photo, t.tech_city, t.is_available, t.max_daily_bookings,
              b.branch_name
       FROM ip_users u
       JOIN ip_technicians t ON t.user_id = u.user_id
       LEFT JOIN ip_branches b ON b.branch_id = t.branch_id
       WHERE t.technician_id = ?`,
      [technicianId]
    );

    if (!profile) {
      return res.status(404).json({ success: false, message: 'Technician not found' });
    }

    // ✅ FIXED: Added 'collected' to completed_today calculation
    const [[stats]] = await db.execute(
      `SELECT
         COUNT(*) AS assigned_today,
         SUM(CASE WHEN collection_status IN ('completed','all_collected','collected','handed_to_lab') THEN 1 ELSE 0 END) AS completed_today,
         SUM(CASE WHEN collection_status NOT IN ('completed','all_collected','collected','handed_to_lab','cancelled') THEN 1 ELSE 0 END) AS pending_today,
         (SELECT COUNT(*) FROM ip_technician_collection
          WHERE technician_id = ? AND collection_status IN ('completed','all_collected','collected','handed_to_lab')) AS total_done
       FROM ip_technician_collection
       WHERE technician_id = ? AND DATE(collection_date) = CURDATE()`,
      [technicianId, technicianId]
    );

    console.log(`✅ Profile loaded — ${profile.user_name} branch=${profile.branch_name}`);
    res.json({ success: true, profile, stats });
  } catch (e) {
    console.error('[getProfile]', e.message);
    res.status(500).json({ success: false, message: e.message });
  }
};

// ── GET /api/technicians/:technicianId/history ───────────────────────────────
exports.getHistory = async (req, res) => {
  const { technicianId } = req.params;
  console.log(`\n📋 [GET HISTORY] technician_id=${technicianId}`);
  try {
    console.log(`   [HISTORY] running SQL query...`);
    const [rows] = await db.execute(
      `SELECT
         tc.collection_id,
         tc.booking_id,
         tc.collection_status,
         tc.collection_date,
         tc.collection_address,
         tc.assigned_at,
         tc.collected_at,
         s.slot_label,
         b.city,
         b.postal_code,
         b.amount_paid,
         p.patient_name,
         p.patient_mobile
       FROM ip_technician_collection tc
       JOIN      ip_bookings b  ON b.booking_id = tc.booking_id
       LEFT JOIN ip_slots    s  ON s.slot_id    = b.slot_id
       LEFT JOIN ip_patients p  ON p.patient_id = b.client_id
       WHERE tc.technician_id = ?
         AND tc.collection_status IN ('completed','all_collected','collected','handed_to_lab','cancelled')
       ORDER BY tc.collection_date DESC
       LIMIT 50`,
      [technicianId]
    );
    console.log(`✅ [HISTORY] query done — ${rows.length} records`);
    if (rows.length > 0) console.log(`   [HISTORY] first row keys: ${Object.keys(rows[0]).join(', ')}`);
    res.json({ success: true, data: rows });
  } catch (e) {
    console.error(`❌ [HISTORY] SQL ERROR: ${e.message}`);
    console.error(`   [HISTORY] SQL code: ${e.code} errno: ${e.errno}`);
    res.status(500).json({ success: false, message: e.message, code: e.code });
  }
};

// ── POST /api/technicians/:technicianId/logout ────────────────────────────────
exports.logoutTechnician = async (req, res) => {
  const { technicianId } = req.params;
  console.log(`\n🚪 [LOGOUT] technician_id=${technicianId}`);
  
  // ✅ FIXED: Using transaction for atomicity
  const connection = await db.getConnection();
  try {
    await connection.beginTransaction();

    // Close active session
    await connection.query(
      `UPDATE ip_technician_sessions
       SET duty_end_at    = NOW(),
           session_status = 'completed',
           updated_at     = NOW()
       WHERE technician_id = ? AND session_status = 'active'`,
      [technicianId]
    );

    // Mark offline in live location
    await connection.query(
      `UPDATE ip_technician_live_location
       SET online_status = 'offline',
           task_status   = 'idle',
           socket_id     = NULL
       WHERE technician_id = ?`,
      [technicianId]
    );

    // Clear auth token in ip_users
    await connection.query(
      `UPDATE ip_users u
       JOIN ip_technicians t ON t.user_id = u.user_id
       SET u.user_auth_token    = NULL,
           u.user_token_expiry  = NULL,
           u.user_date_modified = NOW()
       WHERE t.technician_id = ?`,
      [technicianId]
    );

    await connection.commit();
    console.log(`✅ Technician ${technicianId} logged out — session closed`);
    res.json({ success: true, message: 'Logged out successfully' });
  } catch (e) {
    await connection.rollback();
    console.error('[logoutTechnician]', e.message);
    res.status(500).json({ success: false, message: e.message });
  } finally {
    connection.release();
  }
};

// ── GET /api/technicians/:technicianId/active-bookings ───────────────────────
// Returns today's assigned / en_route / arrived bookings so the dashboard can
// restore pending jobs after a logout + re-login.
exports.getActiveBookings = async (req, res) => {
  const { technicianId } = req.params;
  console.log(`\n📋 [GET ACTIVE BOOKINGS] technician_id=${technicianId}`);
  try {
    const [rows] = await db.execute(
      `SELECT
         tc.collection_id,
         tc.booking_id,
         tc.collection_status,
         DATE_FORMAT(tc.collection_date, '%Y-%m-%d') AS collection_date,
         tc.collection_address,
         tc.assigned_at,
         b.city,
         b.postal_code,
         b.amount_due            AS amount_paid,
         b.collection_latitude   AS patient_lat,
         b.collection_longitude  AS patient_lng,
         p.patient_name,
         p.patient_mobile,
         s.slot_label
       FROM ip_technician_collection tc
       JOIN      ip_bookings b  ON b.booking_id = tc.booking_id
       LEFT JOIN ip_slots    s  ON s.slot_id    = b.slot_id
       LEFT JOIN ip_patients p  ON p.patient_id = b.client_id
       WHERE tc.technician_id = ?
         AND tc.collection_status IN ('assigned','en_route','arrived','collected')
       ORDER BY tc.assigned_at ASC`,
      [technicianId]
    );
    console.log(`✅ Active bookings — ${rows.length} records`);
    res.json({ success: true, data: rows });
  } catch (e) {
    console.error('[getActiveBookings]', e.message);
    res.status(500).json({ success: false, message: e.message });
  }
};

// ── GET /api/technicians/:technicianId/slots ──────────────────────────────────
// Returns master slot definitions + which ones this technician has configured
exports.getSlots = async (req, res) => {
  const { technicianId } = req.params;
  console.log(`\n📅 [GET SLOTS] technician_id=${technicianId}`);
  try {
    const [masterSlots] = await db.execute(
      `SELECT slot_id,
              MIN(slot_label)       AS slot_label,
              MIN(slot_start)       AS slot_start,
              MIN(slot_end)         AS slot_end,
              MIN(slot_type)        AS slot_type
       FROM ip_slots
       WHERE slot_active = 1
       GROUP BY slot_id
       ORDER BY MIN(slot_start) ASC`
    );

    const [techSlots] = await db.execute(
      `SELECT slot_id, DATE_FORMAT(slot_date, '%Y-%m-%d') AS slot_date, max_bookings, booked_count, is_available, duration_minutes
       FROM ip_technician_slots
       WHERE technician_id = ? AND slot_date >= CURDATE()
       ORDER BY slot_date ASC`,
      [technicianId]
    );

    console.log(`✅ Master slots=${masterSlots.length} tech configs=${techSlots.length}`);
    res.json({ success: true, masterSlots, techSlots });
  } catch (e) {
    console.error('[getSlots]', e.message);
    res.status(500).json({ success: false, message: e.message });
  }
};

// ── PUT /api/technicians/:technicianId/slots ──────────────────────────────────
// Body: { slots: [{ date: 'YYYY-MM-DD', slot_ids: [1,2], durations: {"1":30,"2":15} }] }
// durations is optional; omitting it (or a specific slot_id key) skips interval generation.
exports.saveSlots = async (req, res) => {
  const { technicianId } = req.params;
  const { slots } = req.body;
  console.log(`\n📅 [SAVE SLOTS] technician_id=${technicianId} days=${slots?.length ?? 0}`);
  try {
    if (!Array.isArray(slots)) {
      return res.status(422).json({ success: false, message: 'slots must be an array' });
    }

    const [[tech]] = await db.execute(
      'SELECT branch_id FROM ip_technicians WHERE technician_id = ?',
      [technicianId]
    );
    if (!tech) return res.status(404).json({ success: false, message: 'Technician not found' });
    const branchId = tech.branch_id;

    const connection = await db.getConnection();
    try {
      await connection.beginTransaction();

      // Delete ip_avilable_slots tied to this tech's future slots before removing the slots
      await connection.query(
        `DELETE ias FROM ip_avilable_slots ias
         JOIN ip_technician_slots ts ON ts.technician_slot_id = ias.technician_slot_id
         WHERE ts.technician_id = ? AND ts.slot_date >= CURDATE()`,
        [technicianId]
      );

      // Remove all future technician slots then re-insert selected ones
      await connection.query(
        'DELETE FROM ip_technician_slots WHERE technician_id = ? AND slot_date >= CURDATE()',
        [technicianId]
      );

      let totalIntervals = 0;
      for (const day of slots) {
        if (!Array.isArray(day.slot_ids) || day.slot_ids.length === 0) continue;
        const durMap = day.durations ?? {}; // { "1": 30, "2": 15 } — keyed by slot_id string

        for (const slotId of day.slot_ids) {
          const durationMinutes = durMap[String(slotId)] ? Number(durMap[String(slotId)]) : null;

          const [ins] = await connection.query(
            `INSERT INTO ip_technician_slots
               (technician_id, slot_id, slot_date, branch_id, max_bookings, is_available, duration_minutes, created_by)
             VALUES (?, ?, ?, ?, 5, 1, ?, ?)`,
            [technicianId, slotId, day.date, branchId, durationMinutes, technicianId]
          );
          const techSlotId = ins.insertId;

          // Generate per-appointment-time rows in ip_avilable_slots when duration is set
          if (durationMinutes) {
            const [[slotDef]] = await connection.query(
              'SELECT slot_start, slot_end FROM ip_slots WHERE slot_id = ?',
              [slotId]
            );
            if (slotDef) {
              const times = _generateIntervals(slotDef.slot_start, slotDef.slot_end, durationMinutes);
              for (const t of times) {
                await connection.query(
                  `INSERT INTO ip_avilable_slots
                     (booking_type, technician_slot_id, slot_date, slot_time, is_available)
                   VALUES ('home', ?, ?, ?, 1)`,
                  [techSlotId, day.date, t]
                );
              }
              totalIntervals += times.length;
              console.log(`   slot_id=${slotId} date=${day.date} ${durationMinutes}min → ${times.length} intervals`);
            }
          }
        }
      }

      await connection.commit();
      const total = slots.reduce((s, d) => s + (d.slot_ids?.length ?? 0), 0);
      console.log(`✅ Slots saved — ${slots.length} day(s), ${total} slot entries, ${totalIntervals} intervals`);
      res.json({ success: true, message: 'Slots saved' });
    } catch (e) {
      await connection.rollback();
      throw e;
    } finally {
      connection.release();
    }
  } catch (e) {
    console.error('[saveSlots]', e.message);
    res.status(500).json({ success: false, message: e.message });
  }
};

// ── GET /api/technicians/stats ────────────────────────────────────────────────
// Returns total / online / offline technician counts.
// Uses ip_technician_live_location (one row per tech who has ever logged in).
exports.getStats = async (req, res) => {
  try {
    const [[row]] = await db.execute(`
      SELECT
        COUNT(*)                                                        AS total,
        SUM(CASE WHEN online_status = 'online'  THEN 1 ELSE 0 END)    AS online,
        SUM(CASE WHEN online_status = 'offline' THEN 1 ELSE 0 END)    AS offline
      FROM ip_technician_live_location
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
    // ✅ FIXED: Added indexing hint (ensure composite index exists in DB)
    // Recommended index: CREATE INDEX idx_live_online_location 
    // ON ip_technician_live_location(online_status, latitude, longitude, last_ping_at);
    const [rows] = await db.execute(`
      SELECT
        technician_id,
        socket_id,
        latitude,
        longitude,
        task_status,
        booking_id,
        last_ping_at,
        updated_at
      FROM ip_technician_live_location
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
        booking_id,
        latitude,
        longitude,
        last_ping_at,
        updated_at
      FROM ip_technician_live_location
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