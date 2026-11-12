'use strict';
const db = require('../config/db');

// Who may act on what, for a logged-in request. Each check runs after auth or
// rolloutAuth. req.user is only missing when rolloutAuth let a tokenless
// request through (see that file), and then there is nobody to check.

// Technician-only routes. A customer token also carries an `id` (their
// patient_id), which must never be read as a technician_id.
function requireTechnician(req, res, next) {
  if (!req.user || req.user.role === 'technician') return next();
  return res.status(403).json({ success: false, message: 'Technician access only' });
}

// /api/technicians/:technicianId/... — only that technician.
function requireSameTechnician(req, res, next) {
  if (!req.user) return next();
  if (req.user.role === 'technician' && Number(req.user.id) === Number(req.params.technicianId)) return next();
  return res.status(403).json({ success: false, message: 'Not allowed' });
}

// A technician reaches a booking they were offered, are assigned to, or that
// belongs to a family visit they are assigned to. A customer reaches their own
// account's bookings. 404, not 403, so booking ids can't be probed.
async function requireBookingAccess(req, res, next) {
  if (!req.user) return next();
  const { bookingId } = req.params;
  const { role, id, client_id: clientId } = req.user;

  try {
    const [rows] = role === 'technician'
      ? await db.execute(
          `SELECT 1 FROM ip_bookings b
           WHERE b.booking_id = ?
             AND (
               EXISTS (SELECT 1 FROM ip_technician_collection tc
                       WHERE tc.booking_id = b.booking_id AND tc.technician_id = ?)
               OR EXISTS (SELECT 1 FROM ip_booking_requests br
                          WHERE br.booking_id = b.booking_id AND br.technician_id = ?)
               OR (b.visit_group_id IS NOT NULL AND EXISTS (
                     SELECT 1 FROM ip_bookings sibling
                     JOIN ip_technician_collection tc ON tc.booking_id = sibling.booking_id
                     WHERE sibling.visit_group_id = b.visit_group_id AND tc.technician_id = ?))
             )
           LIMIT 1`,
          [bookingId, id, id, id]
        )
      : await db.execute(
          `SELECT 1 FROM ip_bookings WHERE booking_id = ? AND (client_id = ? OR patient_id = ?) LIMIT 1`,
          [bookingId, clientId ?? null, id ?? null]
        );
    if (rows.length > 0) return next();
    return res.status(404).json({ success: false, message: 'Booking not found' });
  } catch (err) {
    console.error('[access] booking check failed:', err.message);
    return res.status(500).json({ success: false, message: 'Server error' });
  }
}

// /api/bookings/patient/:patientId — a patient on the customer's own account.
async function requirePatientAccess(req, res, next) {
  if (!req.user) return next();
  if (req.user.role === 'technician') {
    return res.status(403).json({ success: false, message: 'Not allowed' });
  }
  try {
    const [rows] = await db.execute(
      `SELECT 1 FROM ip_patients WHERE patient_id = ? AND client_id = ? LIMIT 1`,
      [req.params.patientId, req.user.client_id ?? null]
    );
    if (rows.length > 0) return next();
    return res.status(404).json({ success: false, message: 'Patient not found' });
  } catch (err) {
    console.error('[access] patient check failed:', err.message);
    return res.status(500).json({ success: false, message: 'Server error' });
  }
}

module.exports = { requireTechnician, requireSameTechnician, requireBookingAccess, requirePatientAccess };
