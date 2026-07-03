const db   = require('../config/db');
const fs   = require('fs');
const path = require('path');

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
    const uploadedBy = req.user.user_id;
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
    res.status(201).json({ success: true, docIds: insertedIds });
  } catch (err) {
    writeLog(`[savePrescription] ERROR — ${err.message} | code=${err.code} | sql=${err.sql}`);
    console.error('savePrescription error:', err.message);
    res.status(500).json({ success: false, message: 'Server error', debug: err.message });
  }
};
