const db = require('../config/db');

// Stores the technician's partial-payment reason: on the booking itself, or
// on every booking of its visit when it is part of a family visit (the reason
// applies to all members, whichever member's payment was partial). Blank →
// nothing changes, so a full payment never clears or overwrites a reason.
async function savePartialReason(bookingId, reason) {
  const text = String(reason ?? '').trim().slice(0, 255);
  if (!text) return;
  await db.execute(
    `UPDATE ip_bookings b
     LEFT JOIN ip_bookings primary_b ON primary_b.booking_id = ?
     SET b.partial_payment_reason = ?, b.updated_at = NOW()
     WHERE b.deleted_at IS NULL
       AND (b.booking_id = ?
            OR (primary_b.visit_group_id IS NOT NULL AND b.visit_group_id = primary_b.visit_group_id))`,
    [bookingId, text, bookingId]
  );
}

module.exports = { savePartialReason };
