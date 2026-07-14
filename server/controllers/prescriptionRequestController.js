const db = require('../config/db');

// ── POST /api/prescription-requests ──────────────────────────────────────────
// Patient submits prescription image URLs + optional note.
// Files are already uploaded via POST /api/upload before calling this.
exports.submit = async (req, res) => {
  const clientId  = req.user.client_id;
  const { file_paths, notes, patient_id } = req.body;

  // Use the specific family member's patient_id if provided, else fall back to logged-in user
  const patientId = patient_id ?? req.user.id;

  if (!Array.isArray(file_paths) || file_paths.length === 0) {
    return res.status(400).json({ success: false, message: 'file_paths array is required' });
  }

  try {
    const [result] = await db.execute(
      `INSERT INTO ip_prescription_requests
         (patient_id, client_id, file_paths, notes, status, created_at)
       VALUES (?, ?, ?, ?, 'pending', NOW())`,
      [patientId, clientId, JSON.stringify(file_paths), notes ?? null]
    );
    res.status(201).json({ success: true, request_id: result.insertId });
  } catch (err) {
    console.error('❌ prescriptionRequest.submit FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── GET /api/prescription-requests/mine ──────────────────────────────────────
// Returns all prescription requests for the logged-in account (all family members).
exports.getMine = async (req, res) => {
  const clientId  = req.user.client_id;
  const patientId = req.query.patient_id ? Number(req.query.patient_id) : null;
  try {
    const whereExtra = patientId ? ' AND r.patient_id = ?' : '';
    const params     = patientId ? [clientId, patientId] : [clientId];
    const [rows] = await db.execute(
      `SELECT r.request_id, r.file_paths, r.notes, r.status, r.admin_notes,
              r.converted_booking_id, r.created_at,
              p.patient_name
       FROM ip_prescription_requests r
       LEFT JOIN ip_patients p ON p.patient_id = r.patient_id
       WHERE r.client_id = ?${whereExtra}
       ORDER BY r.created_at DESC
       LIMIT 20`,
      params
    );

    const requests = rows.map(r => ({
      ...r,
      file_paths: typeof r.file_paths === 'string' ? JSON.parse(r.file_paths) : r.file_paths,
    }));

    res.json({ success: true, requests });
  } catch (err) {
    console.error('❌ prescriptionRequest.getMine FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};
