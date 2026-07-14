// controllers/technicianController.js
//
// REST endpoints for technician availability and live-location data.
// Reads from ip_technician_live_location which is kept current by bookingSocket.js
// via INSERT … ON DUPLICATE KEY UPDATE on every technician_online event.

const db   = require('../config/db');
const fs   = require('fs');
const path = require('path');

const TECH_LOG = path.join(__dirname, '..', 'logs', 'technician.log');
function tlog(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false }).replace(',', '') + ' IST';
  const line = `[${ist}] ${msg}\n`;
  process.stdout.write(line);
  fs.appendFileSync(TECH_LOG, line, 'utf8');
}

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
  tlog(`[getHistory] START technician_id=${technicianId}`);
  try {
    tlog(`[getHistory] running SQL query...`);
    const [rows] = await db.execute(
      `SELECT
         tc.collection_id,
         tc.booking_id,
         tc.collection_status,
         tc.collection_date,
         tc.collection_address,
         tc.assigned_at,
         tc.collected_at,
         tc.completed_at,
         s.slot_label,
         TIME_FORMAT(avs.slot_time, '%h:%i %p') AS slot_time_formatted,
         b.city,
         b.postal_code,
         b.amount_paid,
         p.patient_name,
         p.patient_mobile
       FROM ip_technician_collection tc
       JOIN      ip_bookings          b   ON b.booking_id          = tc.booking_id
       LEFT JOIN ip_available_slots   avs ON avs.available_slot_id = b.available_slot_id
       LEFT JOIN ip_technician_slots  ts  ON ts.tech_slot_id       = avs.technician_slot_id
       LEFT JOIN ip_slots             s   ON s.slot_id             = COALESCE(ts.slot_id, b.slot_id)
       LEFT JOIN ip_patients          p   ON p.patient_id          = b.patient_id
       WHERE tc.technician_id = ?
         AND tc.collection_status IN (
           'completed','all_collected','collected',
           'handed_to_lab','sample_collected','collection_started',
           'cancelled'
         )
       ORDER BY COALESCE(tc.completed_at, tc.collected_at, tc.assigned_at) DESC
       LIMIT 100`,
      [technicianId]
    );
    tlog(`[getHistory] OK — ${rows.length} records returned`);
    if (rows.length > 0) tlog(`[getHistory] first row: booking_id=${rows[0].booking_id} status=${rows[0].collection_status} patient=${rows[0].patient_name}`);
    if (rows.length === 0) tlog(`[getHistory] WARNING — 0 rows: check technician_id=${technicianId} has completed/cancelled entries`);
    res.json({ success: true, data: rows });
  } catch (e) {
    tlog(`[getHistory] SQL ERROR: ${e.message} | code=${e.code} errno=${e.errno}`);
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
         b.booking_ref,
         b.patient_id,
         tc.collection_status,
         DATE_FORMAT(tc.collection_date, '%Y-%m-%d') AS collection_date,
         tc.collection_address,
         tc.assigned_at,
         b.city,
         b.postal_code,
         b.visit_group_id,
         b.amount_due            AS amount_paid,
         b.amount_paid           AS booking_amount_paid,
         b.payment_status,
         b.collection_latitude   AS patient_lat,
         b.collection_longitude  AS patient_lng,
         p.patient_name,
         p.patient_mobile,
         s.slot_label,
         TIME_FORMAT(avs.slot_time, '%h:%i %p') AS slot_time_formatted
       FROM ip_technician_collection tc
       JOIN      ip_bookings          b   ON b.booking_id          = tc.booking_id
       LEFT JOIN ip_available_slots   avs ON avs.available_slot_id = b.available_slot_id
       LEFT JOIN ip_technician_slots  ts  ON ts.tech_slot_id       = avs.technician_slot_id
       LEFT JOIN ip_slots             s   ON s.slot_id             = COALESCE(ts.slot_id, b.slot_id)
       LEFT JOIN ip_patients          p   ON p.patient_id          = b.patient_id
       WHERE tc.technician_id = ?
         AND tc.collection_status IN ('assigned','en_route','arrived','collection_started','sample_collected','otp_verified','collected')
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

      // Delete ip_available_slots tied to this tech's future slots before removing the slots
      await connection.query(
        `DELETE ias FROM ip_available_slots ias
         JOIN ip_technician_slots ts ON ts.tech_slot_id = ias.technician_slot_id
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
                  `INSERT INTO ip_available_slots
                     (booking_type, technician_slot_id, slot_date, slot_time, is_available, created_at)
                   VALUES ('home_collection', ?, ?, ?, 1, NOW())`,
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


// ── POST /api/technicians/add-customer ────────────────────────────────────────
// Called by the technician app to add a walk-in patient at the same location.
// Inherits date/address/coords from the parent booking so the new job appears
// ── POST /api/technicians/collect-payment ─────────────────────────────────────
// Records a payment collected on-site by the technician and marks the booking paid
exports.collectPayment = async (req, res) => {
  const technicianId = req.user.id;
  const { bookingId, razorpayPaymentId, amount } = req.body;

  if (!bookingId || !razorpayPaymentId || !amount) {
    return res.status(400).json({ success: false, message: 'bookingId, razorpayPaymentId and amount are required' });
  }

  try {
    // Single JOIN UPDATE — verifies technician assignment and marks paid atomically
    const [result] = await db.execute(
      `UPDATE ip_bookings b
       INNER JOIN ip_technician_collection tc ON tc.booking_id = b.booking_id
       SET b.payment_status = 'paid', b.amount_paid = b.amount_paid + ?, b.amount_due = 0, b.updated_at = NOW()
       WHERE b.booking_id = ? AND tc.technician_id = ?`,
      [amount, bookingId, technicianId]
    );

    if (result.affectedRows === 0) {
      console.warn(`⚠️  collectPayment — no rows updated for booking_id=${bookingId} technician_id=${technicianId}`);
      return res.status(404).json({ success: false, message: 'Booking not found or not assigned to this technician' });
    }

    // Update payment transaction record if one exists (best-effort, no-op if absent)
    await db.execute(
      `UPDATE ip_payment_transactions
       SET payment_status = 'paid', transaction_status = 'completed',
           amount_paid = ?, amount_due = 0,
           gateway_transaction_id = ?, gateway_status = 'success',
           paid_at = NOW(), updated_at = NOW()
       WHERE booking_id = ? AND (is_refund = 0 OR is_refund IS NULL)`,
      [amount, razorpayPaymentId, bookingId]
    );

    // Cascade paid status to any sibling bookings linked via visit_group_id
    await db.execute(
      `UPDATE ip_bookings sib
       JOIN ip_bookings parent ON parent.booking_id = ? AND parent.visit_group_id IS NOT NULL
                               AND sib.visit_group_id = parent.visit_group_id
       SET sib.payment_status = 'paid', sib.amount_paid = sib.total_amount, sib.amount_due = 0, sib.updated_at = NOW()
       WHERE sib.booking_id != ?`,
      [bookingId, bookingId]
    );
    await db.execute(
      `UPDATE ip_payment_transactions pt
       JOIN ip_bookings sib ON sib.booking_id = pt.booking_id
       JOIN ip_bookings parent ON parent.booking_id = ? AND parent.visit_group_id IS NOT NULL
                               AND sib.visit_group_id = parent.visit_group_id
       SET pt.payment_status = 'paid', pt.transaction_status = 'completed',
           pt.amount_paid = pt.net_amount, pt.amount_due = 0,
           pt.gateway_transaction_id = ?, pt.gateway_status = 'success',
           pt.paid_at = NOW(), pt.updated_at = NOW()
       WHERE sib.booking_id != ? AND (pt.is_refund = 0 OR pt.is_refund IS NULL)`,
      [bookingId, razorpayPaymentId, bookingId]
    );

    console.log(`✅ collectPayment — booking_id=${bookingId} paid ₹${amount} by technician_id=${technicianId}`);
    res.json({ success: true });
  } catch (err) {
    console.error('❌ collectPayment FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// in the same slot without requiring a fresh booking flow on the patient side.
exports.addCustomerBooking = async (req, res) => {
  const technicianId = req.user.id;
  const {
    parentBookingId,
    name, mobile, email, dob, age, gender, relation, healthNotes,
    tests = [],
  } = req.body;

  if (!parentBookingId || !name || !mobile) {
    return res.status(400).json({ success: false, message: 'parentBookingId, name and mobile are required' });
  }

  const conn = await db.getConnection();
  try {
    await conn.beginTransaction();

    // 1. Inherit context from the parent booking
    const [[parent]] = await conn.execute(
      `SELECT client_id, booking_date, collection_address, postal_code, city,
              collection_latitude, collection_longitude, available_slot_id
       FROM ip_bookings WHERE booking_id = ? AND deleted_at IS NULL LIMIT 1`,
      [parentBookingId]
    );
    if (!parent) {
      await conn.rollback();
      return res.status(404).json({ success: false, message: 'Parent booking not found' });
    }

    // 2. Find or create patient by mobile + client
    const [[existing]] = await conn.execute(
      `SELECT patient_id FROM ip_patients
       WHERE patient_mobile = ? AND client_id = ? AND deleted_at IS NULL LIMIT 1`,
      [mobile, parent.client_id]
    );

    let patientId;
    if (existing) {
      patientId = existing.patient_id;
      await conn.execute(
        `UPDATE ip_patients
         SET patient_name=?, patient_email=?, patient_dob=?, patient_age=?,
             patient_gender=?, patient_relation=?, health_conditions=?, updated_at=NOW()
         WHERE patient_id=?`,
        [name, email || null, dob || null, age || null,
         gender || null, relation || null, healthNotes || null, patientId]
      );
    } else {
      const [pRes] = await conn.execute(
        `INSERT INTO ip_patients
           (client_id, patient_name, patient_mobile, patient_email, patient_dob,
            patient_age, patient_gender, patient_relation, health_conditions, created_by)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [parent.client_id, name, mobile, email || null, dob || null,
         age || null, gender || null, relation || null, healthNotes || null,
         `technician_${technicianId}`]
      );
      patientId = pRes.insertId;
    }

    // 3. Link patient to the PARENT booking (not a new booking)
    const [[alreadyLinked]] = await conn.execute(
      `SELECT 1 FROM ip_patient_bookings WHERE booking_id = ? AND patient_id = ? LIMIT 1`,
      [parentBookingId, patientId]
    );
    if (!alreadyLinked) {
      await conn.execute(
        `INSERT INTO ip_patient_bookings (booking_id, patient_id, created_at) VALUES (?, ?, NOW())`,
        [parentBookingId, patientId]
      );
    }

    // 4. Resolve products and add as items under the PARENT booking
    let totalAmount = 0;
    for (const t of tests) {
      if (!t.productId) continue;
      const [[prod]] = await conn.execute(
        `SELECT product_id, product_name, product_price FROM ip_products
         WHERE product_id = ? AND product_active = 1 LIMIT 1`,
        [t.productId]
      );
      if (prod) {
        const price = parseFloat(prod.product_price ?? 0) || 0;
        totalAmount += price;
        await conn.execute(
          `INSERT INTO ip_booking_items
             (booking_id, product_id, product_name_snapshot, patient_id, unit_price, final_price, created_at)
           VALUES (?, ?, ?, ?, ?, ?, NOW())`,
          [parentBookingId, prod.product_id, prod.product_name, patientId, price, price]
        );
      }
    }

    // 5. Update parent booking total so it reflects all patients' tests
    if (totalAmount > 0) {
      await conn.execute(
        `UPDATE ip_bookings
         SET total_amount = total_amount + ?, amount_due = amount_due + ?
         WHERE booking_id = ?`,
        [totalAmount, totalAmount, parentBookingId]
      );
    }

    await conn.commit();
    console.log(`✅ addCustomerBooking — patient_id=${patientId} attached to booking_id=${parentBookingId}`);
    res.status(201).json({
      success:     true,
      patientId,
      patientName: name,
      totalAmount,
    });
  } catch (err) {
    await conn.rollback();
    console.error('❌ addCustomerBooking FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error', detail: err.message });
  } finally {
    conn.release();
  }
};

// ── GET /api/technicians/patient-lookup ───────────────────────────────────────
// Search for an existing patient by mobile within the booking's client scope.
// Returns { patient } or { patient: null } — never leaks cross-client data.
exports.lookupPatient = async (req, res) => {
  const { mobile, bookingId } = req.query;
  if (!mobile || !bookingId) {
    return res.status(400).json({ success: false, message: 'mobile and bookingId are required' });
  }
  try {
    const [[booking]] = await db.execute(
      `SELECT client_id FROM ip_bookings WHERE booking_id = ? AND deleted_at IS NULL LIMIT 1`,
      [bookingId]
    );
    if (!booking) {
      return res.status(404).json({ success: false, message: 'Booking not found' });
    }
    const [[patient]] = await db.execute(
      `SELECT patient_id, patient_name, patient_mobile, patient_email,
              patient_dob, patient_age, patient_gender
       FROM ip_patients
       WHERE patient_mobile = ? AND client_id = ? AND deleted_at IS NULL LIMIT 1`,
      [mobile, booking.client_id]
    );
    res.json({ success: true, patient: patient || null });
  } catch (err) {
    console.error('❌ lookupPatient FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── POST /api/technicians/add-visit-member ────────────────────────────────────
// On-site: technician adds a family member at the same address as a sibling
// booking. Creates a NEW confirmed booking linked via visit_group_id — bypasses
// the normal dispatch flow entirely. Inserts ip_technician_collection directly
// with collection_status='arrived' so the job is immediately manageable.
exports.addVisitMember = async (req, res) => {
  const technicianId = req.user.id;
  const {
    parentBookingId,
    patientId: existingPatientId,
    name, mobile, email, dob, age, gender, relation, healthNotes,
    tests = [],
  } = req.body;

  if (!parentBookingId) {
    return res.status(400).json({ success: false, message: 'parentBookingId is required' });
  }
  if (!existingPatientId && (!name || !mobile)) {
    return res.status(400).json({ success: false, message: 'Either patientId or (name + mobile) is required' });
  }

  const conn = await db.getConnection();
  try {
    await conn.beginTransaction();

    // Step 1: Fetch parent context + verify this technician is assigned to it
    const [[parent]] = await conn.execute(
      `SELECT b.client_id, b.booking_date, b.collection_address, b.postal_code,
              b.city, b.collection_latitude, b.collection_longitude,
              b.available_slot_id, b.visit_group_id
       FROM ip_bookings b
       INNER JOIN ip_technician_collection tc ON tc.booking_id = b.booking_id
       WHERE b.booking_id = ? AND tc.technician_id = ? AND b.deleted_at IS NULL LIMIT 1`,
      [parentBookingId, technicianId]
    );
    if (!parent) {
      await conn.rollback();
      return res.status(404).json({ success: false, message: 'Parent booking not found or not assigned to you' });
    }

    // Step 2: Find or create patient
    let patientId = existingPatientId || null;
    if (!patientId) {
      const [[existing]] = await conn.execute(
        `SELECT patient_id FROM ip_patients
         WHERE patient_mobile = ? AND client_id = ? AND deleted_at IS NULL LIMIT 1`,
        [mobile, parent.client_id]
      );
      if (existing) {
        patientId = existing.patient_id;
        await conn.execute(
          `UPDATE ip_patients
           SET patient_name=?, patient_email=?, patient_dob=?, patient_age=?,
               patient_gender=?, patient_relation=?, health_conditions=?, updated_at=NOW()
           WHERE patient_id=?`,
          [name, email || null, dob || null, age || null,
           gender || null, relation || null, healthNotes || null, patientId]
        );
      } else {
        const [pRes] = await conn.execute(
          `INSERT INTO ip_patients
             (client_id, patient_name, patient_mobile, patient_email, patient_dob,
              patient_age, patient_gender, patient_relation, health_conditions, created_by)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          [parent.client_id, name, mobile, email || null, dob || null,
           age || null, gender || null, relation || null, healthNotes || null,
           `technician_${technicianId}`]
        );
        patientId = pRes.insertId;
      }
    }

    // Step 2b: Fetch patient_id_ref for linking records correctly
    let patientIdRef = null;
    const [[patRefRow]] = await conn.execute(
      `SELECT patient_id_ref FROM ip_patients WHERE patient_id = ? LIMIT 1`, [patientId]
    );
    if (patRefRow?.patient_id_ref) patientIdRef = patRefRow.patient_id_ref;

    // Step 3: Determine visit_group_id — backfill parent if it has none yet
    let visitGroupId = parent.visit_group_id;
    if (!visitGroupId) {
      visitGroupId = `VG${Date.now()}`;
      await conn.execute(
        `UPDATE ip_bookings SET visit_group_id = ?, updated_at = NOW() WHERE booking_id = ?`,
        [visitGroupId, parentBookingId]
      );
    }

    // Step 4: Resolve products and compute total
    let totalAmount = 0;
    const resolvedProducts = [];
    for (const t of tests) {
      if (!t.productId) continue;
      const [[prod]] = await conn.execute(
        `SELECT product_id, product_name, product_price, offer, discount_percent
         FROM ip_products WHERE product_id = ? LIMIT 1`,
        [t.productId]
      );
      if (prod) {
        // Use client-provided final_price when valid (accounts for offers/discounts).
        // Fallback: compute final price from DB same way the catalogue does.
        let price;
        if (t.price && parseFloat(t.price) > 0) {
          price = parseFloat(t.price);
        } else {
          const original     = parseFloat(prod.product_price ?? 0) || 0;
          const hasOffer     = prod.offer === 'yes' || prod.offer === '1' || prod.offer == 1;
          const discountPct  = hasOffer ? (parseFloat(prod.discount_percent) || 0) : 0;
          price = hasOffer && discountPct > 0
            ? Math.round(original * (1 - discountPct / 100) * 100) / 100
            : original;
        }
        totalAmount += price;
        resolvedProducts.push({ product_id: prod.product_id, product_name: prod.product_name, price });
      }
    }

    // Step 5: INSERT new booking — status='confirmed' bypasses dispatch entirely
    const bookingRef = `BC${Date.now()}`;
    const txnRef    = `TXN${Date.now()}${Math.random().toString(36).slice(2, 5).toUpperCase()}`;
    const [bRes] = await conn.execute(
      `INSERT INTO ip_bookings
         (booking_ref, client_id, branch_id, booking_date, lab_slot_id, available_slot_id,
          booking_type, status, total_amount, discount_amount,
          amount_paid, amount_due, source_channel, notes,
          collection_address, postal_code, city,
          collection_latitude, collection_longitude,
          patient_id, patient_id_ref, product_id,
          payment_status, visit_group_id, start_datetime, end_datetime, created_by, created_at)
       VALUES (?, ?, NULL, ?, NULL, ?, 'home_collection', 'confirmed', ?, 0, 0, ?,
               'technician_app', NULL, ?, ?, ?, ?, ?, ?, ?, 0, 'unpaid', ?, NOW(), NOW(), ?, NOW())`,
      [bookingRef, parent.client_id, parent.booking_date, parent.available_slot_id || null,
       totalAmount, totalAmount,
       parent.collection_address, parent.postal_code, parent.city,
       parent.collection_latitude, parent.collection_longitude,
       patientId, patientIdRef,
       visitGroupId, technicianId]
    );
    const newBookingId = bRes.insertId;

    // Step 6: Link patient to new booking
    await conn.execute(
      `INSERT INTO ip_patient_bookings (booking_id, patient_id, patient_ref, created_at) VALUES (?, ?, ?, NOW())`,
      [newBookingId, patientId, patientIdRef]
    );

    // Step 7: INSERT items into sibling booking (lab tracking) AND into parent booking (payment display)
    for (const prod of resolvedProducts) {
      await conn.execute(
        `INSERT INTO ip_booking_items
           (booking_id, product_id, product_name_snapshot, patient_id, unit_price, final_price, created_at)
         VALUES (?, ?, ?, ?, ?, ?, NOW())`,
        [newBookingId, prod.product_id, prod.product_name, patientId, prod.price, prod.price]
      );
      // Mirror to parent so the technician's payment screen sees the full combined total
      await conn.execute(
        `INSERT INTO ip_booking_items
           (booking_id, product_id, product_name_snapshot, patient_id, unit_price, final_price, created_at)
         VALUES (?, ?, ?, ?, ?, ?, NOW())`,
        [parentBookingId, prod.product_id, prod.product_name, patientId, prod.price, prod.price]
      );
    }

    // Step 7b: Bump parent booking totals so collect-payment amount is correct
    if (totalAmount > 0) {
      await conn.execute(
        `UPDATE ip_bookings SET total_amount = total_amount + ?, amount_due = amount_due + ?, updated_at = NOW()
         WHERE booking_id = ?`,
        [totalAmount, totalAmount, parentBookingId]
      );
    }

    // Step 8: INSERT payment transaction (pay-later, unpaid)
    await conn.execute(
      `INSERT INTO ip_payment_transactions
         (transaction_ref, booking_id, patient_id, payment_type,
          gross_amount, discount_amount, net_amount, amount_paid, amount_due,
          currency, payment_status, transaction_status, is_refund,
          gateway_transaction_id, gateway_order_id, gateway_status, paid_at)
       VALUES (?, ?, ?, 'PAY_LATER', ?, 0, ?, 0, ?, 'INR', 'pending', 'pending', 0, NULL, NULL, NULL, NULL)`,
      [txnRef, newBookingId, patientId, totalAmount, totalAmount, totalAmount]
    );

    await conn.commit();
    console.log(`✅ addVisitMember — new booking_id=${newBookingId} ref=${bookingRef} parent=${parentBookingId} visit_group=${visitGroupId}`);
    res.status(201).json({
      success:      true,
      newBookingId,
      bookingRef,
      patientId,
      visitGroupId,
      totalAmount,
    });
  } catch (err) {
    await conn.rollback();
    const detail = err.sqlMessage || err.message || String(err);
    console.error('❌ addVisitMember FAILED:', detail);
    res.status(500).json({ success: false, message: 'Server error', detail });
  } finally {
    conn.release();
  }
};

// ── GET /api/technicians/booking-family ───────────────────────────────────────
// Returns patients that have been in previous bookings alongside the primary
// patient of this booking — used to display "family member" cards in the sheet.
exports.getBookingFamily = async (req, res) => {
  const technicianId = req.user?.id;
  const bookingId    = parseInt(req.query.bookingId);
  if (!bookingId) {
    return res.status(400).json({ success: false, message: 'bookingId is required' });
  }
  try {
    const [[booking]] = await db.execute(
      `SELECT b.patient_id, b.client_id
       FROM ip_bookings b
       INNER JOIN ip_technician_collection tc ON tc.booking_id = b.booking_id
       WHERE b.booking_id = ? AND tc.technician_id = ? AND b.deleted_at IS NULL LIMIT 1`,
      [bookingId, technicianId]
    );
    if (!booking) {
      return res.status(404).json({ success: false, message: 'Booking not found' });
    }

    const [members] = await db.execute(
      `SELECT DISTINCT p.patient_id, p.patient_name, p.patient_mobile,
                       p.patient_relation, p.patient_age, p.patient_gender
       FROM ip_patient_bookings pb
       JOIN ip_patients p ON p.patient_id = pb.patient_id
       WHERE pb.booking_id IN (
         SELECT pb2.booking_id FROM ip_patient_bookings pb2 WHERE pb2.patient_id = ?
       )
       AND pb.patient_id != ?
       AND p.client_id = ?
       AND p.deleted_at IS NULL
       ORDER BY p.patient_name ASC
       LIMIT 10`,
      [booking.patient_id, booking.patient_id, booking.client_id]
    );

    res.json({ success: true, members });
  } catch (err) {
    console.error('❌ getBookingFamily FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};