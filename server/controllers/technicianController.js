// controllers/technicianController.js
//
// REST endpoints for technician availability and live-location data.
// Reads from ip_technician_live_location which is kept current by bookingSocket.js
// via INSERT … ON DUPLICATE KEY UPDATE on every technician_online event.

const db   = require('../config/db');
const fs   = require('fs');
const path = require('path');
const sms  = require('../utils/sms');

const TECH_LOG = path.join(__dirname, '..', 'logs', 'technician.log');
function tlog(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false }).replace(',', '') + ' IST';
  const line = `[${ist}] ${msg}\n`;
  process.stdout.write(line);
  fs.appendFileSync(TECH_LOG, line, 'utf8');
}

const OTP_LOG = path.join(__dirname, '..', 'logs', 'otpinfo.log');
function otpLog(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false }).replace(',', '') + ' IST';
  const line = `[${ist}] ${msg}\n`;
  process.stdout.write(line);
  try {
    const logsDir = path.join(__dirname, '..', 'logs');
    if (!fs.existsSync(logsDir)) fs.mkdirSync(logsDir, { recursive: true });
    fs.appendFileSync(OTP_LOG, line, 'utf8');
  } catch (_) {}
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
         TIME_FORMAT(avs.slot_time, '%h:%i %p') AS slot_time_formatted,
         CASE WHEN EXISTS(
           SELECT 1 FROM ip_booking_items bi
           JOIN ip_products pr ON pr.product_id = bi.product_id
           WHERE bi.booking_id = tc.booking_id
             AND pr.document_required IN (1, '1', 'yes')
         ) THEN 1 ELSE 0 END AS doc_required,
         CASE WHEN EXISTS(
           SELECT 1 FROM ip_booking_documents bd
           WHERE bd.booking_id = tc.booking_id
             AND bd.file_description = 'prescription'
         ) THEN 1 ELSE 0 END AS doc_verified
       FROM ip_technician_collection tc
       JOIN      ip_bookings          b   ON b.booking_id          = tc.booking_id
       LEFT JOIN ip_available_slots   avs ON avs.available_slot_id = b.available_slot_id
       LEFT JOIN ip_technician_slots  ts  ON ts.tech_slot_id       = avs.technician_slot_id
       LEFT JOIN ip_slots             s   ON s.slot_id             = COALESCE(ts.slot_id, b.slot_id)
       LEFT JOIN ip_patients          p   ON p.patient_id          = b.patient_id
       WHERE tc.technician_id = ?
         AND tc.collection_status IN ('assigned','en_route','arrived','collection_started','sample_collected','otp_verified','collected')
         AND (
           b.visit_group_id IS NULL
           OR tc.booking_id = (
             SELECT MIN(b2.booking_id)
             FROM ip_bookings b2
             WHERE b2.visit_group_id = b.visit_group_id
               AND b2.deleted_at IS NULL
           )
         )
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

    // For today (IST), reject slot_ids whose slot_end has already been reached.
    // A slot is still valid while any appointment time within it remains in the future.
    // Protects against raw API calls (Postman, modified clients) sending past slots.
    // Tomorrow and future dates are skipped — all their slots remain editable.
    const todayIST = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
    const istNow   = new Date(Date.now() + 5.5 * 60 * 60 * 1000); // UTC → IST
    const nowISTMinutes = istNow.getUTCHours() * 60 + istNow.getUTCMinutes();

    for (const day of slots) {
      if (day.date !== todayIST || !Array.isArray(day.slot_ids) || day.slot_ids.length === 0) continue;
      const placeholders = day.slot_ids.map(() => '?').join(',');
      const [slotDefs] = await db.query(
        `SELECT slot_id, slot_end FROM ip_slots WHERE slot_id IN (${placeholders})`,
        day.slot_ids
      );
      const validIds = new Set(
        slotDefs
          .filter(r => {
            const [h = 0, m = 0] = String(r.slot_end).split(':').map(Number);
            return (h * 60 + m) > nowISTMinutes; // slot_end strictly after now → still valid
          })
          .map(r => r.slot_id)
      );
      const removed = day.slot_ids.filter(id => !validIds.has(id));
      day.slot_ids  = day.slot_ids.filter(id =>  validIds.has(id));
      if (day.durations) removed.forEach(id => delete day.durations[String(id)]);
      if (removed.length > 0) {
        console.log(`[saveSlots] Rejected ${removed.length} past slot(s) for today: [${removed}] nowIST=${istNow.getUTCHours()}:${String(istNow.getUTCMinutes()).padStart(2, '0')}`);
      }
    }

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

          // When duration is set, calculate interval count first so max_bookings
          // reflects actual capacity rather than a hardcoded guess.
          let times = [];
          let maxBookings = 5; // sensible default for no-duration slots
          if (durationMinutes) {
            const [[slotDef]] = await connection.query(
              'SELECT slot_start, slot_end FROM ip_slots WHERE slot_id = ?',
              [slotId]
            );
            if (slotDef) {
              times = _generateIntervals(slotDef.slot_start, slotDef.slot_end, durationMinutes);
              maxBookings = times.length || 1; // at least 1 to avoid zero-cap edge case
            }
          }

          const [ins] = await connection.query(
            `INSERT INTO ip_technician_slots
               (technician_id, slot_id, slot_date, branch_id, max_bookings, is_available, duration_minutes, created_by)
             VALUES (?, ?, ?, ?, ?, 1, ?, ?)`,
            [technicianId, slotId, day.date, branchId, maxBookings, durationMinutes, technicianId]
          );
          const techSlotId = ins.insertId;

          // Insert per-appointment-time rows when duration is set (times already computed above)
          if (durationMinutes && times.length > 0) {
            for (const t of times) {
              await connection.query(
                `INSERT INTO ip_available_slots
                   (booking_type, technician_slot_id, slot_date, slot_time, is_available, created_at)
                 VALUES ('home_collection', ?, ?, ?, 1, NOW())`,
                [techSlotId, day.date, t]
              );
            }
            totalIntervals += times.length;
            console.log(`   slot_id=${slotId} date=${day.date} ${durationMinutes}min → ${times.length} intervals, max_bookings=${maxBookings}`);
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
// Records a payment collected by a technician on-site — supports both full
// and partial amounts, and either Razorpay or Cash. amount may be less than
// the booking's remaining balance: the row is left with payment_status =
// 'partial' and the real amount_due, rather than always forcing amount_due
// to 0 — the remainder can be collected later in a follow-up call.
exports.collectPayment = async (req, res) => {
  const technicianId  = req.user.id;
  const { bookingId, razorpayPaymentId, amount, paymentMethod = 'RAZORPAY' } = req.body;

  if (!bookingId || !amount) {
    return res.status(400).json({ success: false, message: 'bookingId and amount are required' });
  }
  if (paymentMethod === 'RAZORPAY' && !razorpayPaymentId) {
    return res.status(400).json({ success: false, message: 'razorpayPaymentId is required for Razorpay payments' });
  }

  try {
    // Verify this technician owns the booking — either directly (parent, via
    // ip_technician_collection) or as a sibling of a booking they own (same
    // visit_group_id) — and read the current totals in the same query.
    const [[booking]] = await db.execute(
      `SELECT b.booking_id, b.total_amount, b.amount_paid
       FROM ip_bookings b
       WHERE b.booking_id = ?
         AND (
           EXISTS (SELECT 1 FROM ip_technician_collection tc WHERE tc.booking_id = b.booking_id AND tc.technician_id = ?)
           OR (b.visit_group_id IS NOT NULL AND EXISTS (
             SELECT 1 FROM ip_bookings parent
             INNER JOIN ip_technician_collection tc ON tc.booking_id = parent.booking_id AND tc.technician_id = ?
             WHERE parent.visit_group_id = b.visit_group_id
           ))
         )`,
      [bookingId, technicianId, technicianId]
    );

    if (!booking) {
      console.warn(`⚠️  collectPayment — booking_id=${bookingId} not found or not assigned to technician_id=${technicianId}`);
      return res.status(404).json({ success: false, message: 'Booking not found or not assigned to this technician' });
    }

    const totalAmount      = parseFloat(booking.total_amount) || 0;
    const currentPaid      = parseFloat(booking.amount_paid) || 0;
    const newAmountPaid    = currentPaid + Number(amount);
    const newAmountDue     = Math.max(0, totalAmount - newAmountPaid);
    const newPaymentStatus = newAmountDue <= 0 ? 'paid' : 'partial';

    await db.execute(
      `UPDATE ip_bookings
       SET payment_status = ?, amount_paid = ?, amount_due = ?, updated_at = NOW()
       WHERE booking_id = ?`,
      [newPaymentStatus, newAmountPaid, newAmountDue, bookingId]
    );

    // Update payment transaction record (best-effort — works for both parent and sibling bookings)
    await db.execute(
      `UPDATE ip_payment_transactions
       SET payment_status = ?, transaction_status = ?,
           payment_type = ?, payment_mode = ?,
           amount_paid = ?, amount_due = ?, is_partial = ?,
           gateway_transaction_id = ?, gateway_status = ?,
           collected_by = ?, paid_at = NOW(), updated_at = NOW()
       WHERE booking_id = ? AND (is_refund = 0 OR is_refund IS NULL)`,
      [
        newPaymentStatus, newPaymentStatus === 'paid' ? 'completed' : 'partial',
        paymentMethod, paymentMethod,
        newAmountPaid, newAmountDue, newPaymentStatus === 'paid' ? 0 : 1,
        paymentMethod === 'RAZORPAY' ? razorpayPaymentId : null,
        paymentMethod === 'RAZORPAY' ? 'captured' : 'cash_collected',
        technicianId, bookingId,
      ]
    );

    console.log(`✅ collectPayment — booking_id=${bookingId} method=${paymentMethod} +₹${amount} → paid=₹${newAmountPaid} due=₹${newAmountDue} status=${newPaymentStatus} by technician_id=${technicianId}`);
    res.json({ success: true, amountPaid: newAmountPaid, amountDue: newAmountDue, paymentStatus: newPaymentStatus });
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
// On-site: technician adds one or more family members (up to 4) as sibling
// bookings linked via visit_group_id. Bypasses socket dispatch — technician is
// physically present, so each sibling is directly assigned and marked 'arrived'.
// Body: { parentBookingId, members: [{ patientId?, name, mobile, dob?, age?,
//   gender?, relation?, healthNotes?, tests: [{productId, price?}] }] }
exports.addVisitMember = async (req, res) => {
  const technicianId   = req.user.id;
  const { parentBookingId } = req.body;

  // Accept members[] array; also handle legacy single-member body for compat
  let members = req.body.members;
  if (!members && (req.body.name || req.body.patientId)) {
    const { patientId, name, mobile, email, dob, age, gender, relation, healthNotes, tests } = req.body;
    members = [{ patientId, name, mobile, email, dob, age, gender, relation, healthNotes, tests: tests || [] }];
  }

  if (!parentBookingId) {
    return res.status(400).json({ success: false, message: 'parentBookingId is required' });
  }
  if (!Array.isArray(members) || members.length === 0) {
    return res.status(400).json({ success: false, message: 'members array (1–4) is required' });
  }
  if (members.length > 4) {
    return res.status(400).json({ success: false, message: 'Maximum 4 members per visit' });
  }
  for (const m of members) {
    if (!m.patientId && (!m.name || !m.mobile)) {
      return res.status(400).json({ success: false, message: 'Each member needs patientId or (name + mobile)' });
    }
  }

  const conn = await db.getConnection();
  try {
    await conn.beginTransaction();

    // Step 1: Fetch parent context + verify this technician is assigned to it
    const [[parent]] = await conn.execute(
      `SELECT b.client_id, b.branch_id, b.booking_date, b.collection_address, b.postal_code,
              b.city, b.collection_latitude, b.collection_longitude,
              b.available_slot_id, b.visit_group_id, tc.slot_id
       FROM ip_bookings b
       INNER JOIN ip_technician_collection tc ON tc.booking_id = b.booking_id
       WHERE b.booking_id = ? AND tc.technician_id = ? AND b.deleted_at IS NULL LIMIT 1`,
      [parentBookingId, technicianId]
    );
    if (!parent) {
      await conn.rollback();
      return res.status(404).json({ success: false, message: 'Parent booking not found or not assigned to you' });
    }

    // Fetch technician display name for snapshot storage
    const [[techRow]] = await conn.execute(
      `SELECT u.user_name FROM ip_technicians t
       JOIN ip_users u ON u.user_id = t.user_id
       WHERE t.technician_id = ? LIMIT 1`,
      [technicianId]
    );
    const technicianName = techRow?.user_name || null;

    // Backfill parent booking technician snapshot if not already set
    await conn.execute(
      `UPDATE ip_bookings SET technician_id = ?, technician_name = ?, updated_at = NOW()
       WHERE booking_id = ? AND technician_id IS NULL`,
      [technicianId, technicianName, parentBookingId]
    );

    // Step 2: Determine visit_group_id — backfill parent if it has none yet
    let visitGroupId = parent.visit_group_id;
    if (!visitGroupId) {
      visitGroupId = `VG${Date.now()}`;
      await conn.execute(
        `UPDATE ip_bookings SET visit_group_id = ?, updated_at = NOW() WHERE booking_id = ?`,
        [visitGroupId, parentBookingId]
      );
    }

    // Step 3: Process each member in the same transaction
    const results = [];
    let refSeq = 0;

    for (const member of members) {
      refSeq++;
      const {
        patientId: existingPatientId,
        name, mobile, email, dob, age, gender, relation, healthNotes,
        tests = [],
      } = member;

      // Find or create patient
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

      // Fetch patient_id_ref for linking records correctly
      let patientIdRef = null;
      const [[patRefRow]] = await conn.execute(
        `SELECT patient_id_ref FROM ip_patients WHERE patient_id = ? LIMIT 1`, [patientId]
      );
      if (patRefRow?.patient_id_ref) patientIdRef = patRefRow.patient_id_ref;

      // Resolve products and compute total
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
          let price;
          if (t.price && parseFloat(t.price) > 0) {
            price = parseFloat(t.price);
          } else {
            const original    = parseFloat(prod.product_price ?? 0) || 0;
            const hasOffer    = prod.offer === 'yes' || prod.offer === '1' || prod.offer == 1;
            const discountPct = hasOffer ? (parseFloat(prod.discount_percent) || 0) : 0;
            price = hasOffer && discountPct > 0
              ? Math.round(original * (1 - discountPct / 100) * 100) / 100
              : original;
          }
          totalAmount += price;
          resolvedProducts.push({ product_id: prod.product_id, product_name: prod.product_name, price });
        }
      }

      // INSERT new booking — status='confirmed', technician directly assigned
      const bookingRef = `BC${Date.now()}${String(refSeq).padStart(2, '0')}`;
      const txnRef     = `TXN${Date.now()}${String(refSeq)}${Math.random().toString(36).slice(2, 4).toUpperCase()}`;
      const [bRes] = await conn.execute(
        `INSERT INTO ip_bookings
           (booking_ref, client_id, branch_id, booking_date, lab_slot_id, available_slot_id,
            booking_type, status, total_amount, discount_amount,
            amount_paid, amount_due, source_channel, notes,
            collection_address, postal_code, city,
            collection_latitude, collection_longitude,
            patient_id, patient_id_ref, product_id,
            payment_status, visit_group_id, technician_id, technician_name,
            start_datetime, end_datetime, created_by, created_at)
         VALUES (?, ?, ?, ?, NULL, ?, 'home_collection', 'confirmed', ?, 0, 0, ?,
                 'technician_app', NULL, ?, ?, ?, ?, ?, ?, ?, 0, 'unpaid', ?, ?, ?,
                 NOW(), NOW(), ?, NOW())`,
        [bookingRef, parent.client_id, parent.branch_id || null, parent.booking_date,
         parent.available_slot_id || null, totalAmount, totalAmount,
         parent.collection_address, parent.postal_code, parent.city,
         parent.collection_latitude, parent.collection_longitude,
         patientId, patientIdRef,
         visitGroupId, technicianId, technicianName,
         technicianId]
      );
      const newBookingId = bRes.insertId;

      // Link patient to new booking
      await conn.execute(
        `INSERT INTO ip_patient_bookings (booking_id, patient_id, patient_ref, created_at) VALUES (?, ?, ?, NOW())`,
        [newBookingId, patientId, patientIdRef]
      );

      // INSERT booking items
      for (const prod of resolvedProducts) {
        await conn.execute(
          `INSERT INTO ip_booking_items
             (booking_id, product_id, product_name_snapshot, patient_id, unit_price, final_price, created_at)
           VALUES (?, ?, ?, ?, ?, ?, NOW())`,
          [newBookingId, prod.product_id, prod.product_name, patientId, prod.price, prod.price]
        );
      }

      // INSERT payment transaction (unpaid — collected later via Collect Payment section)
      await conn.execute(
        `INSERT INTO ip_payment_transactions
           (transaction_ref, booking_id, patient_id, payment_type,
            gross_amount, discount_amount, net_amount, amount_paid, amount_due,
            currency, payment_status, transaction_status, is_refund,
            gateway_transaction_id, gateway_order_id, gateway_status, paid_at)
         VALUES (?, ?, ?, 'PAY_LATER', ?, 0, ?, 0, ?, 'INR', 'pending', 'pending', 0, NULL, NULL, NULL, NULL)`,
        [txnRef, newBookingId, patientId, totalAmount, totalAmount, totalAmount]
      );

      // INSERT ip_technician_collection — direct assignment, tech is on-site
      await conn.execute(
        `INSERT INTO ip_technician_collection
           (booking_id, technician_id, technician_name, collection_status, collection_date,
            collection_address, collection_latitude, collection_longitude,
            patient_id, slot_id, assigned_at, created_at, updated_at)
         VALUES (?, ?, ?, 'arrived', CURDATE(), ?, ?, ?, ?, ?, NOW(), NOW(), NOW())
         ON DUPLICATE KEY UPDATE
           technician_id     = VALUES(technician_id),
           technician_name   = VALUES(technician_name),
           collection_status = 'arrived',
           assigned_at       = NOW(),
           updated_at        = NOW()`,
        [newBookingId, technicianId, technicianName || null,
         parent.collection_address, parent.collection_latitude, parent.collection_longitude,
         patientId || null, parent.slot_id ?? null]
      );

      results.push({ newBookingId, bookingRef, patientId, totalAmount });
      console.log(`   ✅ addVisitMember — booking_id=${newBookingId} ref=${bookingRef}`);
    }

    await conn.commit();
    const totalVisitAmount = results.reduce((s, r) => s + r.totalAmount, 0);
    console.log(`✅ addVisitMember — ${results.length} member(s) added parent=${parentBookingId} visit_group=${visitGroupId}`);
    res.status(201).json({
      success: true,
      members: results,
      visitGroupId,
      totalMembers:     results.length,
      totalVisitAmount,
      // Legacy single-member fields (for older clients still using old addVisitMember call)
      ...(results.length === 1 && {
        newBookingId: results[0].newBookingId,
        bookingRef:   results[0].bookingRef,
        patientId:    results[0].patientId,
        totalAmount:  results[0].totalAmount,
      }),
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

    // Family members = other patients registered under the same client_id
    // (the same account/family grouping used everywhere else in the app —
    // e.g. the customer-side "Add Family Member" flow at checkout). The
    // previous version only found patients who had ALREADY shared a
    // visit_group_id or booking row with this patient, which is impossible
    // for a patient's first-ever family addition (no such history exists
    // yet) — it always returned empty in exactly the case this feature is
    // for, silently falling through to the "new patient" form every time.
    const [members] = await db.execute(
      `SELECT patient_id, patient_name, patient_mobile,
              patient_relation, patient_age, patient_gender
       FROM ip_patients
       WHERE client_id   = ?
         AND patient_id != ?
         AND deleted_at IS NULL
       ORDER BY patient_name ASC
       LIMIT 10`,
      [booking.client_id, booking.patient_id]
    );

    res.json({ success: true, members });
  } catch (err) {
    console.error('❌ getBookingFamily FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── POST /api/technicians/booking-otp/generate ───────────────────────────────
// Generates a 4-digit OTP, stores it in ip_technician_collection, and sends it
// to the patient's registered mobile number via the booking OTP SMS template.
exports.generateBookingOtp = async (req, res) => {
  const technicianId  = req.user.id;
  const { bookingId } = req.body;

  if (!bookingId) {
    return res.status(400).json({ success: false, message: 'bookingId is required' });
  }

  const expiryMinutes = parseInt(process.env.OTP_EXPIRY_MINUTES ?? '10');

  otpLog(`[GENERATE] ── START ── booking_id=${bookingId} tech_id=${technicianId}`);

  try {
    // Verify assignment and fetch OTP recipient mobile.
    // If the booking was created by a logged-in account owner (family head), send to their
    // registered login number (ip_users.user_mobile_no) so the person physically present
    // with the technician receives the OTP — not the patient the test is booked for.
    // Falls back to ip_patients.patient_mobile for self-bookings and cases where
    // created_by is null or does not match any ip_users row.
    const [[row]] = await db.execute(
      `SELECT COALESCE(u.user_mobile_no, p.patient_mobile) AS patient_mobile,
              p.patient_name,
              p.patient_mobile   AS raw_patient_mobile,
              b.created_by,
              u.user_id          AS creator_user_id,
              u.user_mobile_no   AS creator_mobile
       FROM ip_technician_collection tc
       JOIN ip_bookings b ON b.booking_id = tc.booking_id
       JOIN ip_patients p ON p.patient_id = b.patient_id
       LEFT JOIN ip_users u ON u.user_id = b.created_by
       WHERE tc.booking_id = ? AND tc.technician_id = ? AND b.deleted_at IS NULL LIMIT 1`,
      [bookingId, technicianId]
    );

    if (!row) {
      otpLog(`[GENERATE] ❌ LOOKUP FAILED — no row found for booking_id=${bookingId} tech_id=${technicianId} (booking missing, not assigned, or deleted)`);
      return res.status(404).json({ success: false, message: 'Booking not found or not assigned to you' });
    }

    otpLog(`[GENERATE] DB lookup OK — patient_name="${row.patient_name}" raw_patient_mobile=${row.raw_patient_mobile ?? 'NULL'} created_by=${row.created_by ?? 'NULL'} creator_user_id=${row.creator_user_id ?? 'NULL'} creator_mobile=${row.creator_mobile ?? 'NULL'} resolved_mobile=${row.patient_mobile ?? 'NULL'}`);

    if (!row.patient_mobile) {
      otpLog(`[GENERATE] ⚠️  resolved mobile is NULL — SMS will not be sent (patient_mobile and creator_mobile are both NULL)`);
    }

    const otp = Math.floor(1000 + Math.random() * 9000).toString();

    const [updateRes] = await db.execute(
      `UPDATE ip_technician_collection
       SET collection_otp = ?, collection_otp_expiry = DATE_ADD(NOW(), INTERVAL ? MINUTE), otp_attempts = 0
       WHERE booking_id = ? AND technician_id = ?`,
      [otp, expiryMinutes, bookingId, technicianId]
    );
    otpLog(`[GENERATE] OTP stored in DB — affected_rows=${updateRes.affectedRows} expiry=${expiryMinutes}min`);

    if (updateRes.affectedRows === 0) {
      otpLog(`[GENERATE] ⚠️  OTP UPDATE hit 0 rows — ip_technician_collection row may be missing for booking_id=${bookingId} tech_id=${technicianId}`);
    }

    // Send SMS — non-fatal: OTP is stored even if SMS fails
    const targetMobile = row.patient_mobile ?? '';
    otpLog(`[GENERATE] SMS target — mobile="${targetMobile}" api_key_set=${!!process.env.PING4SMS_API_KEY} sender_set=${!!process.env.PING4SMS_SENDER_ID} template_id=${process.env.PING4SMS_BOOKING_OTP_TEMPLATE_ID ?? 'NOT SET'}`);
    try {
      const smsRes = await sms.sendBookingOtp(targetMobile, otp);
      otpLog(`[GENERATE] ✅ SMS sent — mobile=${targetMobile} response="${smsRes}"`);
    } catch (smsErr) {
      otpLog(`[GENERATE] ❌ SMS FAILED — mobile=${targetMobile} error="${smsErr.message}"`);
    }

    const maskedMobile = targetMobile.length >= 10
      ? `${targetMobile.slice(0, 3)}****${targetMobile.slice(7)}`
      : '****';

    otpLog(`[GENERATE] ── DONE ── success=true maskedMobile=${maskedMobile}`);
    res.json({ success: true, maskedMobile });
  } catch (err) {
    otpLog(`[GENERATE] ❌ SERVER ERROR — ${err.message}`);
    console.error('❌ generateBookingOtp FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── POST /api/technicians/booking-otp/verify ─────────────────────────────────
// Validates the OTP the technician entered against the stored value.
// On success: sets collection_status = 'otp_verified', clears OTP fields.
exports.verifyBookingOtp = async (req, res) => {
  const technicianId      = req.user.id;
  const { bookingId, otp } = req.body;

  if (!bookingId || !otp) {
    return res.status(400).json({ success: false, message: 'bookingId and otp are required' });
  }

  const maxAttempts = parseInt(process.env.OTP_MAX_ATTEMPTS ?? '3');

  try {
    const [[row]] = await db.execute(
      `SELECT collection_otp, otp_attempts,
              (collection_otp_expiry IS NULL OR collection_otp_expiry < NOW()) AS is_expired
       FROM ip_technician_collection
       WHERE booking_id = ? AND technician_id = ?`,
      [bookingId, technicianId]
    );

    if (!row) {
      return res.status(404).json({ success: false, message: 'Assignment not found' });
    }

    if (!row.collection_otp) {
      return res.status(400).json({ success: false, message: 'No OTP generated. Please generate OTP first.' });
    }

    if (row.otp_attempts >= maxAttempts) {
      return res.status(429).json({ success: false, message: 'Too many failed attempts. Please resend OTP.', attemptsExhausted: true });
    }

    if (row.is_expired) {
      return res.status(400).json({ success: false, message: 'OTP has expired. Please resend OTP.', expired: true });
    }

    if (row.collection_otp !== otp.toString()) {
      await db.execute(
        `UPDATE ip_technician_collection SET otp_attempts = otp_attempts + 1 WHERE booking_id = ? AND technician_id = ?`,
        [bookingId, technicianId]
      );
      const remaining = maxAttempts - (row.otp_attempts + 1);
      return res.status(401).json({
        success: false,
        message: remaining > 0
          ? `Incorrect OTP. ${remaining} attempt${remaining === 1 ? '' : 's'} remaining.`
          : 'Too many failed attempts. Please resend OTP.',
        attemptsExhausted: remaining <= 0,
      });
    }

    // OTP correct — update status and clear OTP fields
    await db.execute(
      `UPDATE ip_technician_collection
       SET collection_status     = 'otp_verified',
           collection_otp        = NULL,
           collection_otp_expiry = NULL,
           otp_attempts          = 0,
           otp_verified_at       = NOW()
       WHERE booking_id = ? AND technician_id = ?`,
      [bookingId, technicianId]
    );

    // Cascade otp_verified to sibling bookings in the same visit group
    try {
      const [[vgRow]] = await db.execute(
        'SELECT visit_group_id FROM ip_bookings WHERE booking_id = ? LIMIT 1',
        [bookingId]
      );
      if (vgRow?.visit_group_id) {
        await db.execute(
          `UPDATE ip_technician_collection tc
           JOIN ip_bookings b ON b.booking_id = tc.booking_id
           SET tc.collection_status = 'otp_verified',
               tc.otp_verified_at   = NOW(),
               tc.updated_at        = NOW()
           WHERE b.visit_group_id = ? AND b.booking_id != ? AND b.deleted_at IS NULL`,
          [vgRow.visit_group_id, bookingId]
        );
      }
    } catch (e) {
      console.error(`❌ [verifyBookingOtp] sibling cascade failed booking=${bookingId}: ${e.message}`);
    }

    console.log(`✅ verifyBookingOtp — booking_id=${bookingId} OTP verified by technician_id=${technicianId}`);
    res.json({ success: true });
  } catch (err) {
    console.error('❌ verifyBookingOtp FAILED:', err.code, err.message);
    res.status(500).json({ success: false, message: 'Server error', detail: err.message });
  }
};

// ── POST /api/technicians/booking-otp/resend ─────────────────────────────────
// Regenerates and resends the OTP. Enforces a 60-second cooldown between resends.
exports.resendBookingOtp = async (req, res) => {
  const technicianId  = req.user.id;
  const { bookingId } = req.body;

  if (!bookingId) {
    return res.status(400).json({ success: false, message: 'bookingId is required' });
  }

  const expiryMinutes = parseInt(process.env.OTP_EXPIRY_MINUTES ?? '10');

  otpLog(`[RESEND] ── START ── booking_id=${bookingId} tech_id=${technicianId}`);

  try {
    // Check cooldown: if OTP remaining time > (expiryMinutes - 1) minutes, resend too soon
    const [[cooldownRow]] = await db.execute(
      `SELECT 1 FROM ip_technician_collection
       WHERE booking_id = ? AND technician_id = ?
         AND collection_otp IS NOT NULL
         AND TIMESTAMPDIFF(SECOND, NOW(), collection_otp_expiry) > ?`,
      [bookingId, technicianId, (expiryMinutes - 1) * 60]
    );

    if (cooldownRow) {
      otpLog(`[RESEND] ⏱  cooldown active — too soon to resend for booking_id=${bookingId}`);
      return res.status(429).json({ success: false, message: 'Please wait 60 seconds before resending OTP.' });
    }

    // Fetch OTP recipient mobile — same logic as generateBookingOtp:
    // prefer the booking creator's login number over the patient's number.
    const [[row]] = await db.execute(
      `SELECT COALESCE(u.user_mobile_no, p.patient_mobile) AS patient_mobile,
              p.patient_mobile   AS raw_patient_mobile,
              b.created_by,
              u.user_id          AS creator_user_id,
              u.user_mobile_no   AS creator_mobile
       FROM ip_technician_collection tc
       JOIN ip_bookings b ON b.booking_id = tc.booking_id
       JOIN ip_patients p ON p.patient_id = b.patient_id
       LEFT JOIN ip_users u ON u.user_id = b.created_by
       WHERE tc.booking_id = ? AND tc.technician_id = ? AND b.deleted_at IS NULL LIMIT 1`,
      [bookingId, technicianId]
    );

    if (!row) {
      otpLog(`[RESEND] ❌ LOOKUP FAILED — no row found for booking_id=${bookingId} tech_id=${technicianId}`);
      return res.status(404).json({ success: false, message: 'Booking not found or not assigned to you' });
    }

    otpLog(`[RESEND] DB lookup OK — raw_patient_mobile=${row.raw_patient_mobile ?? 'NULL'} created_by=${row.created_by ?? 'NULL'} creator_user_id=${row.creator_user_id ?? 'NULL'} creator_mobile=${row.creator_mobile ?? 'NULL'} resolved_mobile=${row.patient_mobile ?? 'NULL'}`);

    const otp = Math.floor(1000 + Math.random() * 9000).toString();

    const [updateRes] = await db.execute(
      `UPDATE ip_technician_collection
       SET collection_otp = ?, collection_otp_expiry = DATE_ADD(NOW(), INTERVAL ? MINUTE), otp_attempts = 0
       WHERE booking_id = ? AND technician_id = ?`,
      [otp, expiryMinutes, bookingId, technicianId]
    );
    otpLog(`[RESEND] OTP stored in DB — affected_rows=${updateRes.affectedRows}`);

    const targetMobile = row.patient_mobile ?? '';
    otpLog(`[RESEND] SMS target — mobile="${targetMobile}" template_id=${process.env.PING4SMS_BOOKING_OTP_TEMPLATE_ID ?? 'NOT SET'}`);
    try {
      const smsRes = await sms.sendBookingOtp(targetMobile, otp);
      otpLog(`[RESEND] ✅ SMS sent — mobile=${targetMobile} response="${smsRes}"`);
    } catch (smsErr) {
      otpLog(`[RESEND] ❌ SMS FAILED — mobile=${targetMobile} error="${smsErr.message}"`);
    }

    otpLog(`[RESEND] ── DONE ── success=true`);
    res.json({ success: true });
  } catch (err) {
    otpLog(`[RESEND] ❌ SERVER ERROR — ${err.message}`);
    console.error('❌ resendBookingOtp FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};