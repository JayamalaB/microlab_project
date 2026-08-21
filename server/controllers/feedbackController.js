const db = require('../config/db');

// ── POST /api/feedback ────────────────────────────────────────────────────────
// Submit feedback for a completed booking.
exports.submitFeedback = async (req, res) => {
  const clientId  = req.user.client_id;
  const patientId = req.user.id;
  const { booking_id, overall_rating, feedback_comments } = req.body;

  if (!booking_id || !overall_rating) {
    return res.status(400).json({ success: false, message: 'booking_id and overall_rating are required' });
  }
  if (overall_rating < 1 || overall_rating > 5) {
    return res.status(400).json({ success: false, message: 'overall_rating must be between 1 and 5' });
  }

  try {
    // Verify booking exists, belongs to this account (client_id covers all family members), and is completed
    const [[booking]] = await db.execute(
      `SELECT b.booking_id, b.status, b.branch_id, b.patient_id, tc.technician_id
       FROM ip_bookings b
       LEFT JOIN ip_technician_collection tc ON tc.booking_id = b.booking_id
       WHERE b.booking_id = ?
         AND (b.client_id = ? OR b.patient_id = ?)
         AND b.deleted_at IS NULL
       LIMIT 1`,
      [booking_id, clientId, patientId]
    );

    if (!booking) {
      return res.status(404).json({ success: false, message: 'Booking not found' });
    }
    if (booking.status !== 'completed' && booking.status !== 'collected') {
      return res.status(400).json({ success: false, message: 'Feedback can only be submitted once the sample has been collected' });
    }

    // Check for duplicate feedback
    const [[existing]] = await db.execute(
      `SELECT feedback_id FROM ip_feedback WHERE booking_id = ? LIMIT 1`,
      [booking_id]
    );
    if (existing) {
      return res.status(409).json({ success: false, message: 'Feedback already submitted for this booking' });
    }

    const [result] = await db.execute(
      `INSERT INTO ip_feedback
         (booking_id, patient_id, branch_id, technician_id, overall_rating, feedback_comments, created_at)
       VALUES (?, ?, ?, ?, ?, ?, NOW())`,
      [
        booking_id,
        booking.patient_id,
        booking.branch_id ?? null,
        booking.technician_id ?? null,
        overall_rating,
        feedback_comments ?? null,
      ]
    );

    res.status(201).json({ success: true, feedback_id: result.insertId });
  } catch (err) {
    console.error('❌ submitFeedback FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── GET /api/feedback/booking/:bookingId ──────────────────────────────────────
// Check if feedback exists for a booking.
exports.getFeedbackByBooking = async (req, res) => {
  const { bookingId } = req.params;
  try {
    const [[row]] = await db.execute(
      `SELECT feedback_id, overall_rating, feedback_comments, created_at
       FROM ip_feedback WHERE booking_id = ? LIMIT 1`,
      [bookingId]
    );
    if (!row) return res.json({ success: true, feedback: null });
    res.json({ success: true, feedback: row });
  } catch (err) {
    console.error('❌ getFeedbackByBooking FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};
