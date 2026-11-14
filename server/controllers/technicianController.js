// controllers/technicianController.js
//
// REST endpoints for technician availability and live-location data.
// Reads from ip_technician_live_location which is kept current by bookingSocket.js
// via INSERT … ON DUPLICATE KEY UPDATE on every technician_online event.

const db       = require('../config/db');
const settings = require('../config/settings');
const fs   = require('fs');
const path = require('path');
const qrStore  = require('../services/qrSessionStore');
const { savePartialReason } = require('../services/partialPaymentReason');
const sms  = require('../utils/sms');
const { forceTechnicianOffline, unassignAndRedispatch } = require('../socket/bookingSocket');
const dbLogger = require('../utils/dbLogger');
const { getTechnicianBranches } = require('../services/technicianBranches');
const serviceChargeSvc = require('../services/serviceCharge');
const { verifyRazorpayPayment } = require('../services/razorpayVerify');
const { captureRazorpayPayment } = require('../services/razorpayCapture');

const TECH_LOG = path.join(__dirname, '..', 'logs', 'technician.log');
function tlog(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false }).replace(',', '') + ' IST';
  const line = `[${ist}] ${msg}\n`;
  process.stdout.write(line);
  fs.appendFileSync(TECH_LOG, line, 'utf8');
  dbLogger.logTechnicianEvent(msg);
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
  dbLogger.logOtpInfoEvent(msg);
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

    // Extra detail: the rest of the profile still loads if this fails.
    let branches = [];
    try {
      branches = await getTechnicianBranches(technicianId);
    } catch (branchErr) {
      console.error('[getProfile] branches failed:', branchErr.message);
    }

    console.log(`✅ Profile loaded — ${profile.user_name} branch=${profile.branch_name}`);
    res.json({ success: true, profile, stats, branches });
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
      `(
        SELECT
           tc.collection_id,
           tc.booking_id,
           b.booking_ref,
           b.reference_no,
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
             'handed_to_lab','handed_to_lab_pending','sample_collected','collection_started',
             'cancelled'
           )
      )
      UNION ALL
      (
        -- Jobs THIS technician accepted and then cancelled. ip_technician_collection
        -- no longer has a row for them here — it was deleted and (if a replacement
        -- was found) reassigned to whoever picked it up next — so this branch reads
        -- straight off ip_bookings.technician_cancelled_by, which survives that.
        SELECT
           NULL AS collection_id,
           b.booking_id,
           b.booking_ref,
           b.reference_no,
           'cancelled' AS collection_status,
           b.booking_date AS collection_date,
           b.collection_address,
           b.technician_cancelled_at AS assigned_at,
           NULL AS collected_at,
           b.technician_cancelled_at AS completed_at,
           s.slot_label,
           TIME_FORMAT(avs.slot_time, '%h:%i %p') AS slot_time_formatted,
           b.city,
           b.postal_code,
           b.amount_paid,
           p.patient_name,
           p.patient_mobile
         FROM ip_bookings b
         LEFT JOIN ip_available_slots   avs ON avs.available_slot_id = b.available_slot_id
         LEFT JOIN ip_technician_slots  ts  ON ts.tech_slot_id       = avs.technician_slot_id
         LEFT JOIN ip_slots             s   ON s.slot_id             = COALESCE(ts.slot_id, b.slot_id)
         LEFT JOIN ip_patients          p   ON p.patient_id          = b.patient_id
         WHERE b.technician_cancelled_by = ?
           AND NOT EXISTS (
             SELECT 1 FROM ip_technician_collection tc2
             WHERE tc2.booking_id = b.booking_id AND tc2.technician_id = ?
           )
      )
      ORDER BY COALESCE(completed_at, collected_at, assigned_at) DESC
      LIMIT 100`,
      [technicianId, technicianId, technicianId]
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

    // Clear auth token and logged-in flag in ip_users
    await connection.query(
      `UPDATE ip_users u
       JOIN ip_technicians t ON t.user_id = u.user_id
       SET u.user_auth_token    = NULL,
           u.user_token_expiry  = NULL,
           u.is_logged_in       = 0,
           u.user_date_modified = NOW()
       WHERE t.technician_id = ?`,
      [technicianId]
    );

    await connection.commit();

    // Force the technician out of the live dispatch pool regardless of
    // whether their socket's technician_offline event actually arrived.
    // That event can silently fail to reach the server if the socket was
    // already disconnected at logout time — in which case the plain socket
    // 'disconnect' handler treats it as an accidental drop (45s grace period,
    // in-memory pool never cleared) rather than an intentional logout. This
    // REST path updates the same in-memory maps directly, independent of
    // socket timing, so a logged-out technician stops receiving new
    // dispatch attempts immediately rather than indefinitely.
    forceTechnicianOffline(Number(technicianId));

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

// ── POST /api/technicians/cancel-booking ──────────────────────────────────────
// Technician-initiated hand-off of an already-accepted job, back before they've
// started traveling (collection_status='assigned' only — mirrors the same gate
// patient-side reschedule uses). This is NOT a booking cancellation: the patient
// keeps their booking, it's released and re-dispatched to find them another
// technician, exactly like reschedule already does — see unassignAndRedispatch
// in bookingSocket.js, shared by both flows.
const CANCEL_REASONS = ['vehicle_issue', 'personal_emergency', 'unreachable_patient', 'other'];

exports.cancelAssignedBooking = async (req, res) => {
  const technicianId = req.user.id;
  const { bookingId, reason, note = null } = req.body;

  if (!bookingId) {
    return res.status(400).json({ success: false, message: 'bookingId is required' });
  }
  if (!CANCEL_REASONS.includes(reason)) {
    return res.status(400).json({
      success: false,
      message: `reason is required and must be one of: ${CANCEL_REASONS.join(', ')}`,
    });
  }

  try {
    const [[tc]] = await db.execute(
      `SELECT tc.collection_status, b.booking_ref, b.reference_no, b.visit_group_id
       FROM ip_technician_collection tc
       JOIN ip_bookings b ON b.booking_id = tc.booking_id
       WHERE tc.booking_id = ? AND tc.technician_id = ?
       LIMIT 1`,
      [bookingId, technicianId]
    );

    if (!tc) {
      return res.status(404).json({ success: false, message: 'Booking not found or not assigned to you' });
    }
    if (tc.collection_status !== 'assigned') {
      return res.status(400).json({
        success: false,
        message: `Cannot cancel — already ${tc.collection_status.replace(/_/g, ' ')}`,
      });
    }

    let allIds = [bookingId];
    if (tc.visit_group_id) {
      const [siblings] = await db.execute(
        `SELECT booking_id FROM ip_bookings WHERE visit_group_id = ? AND deleted_at IS NULL`,
        [tc.visit_group_id]
      );
      allIds = siblings.map(s => s.booking_id);
    }

    tlog(`[cancelAssignedBooking] technician_id=${technicianId} booking_id=${bookingId} ref=${tc.booking_ref} reason=${reason} note=${note ?? ''} group_size=${allIds.length}`);

    await unassignAndRedispatch({
      bookingId,
      allIds,
      technicianId,
      notifyTitle: 'Booking Unassigned',
      notifyBody:  `You are no longer assigned to booking ${tc.reference_no ?? tc.booking_ref} (${reason.replace(/_/g, ' ')}). It has been re-dispatched.`,
      notifyType:  'booking_unassigned',
      excludeFromRedispatch: true,
      technicianCancelReason: reason,
      technicianCancelNote:   note,
    });

    res.json({ success: true, message: 'Booking released and re-dispatched' });
  } catch (e) {
    tlog(`[cancelAssignedBooking] ERROR — technician_id=${technicianId} booking_id=${bookingId} — ${e.message}`);
    console.error('[cancelAssignedBooking]', e.message);
    res.status(500).json({ success: false, message: 'Server error' });
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
         b.reference_no,
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
         b.notes                 AS collection_notes,
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

    // branch_ids: the branches each slot is offered at — the technician's
    // picks (ip_technician_slot_branches), or the slot's own branch for one
    // saved before branches could be picked.
    const [techSlots] = await db.execute(
      `SELECT ts.slot_id, DATE_FORMAT(ts.slot_date, '%Y-%m-%d') AS slot_date, ts.max_bookings, ts.booked_count,
              ts.is_available, ts.duration_minutes, ts.branch_id,
              GROUP_CONCAT(sb.branch_id ORDER BY sb.branch_id) AS slot_branch_ids
       FROM ip_technician_slots ts
       LEFT JOIN ip_technician_slot_branches sb ON sb.tech_slot_id = ts.tech_slot_id
       WHERE ts.technician_id = ? AND ts.slot_date >= CURDATE() AND ts.is_available = 1
       GROUP BY ts.tech_slot_id
       ORDER BY ts.slot_date ASC`,
      [technicianId]
    );
    for (const s of techSlots) {
      s.branch_ids = s.slot_branch_ids
        ? String(s.slot_branch_ids).split(',').map(Number)
        : (s.branch_id != null ? [Number(s.branch_id)] : []);
      delete s.slot_branch_ids;
    }

    // The branches this technician can offer slots at, for the branch picker.
    let branches = [];
    try {
      branches = await getTechnicianBranches(technicianId);
    } catch (branchErr) {
      console.error('[getSlots] branches failed:', branchErr.message);
    }

    console.log(`✅ Master slots=${masterSlots.length} tech configs=${techSlots.length} branches=${branches.length}`);
    res.json({ success: true, masterSlots, techSlots, branches });
  } catch (e) {
    console.error('[getSlots]', e.message);
    res.status(500).json({ success: false, message: e.message });
  }
};

// ── PUT /api/technicians/:technicianId/slots ──────────────────────────────────
// Body: { slots: [{ date: 'YYYY-MM-DD', slot_ids: [1,2], durations: {"1":30,"2":15},
//                   branches: {"1": [3, 7], "2": [3]} }] }
// durations is optional; omitting it (or a specific slot_id key) skips interval generation.
// branches is optional: the branches each slot is offered at, per day — only
// branches the technician works at are kept; none → their own branch. One
// slot, one capacity: offered at several branches, the first booking takes it.
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

    // Branches this technician may offer a slot at: their own branch plus
    // their ASMX branches (same list as Profile → My Branches and dispatch).
    const allowedBranches = new Set(branchId != null ? [Number(branchId)] : []);
    try {
      for (const b of await getTechnicianBranches(technicianId)) allowedBranches.add(Number(b.branchId));
    } catch (branchErr) {
      console.error('[saveSlots] branches failed — slots go to the own branch:', branchErr.message);
    }
    // The branches picked for one slot on one day; none valid → own branch.
    const branchesFor = (day, slotId) => {
      const asked = day.branches?.[String(slotId)];
      const picked = [...new Set((Array.isArray(asked) ? asked : []).map(Number).filter(b => allowedBranches.has(b)))];
      return picked.length ? picked : (branchId != null ? [Number(branchId)] : []);
    };

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

      // What the technician wants: "date|slotId" → duration in minutes, or null.
      const slotKey = (date, slotId) => `${date}|${slotId}`;
      const wanted  = new Map();
      // "date|slotId" → the branches it is offered at (first = its own branch_id).
      const wantedBranches = new Map();
      for (const day of slots) {
        if (!Array.isArray(day.slot_ids)) continue;
        const durMap = day.durations ?? {}; // { "1": 30, "2": 15 } — keyed by slot_id string
        for (const slotId of day.slot_ids) {
          wanted.set(slotKey(day.date, slotId), durMap[String(slotId)] ? Number(durMap[String(slotId)]) : null);
          wantedBranches.set(slotKey(day.date, slotId), branchesFor(day, slotId));
        }
      }

      // A slot with bookings is never deleted: those bookings point at its
      // rows, and deleting them would lose the appointment time and put a
      // booked time back on sale. Only unbooked slots are removed or rebuilt.
      const [existing] = await connection.query(
        `SELECT ts.tech_slot_id, ts.slot_id, ts.duration_minutes,
                DATE_FORMAT(ts.slot_date, '%Y-%m-%d') AS slot_date,
                (ts.booked_count > 0 OR EXISTS (
                   SELECT 1 FROM ip_available_slots ias
                   WHERE ias.technician_slot_id = ts.tech_slot_id AND ias.is_available = 0)) AS has_bookings
         FROM ip_technician_slots ts
         WHERE ts.technician_id = ? AND ts.slot_date >= ?`,
        [technicianId, todayIST]
      );

      for (const row of existing) {
        const key         = slotKey(row.slot_date, row.slot_id);
        const isWanted    = wanted.has(key);
        const hasBookings = Number(row.has_bookings) === 1;
        const sameLength  = isWanted && (Number(row.duration_minutes) || null) === wanted.get(key);

        // Kept rows take the branches picked now (or the technician's own
        // branch when unticked), so a change reaches slots saved before it.
        const keptBranches = wantedBranches.get(key) ?? (branchId != null ? [Number(branchId)] : []);
        if (hasBookings) {
          // Booked but unticked: stays for its bookings, with its free times withdrawn.
          await connection.query(
            'UPDATE ip_technician_slots SET is_available = ?, branch_id = ? WHERE tech_slot_id = ?',
            [isWanted ? 1 : 0, isWanted ? keptBranches[0] ?? branchId : branchId, row.tech_slot_id]
          );
          if (isWanted) await _saveSlotBranches(connection, row.tech_slot_id, keptBranches);
          if (!isWanted) {
            await connection.query(
              'DELETE FROM ip_available_slots WHERE technician_slot_id = ? AND is_available = 1',
              [row.tech_slot_id]
            );
          } else {
            await _restoreFreeTimes(connection, row);
            wanted.delete(key);
          }
        } else if (sameLength) {
          await connection.query(
            'UPDATE ip_technician_slots SET is_available = 1, branch_id = ? WHERE tech_slot_id = ?',
            [keptBranches[0] ?? branchId, row.tech_slot_id]
          );
          await _saveSlotBranches(connection, row.tech_slot_id, keptBranches);
          wanted.delete(key);
        } else {
          await connection.query('DELETE FROM ip_available_slots WHERE technician_slot_id = ?', [row.tech_slot_id]);
          await connection.query('DELETE FROM ip_technician_slot_branches WHERE tech_slot_id = ?', [row.tech_slot_id]);
          await connection.query('DELETE FROM ip_technician_slots WHERE tech_slot_id = ?', [row.tech_slot_id]);
        }
      }

      let totalIntervals = 0;
      for (const day of slots) {
        if (!Array.isArray(day.slot_ids) || day.slot_ids.length === 0) continue;

        for (const slotId of day.slot_ids) {
          const key = slotKey(day.date, slotId);
          if (!wanted.has(key)) continue; // kept as it was above
          const durationMinutes = wanted.get(key);
          const slotBranches    = wantedBranches.get(key) ?? [];

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
            [technicianId, slotId, day.date, slotBranches[0] ?? branchId, maxBookings, durationMinutes, technicianId]
          );
          const techSlotId = ins.insertId;
          await _saveSlotBranches(connection, techSlotId, slotBranches);

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

// The branches a slot is offered at (ip_technician_slot_branches): replaces
// whatever was saved for it before.
async function _saveSlotBranches(connection, techSlotId, branchIds) {
  await connection.query('DELETE FROM ip_technician_slot_branches WHERE tech_slot_id = ?', [techSlotId]);
  if (!branchIds.length) return;
  await connection.query(
    `INSERT INTO ip_technician_slot_branches (tech_slot_id, branch_id) VALUES ${branchIds.map(() => '(?, ?)').join(', ')}`,
    branchIds.flatMap(b => [techSlotId, b])
  );
}

// Puts back the free times of a booked slot the technician ticked again after
// unticking it. Times that are still booked keep their rows.
async function _restoreFreeTimes(connection, row) {
  const durationMinutes = Number(row.duration_minutes);
  if (!durationMinutes) return;
  const [[slotDef]] = await connection.query(
    'SELECT slot_start, slot_end FROM ip_slots WHERE slot_id = ?',
    [row.slot_id]
  );
  if (!slotDef) return;
  const [rows] = await connection.query(
    'SELECT slot_time FROM ip_available_slots WHERE technician_slot_id = ?',
    [row.tech_slot_id]
  );
  const present = new Set(rows.map(r => String(r.slot_time).slice(0, 5)));
  for (const t of _generateIntervals(slotDef.slot_start, slotDef.slot_end, durationMinutes)) {
    if (present.has(String(t).slice(0, 5))) continue;
    await connection.query(
      `INSERT INTO ip_available_slots
         (booking_type, technician_slot_id, slot_date, slot_time, is_available, created_at)
       VALUES ('home_collection', ?, ?, ?, 1, NOW())`,
      [row.tech_slot_id, row.slot_date, t]
    );
  }
}

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
  const { bookingId, razorpayPaymentId, amount, paymentMethod = 'RAZORPAY', partialReason } = req.body;

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
      `SELECT b.booking_id, b.patient_id, b.total_amount, b.amount_paid
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

    const totalAmount   = parseFloat(booking.total_amount) || 0;
    const currentPaid   = parseFloat(booking.amount_paid) || 0;
    const incomingAmount = Number(amount);
    const amountDueBefore = Math.max(0, Math.round((totalAmount - currentPaid) * 100) / 100);

    // Reject anything that would push amount_paid past total_amount — covers
    // both a booking that's already fully paid (amountDueBefore = 0, so any
    // positive amount is rejected) and a single payment larger than what's
    // left owed. 0.01 tolerance absorbs float rounding on the subtraction
    // above, not a real allowance to overpay.
    if (incomingAmount > amountDueBefore + 0.01) {
      console.warn(`⚠️  collectPayment — booking_id=${bookingId} rejected: amount=₹${incomingAmount} exceeds amount due=₹${amountDueBefore} by technician_id=${technicianId}`);
      return res.status(400).json({
        success: false,
        message: `Payment amount ₹${incomingAmount} exceeds the amount due ₹${amountDueBefore}`,
        amountDue: amountDueBefore,
      });
    }

    // A combined family payment splits one Razorpay payment across bookings,
    // so the id repeats and the payment may be larger than this share.
    let payment = null;
    if (paymentMethod === 'RAZORPAY') {
      payment = await verifyRazorpayPayment(razorpayPaymentId, { amount: incomingAmount, atLeast: true });
      if (!payment.ok) return res.status(402).json({ success: false, message: payment.message });
    }

    const newAmountPaid    = currentPaid + incomingAmount;
    const newAmountDue     = Math.max(0, totalAmount - newAmountPaid);
    const newPaymentStatus = newAmountDue <= 0 ? 'paid' : 'partial';

    await db.execute(
      `UPDATE ip_bookings
       SET payment_status = ?, amount_paid = ?, amount_due = ?, updated_at = NOW()
       WHERE booking_id = ?`,
      [newPaymentStatus, newAmountPaid, newAmountDue, bookingId]
    );

    const txnRef = `TXN${Date.now()}TC`;
    const isPartial = newAmountDue > 0 ? 1 : 0;
    await db.execute(
      `INSERT INTO ip_payment_transactions
         (transaction_ref, booking_id, patient_id, payment_type, payment_mode,
          gross_amount, net_amount, amount_paid, amount_due,
          currency, payment_status, transaction_status, is_refund, is_partial,
          gateway_transaction_id, gateway_status, collected_by, paid_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'INR', ?, ?, 0, ?, ?, ?, ?, NOW())`,
      [
        txnRef, bookingId, booking.patient_id, paymentMethod, paymentMethod,
        amount, amount, amount, newAmountDue,
        newPaymentStatus, newPaymentStatus === 'paid' ? 'completed' : 'partial',
        isPartial,
        paymentMethod === 'RAZORPAY' ? razorpayPaymentId : null,
        paymentMethod === 'RAZORPAY' ? 'captured' : 'cash_collected',
        technicianId,
      ]
    );

    // The whole payment, once: a split family payment is already 'captured' by
    // the time the next booking's share arrives.
    if (payment?.status === 'authorized') captureRazorpayPayment(razorpayPaymentId, payment.amount);

    console.log(`✅ collectPayment — booking_id=${bookingId} method=${paymentMethod} +₹${amount} → paid=₹${newAmountPaid} due=₹${newAmountDue} status=${newPaymentStatus} by technician_id=${technicianId}`);

    // No individual Jayamala sync here — payment for a technician-run visit
    // now reaches the client server only once, in the consolidated
    // visit_completed request fired from verifyBookingOtp. This value is
    // still saved to ip_payment_transactions/ip_bookings above exactly as
    // before; only the immediate per-action sync was removed.

    // Sent by the app only for a partial payment. The payment above is already
    // saved, so a failure here must not report the payment as failed.
    try {
      await savePartialReason(bookingId, partialReason);
    } catch (reasonErr) {
      console.error(`⚠️  collectPayment — partial reason not saved booking_id=${bookingId}: ${reasonErr.message}`);
    }

    res.json({ success: true, amountPaid: newAmountPaid, amountDue: newAmountDue, paymentStatus: newPaymentStatus });
  } catch (err) {
    console.error('❌ collectPayment FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── POST /api/technicians/create-qr ──────────────────────────────────────────
// Creates a Razorpay UPI QR code for on-site payment collection.
// Returns { qrId, imageUrl } on success; stores session in qrSessionStore so
// the qr-status polling endpoint and the webhook handler can both find it.
exports.createQrPayment = async (req, res) => {
  const technicianId = req.user.id;
  // bookingIds[] for combined family QR; bookingId for single booking QR.
  const { bookingId, bookingIds, amount, partialReason } = req.body;
  const reasonText = String(partialReason ?? '').trim().slice(0, 255); // Razorpay notes: 256 chars max
  const primaryId  = bookingId ?? (Array.isArray(bookingIds) ? bookingIds[0] : null);
  const allIds     = Array.isArray(bookingIds) && bookingIds.length > 0 ? bookingIds : [primaryId];
  const isCombined = allIds.length > 1;

  if (!primaryId || !amount || Number(amount) <= 0) {
    return res.status(400).json({ success: false, message: 'bookingId and amount are required' });
  }

  try {
    // Ownership check on the primary booking (the one used as QR anchor).
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
      [primaryId, technicianId, technicianId]
    );

    if (!booking) {
      return res.status(404).json({ success: false, message: 'Booking not found or not assigned to this technician' });
    }

    // For combined QR, validate against the sum of all members' due amounts.
    let totalDue;
    if (isCombined) {
      const placeholders = allIds.map(() => '?').join(',');
      const [rows] = await db.execute(
        `SELECT SUM(GREATEST(0, total_amount - COALESCE(amount_paid, 0))) AS combined_due
         FROM ip_bookings WHERE booking_id IN (${placeholders})`,
        allIds
      );
      totalDue = parseFloat(rows[0]?.combined_due ?? 0);
    } else {
      totalDue = Math.max(0, parseFloat(booking.total_amount) - parseFloat(booking.amount_paid || 0));
    }
    if (Number(amount) > totalDue + 0.01) {
      return res.status(400).json({ success: false, message: `Amount ₹${amount} exceeds amount due ₹${totalDue.toFixed(2)}` });
    }

    const keyId     = process.env.RAZORPAY_KEY_ID;
    const keySecret = process.env.RAZORPAY_KEY_SECRET;
    if (!keyId || !keySecret) {
      return res.status(500).json({ success: false, message: 'Razorpay credentials not configured' });
    }

    const auth    = Buffer.from(`${keyId}:${keySecret}`).toString('base64');
    const closeBy = Math.floor(Date.now() / 1000) + 600; // 10-minute expiry

    const qrRes = await fetch('https://api.razorpay.com/v1/payments/qr_codes', {
      method: 'POST',
      headers: { 'Authorization': `Basic ${auth}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        type: 'upi_qr',
        name: 'MicroLab',
        usage: 'single_use',
        fixed_amount: true,
        payment_amount: Math.round(Number(amount) * 100),
        description: `Payment for booking ${bookingId}`,
        close_by: closeBy,
        notes: {
          booking_id:    String(bookingId),
          technician_id: String(technicianId),
          amount:        String(amount),
          // Saved by the webhook once the payment is recorded.
          ...(reasonText && { partial_reason: reasonText }),
        },
      }),
    });

    const qrData = await qrRes.json();
    console.log(`[QR] Razorpay response status=${qrRes.status} id=${qrData.id ?? 'NONE'} image_url=${qrData.image_url ?? 'NULL'} error=${JSON.stringify(qrData.error ?? null)}`);
    if (!qrRes.ok || !qrData.id) {
      console.error('❌ Razorpay QR creation failed:', JSON.stringify(qrData));
      return res.status(502).json({ success: false, message: qrData.error?.description || 'Failed to create QR code' });
    }
    if (!qrData.image_url) {
      console.warn(`[QR] image_url is null for qr_id=${qrData.id} — Razorpay may not support QR in test mode`);
      return res.status(502).json({ success: false, message: 'QR image not available. This may not be supported in test mode.' });
    }

    qrStore.sessions.set(qrData.id, {
      bookingId:    parseInt(bookingId, 10),
      amount:       Number(amount),
      technicianId,
      paid:         false,
      paymentId:    null,
    });

    console.log(`✅ QR created — qr_id=${qrData.id} booking_id=${bookingId} amount=₹${amount} by technician_id=${technicianId}`);
    res.json({ success: true, qrId: qrData.id, imageUrl: qrData.image_url });
  } catch (err) {
    console.error('❌ createQrPayment FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── GET /api/technicians/qr-status/:qrId ─────────────────────────────────────
// Polling endpoint: returns whether the QR session has been paid.
exports.getQrStatus = (req, res) => {
  const session = qrStore.sessions.get(req.params.qrId);
  if (!session) return res.status(404).json({ success: false, message: 'QR session not found' });
  res.json({ success: true, paid: session.paid, paymentId: session.paymentId });
};

// ── Additional charges ───────────────────────────────────────────────────────
// Extra charges the technician puts on a booking on site. Every charge lives
// inside total_amount (ip_bookings.additional_charge_amount is their sum), so
// collectPayment, partial payments and the family payment popup pick it up
// unchanged. Only allowed from Arrived up to Sample Collected — the visit is
// finalised from OTP Verified on.
const ADDITIONAL_CHARGE_STATUSES = ['arrived', 'collection_started', 'sample_collected'];
const CHARGE_WINDOW_MESSAGE = 'Additional charges can be added only after arrival and before OTP verification';

// A booking this technician may charge — same ownership rule as
// collectPayment (their own booking, or a family sibling of it) — with the
// visit's collection status and the sum of its charge packages.
const CHARGEABLE_BOOKING_SQL =
  `SELECT b.booking_id, b.status, b.total_amount, b.amount_paid, b.payment_status,
          b.additional_charge_amount, b.visit_group_id,
          (SELECT COALESCE(SUM(c.price), 0) FROM ip_booking_additional_charges c
            WHERE c.booking_id = b.booking_id AND c.deleted_at IS NULL) AS package_charges,
          (SELECT tc.collection_status
             FROM ip_technician_collection tc
             JOIN ip_bookings vb ON vb.booking_id = tc.booking_id
            WHERE tc.technician_id = ?
              AND (vb.booking_id = b.booking_id
                   OR (b.visit_group_id IS NOT NULL AND vb.visit_group_id = b.visit_group_id))
            ORDER BY tc.booking_id ASC LIMIT 1) AS collection_status
   FROM ip_bookings b
   WHERE b.booking_id = ? AND b.deleted_at IS NULL
     AND (
       EXISTS (SELECT 1 FROM ip_technician_collection tc WHERE tc.booking_id = b.booking_id AND tc.technician_id = ?)
       OR (b.visit_group_id IS NOT NULL AND EXISTS (
         SELECT 1 FROM ip_bookings parent
         INNER JOIN ip_technician_collection tc ON tc.booking_id = parent.booking_id AND tc.technician_id = ?
         WHERE parent.visit_group_id = b.visit_group_id
       ))
     )`;
const chargeableBookingParams = (technicianId, bookingId) => [technicianId, bookingId, technicianId, technicianId];
const canChargeBooking = (booking) =>
  booking.status !== 'cancelled' && ADDITIONAL_CHARGE_STATUSES.includes(booking.collection_status);

const round2 = (n) => Math.round(n * 100) / 100;

// Amount due and payment status once the total changes. Nothing paid yet →
// payment status unchanged (still unpaid/pending).
function chargeTotals(booking, newTotal) {
  const amountPaid = parseFloat(booking.amount_paid) || 0;
  const amountDue  = Math.max(0, round2(newTotal - amountPaid));
  const paymentStatus = amountPaid > 0 ? (amountDue <= 0 ? 'paid' : 'partial') : booking.payment_status;
  return { amountDue, paymentStatus };
}

// ── PUT /api/technicians/bookings/:bookingId/additional-charge ───────────────
// The older typed charge (amount + reason), still used by app versions from
// before charge packages: saving again replaces it, amount 0 removes it.
// It reaches the ASMX in payment_details at Handed to Lab (clientSync.js).

exports.setAdditionalCharge = async (req, res) => {
  const technicianId = req.user.id;
  const bookingId    = parseInt(req.params.bookingId, 10);
  const amount       = Math.round(Number(req.body.amount) * 100) / 100;
  const reason       = String(req.body.reason ?? '').trim();
  const maxAmount    = parseFloat(settings.get('additional_charge_max', '1000')) || 1000;

  if (!bookingId || !Number.isFinite(amount) || amount < 0) {
    return res.status(400).json({ success: false, message: 'Enter a valid additional charge amount' });
  }
  if (amount > maxAmount) {
    return res.status(400).json({ success: false, message: `Additional charge can be at most ₹${maxAmount}` });
  }
  if (amount > 0 && !reason) {
    return res.status(400).json({ success: false, message: 'Please enter a reason for the additional charge' });
  }
  if (reason.length > 255) {
    return res.status(400).json({ success: false, message: 'Reason must be 255 characters or fewer' });
  }

  try {
    const [[booking]] = await db.execute(CHARGEABLE_BOOKING_SQL, chargeableBookingParams(technicianId, bookingId));
    if (!booking) {
      return res.status(404).json({ success: false, message: 'Booking not found or not assigned to this technician' });
    }
    if (!canChargeBooking(booking)) {
      return res.status(409).json({ success: false, message: CHARGE_WINDOW_MESSAGE });
    }

    // additional_charge_amount = charge packages + this typed charge. Only
    // the typed part is replaced here; the packages stay as they are.
    const packageCharges = parseFloat(booking.package_charges) || 0;
    const oldCharge  = parseFloat(booking.additional_charge_amount) || 0;
    const oldTyped   = Math.max(0, oldCharge - packageCharges);
    const oldTotal   = parseFloat(booking.total_amount) || 0;
    const amountPaid = parseFloat(booking.amount_paid) || 0;
    const newTotal   = round2(oldTotal - oldTyped + amount);
    const newCharge  = round2(packageCharges + amount);
    if (newTotal < amountPaid - 0.01) {
      return res.status(400).json({
        success: false,
        message: `₹${amountPaid} is already paid — the total can't go below that`,
      });
    }
    const { amountDue: newAmountDue, paymentStatus: newPaymentStatus } = chargeTotals(booking, newTotal);

    // Guarded on the values read above, so a payment or another edit landing
    // in between is never overwritten with stale totals.
    const [result] = await db.execute(
      `UPDATE ip_bookings
          SET additional_charge_amount = ?, additional_charge_reason = ?,
              total_amount = ?, amount_due = ?, payment_status = ?, updated_at = NOW()
        WHERE booking_id = ? AND additional_charge_amount = ? AND amount_paid = ? AND total_amount = ?`,
      [newCharge, amount > 0 ? reason : null, newTotal, newAmountDue, newPaymentStatus,
       bookingId, booking.additional_charge_amount, booking.amount_paid, booking.total_amount]
    );
    if (result.affectedRows !== 1) {
      return res.status(409).json({ success: false, message: 'Booking was just updated — please refresh and try again' });
    }

    tlog(`[ADDITIONAL_CHARGE] technician_id=${technicianId} booking_id=${bookingId} typed=₹${oldTyped}→₹${amount} packages=₹${packageCharges} total=₹${oldTotal}→₹${newTotal} due=₹${newAmountDue} reason="${amount > 0 ? reason : ''}"`);

    res.json({
      success: true,
      additionalChargeAmount: newCharge,
      additionalChargeReason: amount > 0 ? reason : null,
      totalAmount:   newTotal,
      amountDue:     newAmountDue,
      paymentStatus: newPaymentStatus,
    });
  } catch (err) {
    console.error('❌ setAdditionalCharge FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── GET /api/technicians/charge-packages ─────────────────────────────────────
// Every active product the technician can add as a charge package, with the
// price the server will charge for it.
exports.getChargePackages = async (req, res) => {
  try {
    const [rows] = await db.execute(
      `SELECT product_id, product_name, test_code, product_price, product_category
       FROM ip_products
       WHERE product_active = 1 AND deleted_at IS NULL
       ORDER BY product_name ASC, product_id ASC`
    );
    res.json({
      success: true,
      packages: rows.map(r => ({
        productId: r.product_id,
        name:      r.product_name,
        testCode:  r.test_code ?? null,
        price:     round2(parseFloat(r.product_price) || 0),
        category:  r.product_category ?? null,
      })),
    });
  } catch (err) {
    console.error('❌ getChargePackages FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

const mapCharge = (r) => ({
  chargeId:  r.charge_id,
  bookingId: r.booking_id,
  productId: r.product_id,
  name:      r.product_name,
  testCode:  r.test_code ?? null,
  price:     round2(parseFloat(r.price) || 0),
  reason:    r.reason ?? null,
});

// ── GET /api/technicians/bookings/:bookingId/additional-charges ──────────────
// The charge packages on this booking's whole visit (the booking plus its
// family siblings), and the name of the visit's service charge product for
// the Billing Summary.
exports.getAdditionalCharges = async (req, res) => {
  const technicianId = req.user.id;
  const bookingId    = parseInt(req.params.bookingId, 10);
  if (!bookingId) return res.status(400).json({ success: false, message: 'Invalid booking' });

  try {
    const [[booking]] = await db.execute(CHARGEABLE_BOOKING_SQL, chargeableBookingParams(technicianId, bookingId));
    if (!booking) {
      return res.status(404).json({ success: false, message: 'Booking not found or not assigned to this technician' });
    }
    const groupId = booking.visit_group_id ?? null;

    const [rows] = await db.execute(
      `SELECT c.charge_id, c.booking_id, c.product_id, c.product_name, c.test_code, c.price, c.reason
       FROM ip_booking_additional_charges c
       JOIN ip_bookings b ON b.booking_id = c.booking_id
       WHERE c.deleted_at IS NULL AND b.deleted_at IS NULL
         AND (b.booking_id = ? OR (? IS NOT NULL AND b.visit_group_id = ?))
       ORDER BY c.charge_id ASC`,
      [bookingId, groupId, groupId]
    );
    // Only the visit's first member carries the service charge product.
    const [[serviceCharge]] = await db.execute(
      `SELECT p.product_name
       FROM ip_bookings b
       JOIN ip_products p ON p.product_id = b.service_charge_product_id
       WHERE b.deleted_at IS NULL
         AND (b.booking_id = ? OR (? IS NOT NULL AND b.visit_group_id = ?))
       ORDER BY b.booking_id ASC LIMIT 1`,
      [bookingId, groupId, groupId]
    );

    // Service charge decided at accept: applied here too if the arrival step
    // already happened (catch-up), then its details for the Billing Summary.
    await serviceChargeSvc.applyIfArrived(bookingId);
    const sc = await serviceChargeSvc.view(bookingId);

    res.json({
      success: true,
      charges: rows.map(mapCharge),
      serviceChargeProductName: sc.status != null ? sc.productName : serviceCharge?.product_name ?? null,
      // { status, productName, oneWayKm, roundTripKm, amount } — status null:
      // booked before the service charge moved to accept (booking-time fare).
      serviceCharge: sc.skipped ? null : sc,
      canEdit: canChargeBooking(booking),
    });
  } catch (err) {
    console.error('❌ getAdditionalCharges FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── POST /api/technicians/bookings/:bookingId/additional-charges ─────────────
// Adds one or more charge packages: body { productIds: [..], reason? }. The
// reason is optional and applies to every package added together. Prices come
// from ip_products, never from the app, and are added to the booking's total
// and amount due.
exports.addAdditionalCharges = async (req, res) => {
  const technicianId = req.user.id;
  const bookingId    = parseInt(req.params.bookingId, 10);
  const raw          = Array.isArray(req.body.productIds) ? req.body.productIds : [];
  const productIds   = [...new Set(raw.map(v => parseInt(v, 10)))];
  const reason       = String(req.body.reason ?? '').trim();

  if (!bookingId || productIds.length === 0 || productIds.some(id => !Number.isInteger(id) || id <= 0)) {
    return res.status(400).json({ success: false, message: 'Select at least one package' });
  }
  if (productIds.length > 20) {
    return res.status(400).json({ success: false, message: 'Add at most 20 packages at a time' });
  }
  if (reason.length > 255) {
    return res.status(400).json({ success: false, message: 'Reason must be 255 characters or fewer' });
  }

  const conn = await db.getConnection();
  try {
    await conn.beginTransaction();
    // Locked so a payment or another edit can't land between reading the
    // totals and writing them back.
    const [[booking]] = await conn.execute(`${CHARGEABLE_BOOKING_SQL} FOR UPDATE`, chargeableBookingParams(technicianId, bookingId));
    if (!booking) {
      await conn.rollback();
      return res.status(404).json({ success: false, message: 'Booking not found or not assigned to this technician' });
    }
    if (!canChargeBooking(booking)) {
      await conn.rollback();
      return res.status(409).json({ success: false, message: CHARGE_WINDOW_MESSAGE });
    }

    const [products] = await conn.execute(
      `SELECT product_id, product_name, test_code, product_price
       FROM ip_products
       WHERE product_active = 1 AND deleted_at IS NULL AND product_id IN (${productIds.map(() => '?').join(',')})`,
      productIds
    );
    const byId = new Map(products.map(p => [Number(p.product_id), p]));
    if (productIds.some(id => !byId.has(id))) {
      await conn.rollback();
      return res.status(409).json({ success: false, message: 'A selected package is no longer available. Please refresh the list.' });
    }

    let added = 0;
    for (const id of productIds) {
      const p     = byId.get(id);
      const price = round2(parseFloat(p.product_price) || 0);
      added += price;
      await conn.execute(
        `INSERT INTO ip_booking_additional_charges
           (booking_id, product_id, product_name, test_code, price, reason, technician_id, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, NOW())`,
        [bookingId, id, p.product_name, p.test_code ?? null, price, reason || null, technicianId]
      );
    }
    added = round2(added);

    const oldTotal  = parseFloat(booking.total_amount) || 0;
    const newTotal  = round2(oldTotal + added);
    const newCharge = round2((parseFloat(booking.additional_charge_amount) || 0) + added);
    const { amountDue, paymentStatus } = chargeTotals(booking, newTotal);
    await conn.execute(
      `UPDATE ip_bookings
          SET additional_charge_amount = ?, total_amount = ?, amount_due = ?, payment_status = ?, updated_at = NOW()
        WHERE booking_id = ?`,
      [newCharge, newTotal, amountDue, paymentStatus, bookingId]
    );
    await conn.commit();

    tlog(`[CHARGE_PACKAGES_ADDED] technician_id=${technicianId} booking_id=${bookingId} products=${productIds.join(',')} +₹${added} total=₹${oldTotal}→₹${newTotal} due=₹${amountDue} reason="${reason}"`);
    res.json({ success: true, additionalChargeAmount: newCharge, totalAmount: newTotal, amountDue, paymentStatus });
  } catch (err) {
    try { await conn.rollback(); } catch (_) {}
    console.error('❌ addAdditionalCharges FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  } finally {
    conn.release();
  }
};

// ── DELETE /api/technicians/bookings/:bookingId/additional-charges/:chargeId ─
// Removes one charge package and takes its price off the total and amount
// due. Refused when the total would drop below what is already paid.
exports.removeAdditionalCharge = async (req, res) => {
  const technicianId = req.user.id;
  const bookingId    = parseInt(req.params.bookingId, 10);
  const chargeId     = parseInt(req.params.chargeId, 10);
  if (!bookingId || !chargeId) return res.status(400).json({ success: false, message: 'Invalid charge' });

  const conn = await db.getConnection();
  try {
    await conn.beginTransaction();
    const [[booking]] = await conn.execute(`${CHARGEABLE_BOOKING_SQL} FOR UPDATE`, chargeableBookingParams(technicianId, bookingId));
    if (!booking) {
      await conn.rollback();
      return res.status(404).json({ success: false, message: 'Booking not found or not assigned to this technician' });
    }
    if (!canChargeBooking(booking)) {
      await conn.rollback();
      return res.status(409).json({ success: false, message: CHARGE_WINDOW_MESSAGE });
    }

    const [[charge]] = await conn.execute(
      `SELECT charge_id, product_id, price FROM ip_booking_additional_charges
       WHERE charge_id = ? AND booking_id = ? AND deleted_at IS NULL FOR UPDATE`,
      [chargeId, bookingId]
    );
    if (!charge) {
      await conn.rollback();
      return res.status(404).json({ success: false, message: 'This charge was already removed' });
    }

    const price      = round2(parseFloat(charge.price) || 0);
    const oldTotal   = parseFloat(booking.total_amount) || 0;
    const amountPaid = parseFloat(booking.amount_paid) || 0;
    const newTotal   = round2(oldTotal - price);
    if (newTotal < amountPaid - 0.01) {
      await conn.rollback();
      return res.status(400).json({ success: false, message: `₹${amountPaid} is already paid — the total can't go below that` });
    }
    const newCharge = Math.max(0, round2((parseFloat(booking.additional_charge_amount) || 0) - price));
    const { amountDue, paymentStatus } = chargeTotals(booking, newTotal);

    await conn.execute('UPDATE ip_booking_additional_charges SET deleted_at = NOW() WHERE charge_id = ?', [chargeId]);
    await conn.execute(
      `UPDATE ip_bookings
          SET additional_charge_amount = ?, total_amount = ?, amount_due = ?, payment_status = ?, updated_at = NOW()
        WHERE booking_id = ?`,
      [newCharge, newTotal, amountDue, paymentStatus, bookingId]
    );
    await conn.commit();

    tlog(`[CHARGE_PACKAGE_REMOVED] technician_id=${technicianId} booking_id=${bookingId} charge_id=${chargeId} product=${charge.product_id} -₹${price} total=₹${oldTotal}→₹${newTotal} due=₹${amountDue}`);
    res.json({ success: true, additionalChargeAmount: newCharge, totalAmount: newTotal, amountDue, paymentStatus });
  } catch (err) {
    try { await conn.rollback(); } catch (_) {}
    console.error('❌ removeAdditionalCharge FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  } finally {
    conn.release();
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
        doctorName = null,
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

      // INSERT new booking — status='confirmed', technician directly assigned.
      // booking_ref is derived below from the row's own booking_id (same
      // booking_id + ip_settings 'booking_ref_offset' scheme used by every
      // other booking-creation path — see bookingController.js's own
      // comment on why), not known until after the INSERT assigns one.
      // Previously this used `BC${Date.now()}...`, the same
      // timestamp-collision risk the other paths were already fixed for
      // (see change_booking_ref_to_sequential.sql) — this path was simply
      // missed until a real mismatched ref surfaced it.
      const txnRef = `TXN${Date.now()}${String(refSeq)}${Math.random().toString(36).slice(2, 4).toUpperCase()}`;
      const [bRes] = await conn.execute(
        `INSERT INTO ip_bookings
           (booking_ref, client_id, branch_id, booking_date, lab_slot_id, available_slot_id,
            booking_type, status, total_amount, discount_amount,
            amount_paid, amount_due, source_channel, notes, referring_doctor,
            collection_address, postal_code, city,
            collection_latitude, collection_longitude,
            patient_id, patient_id_ref, product_id,
            payment_status, visit_group_id, technician_id, technician_name,
            start_datetime, end_datetime, created_by, created_at)
         VALUES (NULL, ?, ?, ?, NULL, ?, 'home_collection', 'confirmed', ?, 0, 0, ?,
                 'technician_app', NULL, ?, ?, ?, ?, ?, ?, ?, ?, 0, 'unpaid', ?, ?, ?,
                 NOW(), NOW(), ?, NOW())`,
        [parent.client_id, parent.branch_id || null, parent.booking_date,
         parent.available_slot_id || null, totalAmount, totalAmount,
         doctorName || null,
         parent.collection_address, parent.postal_code, parent.city,
         parent.collection_latitude, parent.collection_longitude,
         patientId, patientIdRef,
         visitGroupId, technicianId, technicianName,
         technicianId]
      );
      const newBookingId = bRes.insertId;
      const bookingRef = String(newBookingId + parseInt(settings.get('booking_ref_offset', '0'), 10));
      await conn.execute('UPDATE ip_bookings SET booking_ref = ? WHERE booking_id = ?', [bookingRef, newBookingId]);

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
      // Mirror into ip_patient_bookings — its row for this new booking was
      // just inserted above (patient → booking link), so it's guaranteed
      // to exist here.
      await conn.execute(
        `UPDATE ip_patient_bookings SET collection_status = 'arrived' WHERE booking_id = ?`,
        [newBookingId]
      );

      results.push({ newBookingId, bookingRef, patientId, totalAmount });
      console.log(`   ✅ addVisitMember — booking_id=${newBookingId} ref=${bookingRef}`);
    }

    await conn.commit();
    const totalVisitAmount = results.reduce((s, r) => s + r.totalAmount, 0);
    console.log(`✅ addVisitMember — ${results.length} member(s) added parent=${parentBookingId} visit_group=${visitGroupId}`);

    // No individual Jayamala sync here — a newly added family member now
    // reaches the client server only once, in the consolidated
    // visit_completed request fired from verifyBookingOtp, which resolves
    // every booking sharing this visit_group_id (including these new ones)
    // at that time. These bookings are still saved to ip_bookings/
    // ip_booking_items above exactly as before; only the immediate
    // per-action sync was removed.
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

// ── POST /api/technicians/remove-visit-member ────────────────────────────────
// Removes one family member the technician added during the visit.
// Body: { bookingId }   (bookingId = the member's own booking)
//
// Who can be removed:
//   • only members the technician added (source_channel 'technician_app').
//     Family members booked by the customer stay with the booking.
//   • only while none of that member's samples are collected and nothing has
//     been paid for it.
//   • never the main member (the visit's first booking, which also carries the
//     service charge).
//
// The member is deleted outright — booking, tests, charge packages, document
// rows, the patient link, the technician job and the unpaid pay-later row —
// as if never added. The patient (ip_patients) is kept: they are still the
// customer's family member and can be booked again. Uploaded files are left in
// uploads/, as with every other document removal. A technician-added member
// reaches ASMX only at handover (visit_completed), so nothing to cancel there.
// One line in technician.log is the only trace.
const MEMBER_COLLECTED_STATUSES = [
  'sample_collected', 'all_collected', 'otp_verified', 'collected',
  'handed_to_lab_pending', 'handed_to_lab', 'sample_received', 'test_in_progress',
  'report_ready', 'completed',
];

// Child rows first, the booking last.
const MEMBER_DELETE_SQL = [
  'DELETE FROM ip_booking_items WHERE booking_id = ?',
  'DELETE FROM ip_booking_additional_charges WHERE booking_id = ?',
  'DELETE FROM ip_booking_documents WHERE booking_id = ?',
  'DELETE FROM ip_patient_bookings WHERE booking_id = ?',
  'DELETE FROM ip_technician_collection WHERE booking_id = ?',
  'DELETE FROM ip_payment_transactions WHERE booking_id = ?',
];

exports.removeVisitMember = async (req, res) => {
  const technicianId = req.user.id;
  const bookingId    = Number(req.body?.bookingId);

  if (!Number.isInteger(bookingId) || bookingId <= 0) {
    return res.status(400).json({ success: false, message: 'bookingId is required' });
  }

  try {
    const [[member]] = await db.execute(
      `SELECT b.booking_id, b.booking_ref, b.visit_group_id, b.status, b.source_channel,
              COALESCE(b.amount_paid, 0) AS amount_paid, b.service_charge_status,
              p.patient_name
       FROM ip_bookings b
       LEFT JOIN ip_patients p ON p.patient_id = b.patient_id
       WHERE b.booking_id = ? AND b.deleted_at IS NULL
       LIMIT 1`,
      [bookingId]
    );
    if (!member || !member.visit_group_id) {
      return res.status(404).json({ success: false, message: 'Visit member not found' });
    }
    const name = member.patient_name || 'This member';

    // The technician must be on this visit.
    const [[onVisit]] = await db.execute(
      `SELECT 1 AS ok
       FROM ip_technician_collection tc
       JOIN ip_bookings b ON b.booking_id = tc.booking_id
       WHERE tc.technician_id = ? AND b.visit_group_id = ? AND b.deleted_at IS NULL
         AND tc.collection_status != 'cancelled'
       LIMIT 1`,
      [technicianId, member.visit_group_id]
    );
    if (!onVisit) {
      return res.status(404).json({ success: false, message: 'Visit member not found' });
    }

    // Family members from the customer's booking stay.
    if (member.source_channel !== 'technician_app') {
      return res.status(400).json({ success: false, code: 'BOOKED_BY_CUSTOMER', message: `${name} was booked by the customer and can't be removed` });
    }

    // The main member holds the visit (and its service charge) together.
    const [[main]] = await db.execute(
      `SELECT booking_id FROM ip_bookings
       WHERE visit_group_id = ? AND deleted_at IS NULL AND status != 'cancelled'
       ORDER BY booking_id ASC LIMIT 1`,
      [member.visit_group_id]
    );
    if (!main || Number(main.booking_id) === bookingId || member.service_charge_status != null) {
      return res.status(400).json({ success: false, code: 'MAIN_MEMBER', message: `${name} is the main patient of this visit and can't be removed` });
    }

    // Samples already taken → keep the member.
    const [[collected]] = await db.execute(
      `SELECT
         (SELECT tc.collection_status FROM ip_technician_collection tc WHERE tc.booking_id = ? LIMIT 1) AS collection_status,
         (SELECT COUNT(*) FROM ip_booking_items bi
           WHERE bi.booking_id = ? AND (bi.item_status = 'completed' OR bi.collected_at IS NOT NULL)) AS collected_items`,
      [bookingId, bookingId]
    );
    if (MEMBER_COLLECTED_STATUSES.includes(collected?.collection_status)
        || MEMBER_COLLECTED_STATUSES.includes(member.status)
        || Number(collected?.collected_items ?? 0) > 0) {
      return res.status(400).json({ success: false, code: 'SAMPLES_COLLECTED', message: `Samples are already collected for ${name} — can't remove` });
    }

    // Anything paid → keep the member; money is never deleted.
    const [[paid]] = await db.execute(
      `SELECT COALESCE(SUM(amount_paid), 0) AS paid FROM ip_payment_transactions
       WHERE booking_id = ? AND (is_refund = 0 OR is_refund IS NULL)`,
      [bookingId]
    );
    if (Number(member.amount_paid) > 0 || Number(paid?.paid ?? 0) > 0) {
      return res.status(400).json({ success: false, code: 'MEMBER_PAID', message: `Payment already collected for ${name} — can't remove` });
    }

    const conn = await db.getConnection();
    try {
      await conn.beginTransaction();
      for (const sql of MEMBER_DELETE_SQL) {
        await conn.execute(sql, [bookingId]);
      }
      // Re-checks inside the transaction: still technician-added and unpaid.
      const [del] = await conn.execute(
        `DELETE FROM ip_bookings
         WHERE booking_id = ? AND source_channel = 'technician_app'
           AND COALESCE(amount_paid, 0) = 0`,
        [bookingId]
      );
      if (del.affectedRows === 0) {
        await conn.rollback();
        return res.status(400).json({ success: false, message: `${name} can no longer be removed — refresh and try again` });
      }
      await conn.commit();
    } catch (txErr) {
      await conn.rollback();
      throw txErr;
    } finally {
      conn.release();
    }

    tlog(`[REMOVE_VISIT_MEMBER] deleted — technician_id=${technicianId} booking_id=${bookingId} ref=${member.booking_ref} ` +
         `patient=${member.patient_name ?? '—'} visit_group=${member.visit_group_id} main=${main.booking_id}`);

    res.json({ success: true, message: `${name} removed from this visit` });
  } catch (e) {
    tlog(`[REMOVE_VISIT_MEMBER] ERROR technician_id=${technicianId} booking_id=${bookingId}: ${e.message}`);
    console.error('[removeVisitMember]', e.message);
    res.status(500).json({ success: false, message: 'Server error' });
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
  const { bookingId, otp, noPaymentReason } = req.body;

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
      // 400, not 401: a wrong code is bad input. The app treats any 401 as
      // "signed out on another device" and logs the technician out.
      return res.status(400).json({
        success: false,
        message: remaining > 0
          ? `Incorrect OTP. ${remaining} attempt${remaining === 1 ? '' : 's'} remaining.`
          : 'Too many failed attempts. Please resend OTP.',
        attemptsExhausted: remaining <= 0,
      });
    }

    // Nothing paid toward the visit yet (and something is due): the OTP may
    // still be verified, but only with a reason — saved like a partial-payment
    // reason (ip_bookings.partial_payment_reason, sent to the ASMX at Handed
    // to Lab). Checked before the OTP is used up, so the technician can add
    // the reason and try again with the same OTP.
    const reasonText = String(noPaymentReason ?? '').trim().slice(0, 255);
    const [[visitPay]] = await db.execute(
      `SELECT COALESCE(SUM(b.amount_paid), 0) AS paid, COALESCE(SUM(b.amount_due), 0) AS due
       FROM ip_bookings b
       JOIN ip_bookings p ON p.booking_id = ?
       WHERE b.deleted_at IS NULL AND b.status != 'cancelled'
         AND (b.booking_id = p.booking_id
              OR (p.visit_group_id IS NOT NULL AND b.visit_group_id = p.visit_group_id))`,
      [bookingId]
    );
    const nothingPaid = Number(visitPay?.paid ?? 0) <= 0 && Number(visitPay?.due ?? 0) > 0;
    if (nothingPaid && !reasonText) {
      return res.status(400).json({
        success: false, code: 'NO_PAYMENT_REASON_REQUIRED',
        message: 'No payment has been collected. Please enter the reason to verify the OTP.',
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

    // Mirror into ip_patient_bookings — wrapped defensively so a failure
    // here never turns an already-successful OTP verification into an
    // error response.
    try {
      await db.execute(
        `UPDATE ip_patient_bookings SET collection_status = 'otp_verified' WHERE booking_id = ?`,
        [bookingId]
      );
    } catch (e) {
      console.error(`❌ [verifyBookingOtp] ip_patient_bookings mirror failed booking=${bookingId}: ${e.message}`);
    }

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
        await db.execute(
          `UPDATE ip_patient_bookings pb
           JOIN ip_bookings b ON b.booking_id = pb.booking_id
           SET pb.collection_status = 'otp_verified'
           WHERE b.visit_group_id = ? AND b.booking_id != ? AND b.deleted_at IS NULL`,
          [vgRow.visit_group_id, bookingId]
        );
      }
    } catch (e) {
      console.error(`❌ [verifyBookingOtp] sibling cascade failed booking=${bookingId}: ${e.message}`);
    }

    // The ASMX visit sync (TechnicianVisitCompleted) is no longer sent here —
    // it is sent at the Handed to Lab step instead, together with the
    // handover branch and received-by name (socket/bookingSocket.js,
    // 'handed_to_lab' → syncVisitCompletionToClient).

    if (nothingPaid) {
      try {
        await savePartialReason(bookingId, reasonText);
        tlog(`[OTP_WITHOUT_PAYMENT] technician_id=${technicianId} booking_id=${bookingId} reason="${reasonText}"`);
      } catch (reasonErr) {
        console.error(`⚠️  verifyBookingOtp — no-payment reason not saved booking_id=${bookingId}: ${reasonErr.message}`);
      }
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