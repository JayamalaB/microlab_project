const db   = require('../config/db');
const fs   = require('fs');
const path = require('path');
const { syncBookingToClient } = require('../services/clientSync');

const LOG_FILE = path.join(__dirname, '..', 'logs', 'prescriptions.log');
function writeLog(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false }).replace(',', '') + ' IST';
  const line = `[${ist}] ${msg}\n`;
  process.stdout.write(line);
  fs.appendFileSync(LOG_FILE, line, 'utf8');
}

// ── POST /api/prescriptions ───────────────────────────────────────────────────
exports.savePrescription = async (req, res) => {
  const { bookingId, patientId, bookingItemId = null, imageUrls } = req.body;

  writeLog(`[savePrescription] received — bookingId=${bookingId} patientId=${patientId} bookingItemId=${bookingItemId} imageUrls=${JSON.stringify(imageUrls)}`);

  if (!bookingId || !patientId || !Array.isArray(imageUrls) || imageUrls.length === 0) {
    writeLog(`[savePrescription] validation failed — bookingId=${bookingId} patientId=${patientId} imageUrls=${JSON.stringify(imageUrls)}`);
    return res.status(400).json({
      success: false,
      message: 'bookingId, patientId and imageUrls[] are required',
    });
  }

  try {
    // Customer JWT uses 'user_id'; technician JWT uses 'userId' — handle both
    const uploadedBy = req.user.user_id ?? req.user.userId ?? null;
    writeLog(`[savePrescription] uploadedBy=user_id:${uploadedBy}`);

    const insertedIds = [];
    for (const url of imageUrls) {
      const fileName = url.split('/').pop().split('?')[0] || 'prescription';
      writeLog(`[savePrescription] inserting — url=${url} fileName=${fileName} bookingItemId=${bookingItemId}`);
      const [result] = await db.execute(
        `INSERT INTO ip_booking_documents
           (booking_id, booking_item_id, patient_id, file_path, file_name,
            file_description, uploaded_by, doc_status, created_at)
         VALUES (?, ?, ?, ?, ?, 'prescription', ?, 'pending_review', NOW())`,
        [bookingId, bookingItemId ?? null, patientId, url, fileName, uploadedBy]
      );
      insertedIds.push(result.insertId);
      writeLog(`[savePrescription] inserted doc_id=${result.insertId}`);
    }

    writeLog(`[savePrescription] done — booking=${bookingId} images=${imageUrls.length} doc_ids=${insertedIds.join(',')}`);

    // Sync to client server — this endpoint is called from both the
    // customer app and the technician app (see the uploadedBy resolution
    // above). Customer uploads still sync immediately here, same as
    // always — customer bookings never go through the technician OTP flow,
    // so this is their only route to reach the client server. Technician
    // uploads are deliberately NOT synced here: that data now reaches the
    // client server only once, in the consolidated visit_completed request
    // fired from verifyBookingOtp, which reads the most recent prescription
    // per test directly from the DB at that time.
    const isTechnicianUpload = req.user.userId != null;
    if (!isTechnicianUpload) {
      syncBookingToClient(Number(bookingId), {
        mobile: req.user.mobile,
        type:   'patient_user',
        action: 'prescription_uploaded',
      }).catch(err => console.error(`[clientSync] savePrescription sync failed booking_id=${bookingId}:`, err.message));
    }

    res.status(201).json({ success: true, docIds: insertedIds });
  } catch (err) {
    writeLog(`[savePrescription] ERROR — ${err.message} | code=${err.code} | sql=${err.sql}`);
    console.error('savePrescription error:', err.message);
    res.status(500).json({ success: false, message: 'Server error', debug: err.message });
  }
};

// ── GET /api/prescriptions/:bookingId ─────────────────────────────────────────
// Returns documents for this booking AND any sibling bookings sharing the same
// visit_group_id. Family members added at booking time each get their own
// booking_id (see createFamilyBooking) — their prescriptions are stored under
// THAT booking_id, not the parent's, so a plain booking_id match alone would
// silently miss them. Each doc is tagged with patient_id/booking_id so the
// caller can attribute it to the correct patient instead of assuming every
// document belongs to this booking's own primary patient.
exports.getByBooking = async (req, res) => {
  const { bookingId } = req.params;
  writeLog(`[getByBooking] received — bookingId=${bookingId}`);
  try {
    const [rows] = await db.execute(
      `SELECT bd.doc_id, bd.file_path, bd.file_name, bd.file_description,
              bd.doc_status, bd.created_at, bd.booking_id, bd.patient_id
       FROM ip_booking_documents bd
       WHERE (bd.booking_id = ?
          OR bd.booking_id IN (
            SELECT b2.booking_id
            FROM ip_bookings b1
            JOIN ip_bookings b2 ON b2.visit_group_id = b1.visit_group_id
                                AND b2.booking_id    != b1.booking_id
                                AND b2.deleted_at    IS NULL
            WHERE b1.booking_id = ? AND b1.visit_group_id IS NOT NULL
          ))
         AND bd.file_description = 'prescription'
       ORDER BY bd.created_at ASC`,
      [bookingId, bookingId]
    );
    writeLog(`[getByBooking] found=${rows.length} doc(s) — booking_ids=[${[...new Set(rows.map(r => r.booking_id))].join(',')}] patient_ids=[${[...new Set(rows.map(r => r.patient_id))].join(',')}]`);
    res.json({ success: true, docs: rows });
  } catch (err) {
    writeLog(`[getByBooking] ERROR — ${err.message} | code=${err.code} | sql=${err.sql}`);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── PATCH /api/prescriptions/:docId/verify ────────────────────────────────────
exports.verifyDoc = async (req, res) => {
  const { docId } = req.params;
  writeLog(`[verifyDoc] docId=${docId}`);
  try {
    const [result] = await db.execute(
      `UPDATE ip_booking_documents SET doc_status = 'verified' WHERE doc_id = ?`,
      [docId]
    );
    if (result.affectedRows === 0) {
      return res.status(404).json({ success: false, message: 'Document not found' });
    }
    writeLog(`[verifyDoc] doc_id=${docId} marked verified`);
    res.json({ success: true });
  } catch (err) {
    writeLog(`[verifyDoc] ERROR — ${err.message}`);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── DELETE /api/prescriptions/:docId ─────────────────────────────────────────
exports.deleteDoc = async (req, res) => {
  const { docId } = req.params;
  writeLog(`[deleteDoc] docId=${docId}`);
  try {
    const [result] = await db.execute(
      `DELETE FROM ip_booking_documents WHERE doc_id = ?`,
      [docId]
    );
    if (result.affectedRows === 0) {
      return res.status(404).json({ success: false, message: 'Document not found' });
    }
    writeLog(`[deleteDoc] doc_id=${docId} deleted`);
    res.json({ success: true });
  } catch (err) {
    writeLog(`[deleteDoc] ERROR — ${err.message}`);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};
