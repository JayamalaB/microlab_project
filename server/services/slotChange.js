'use strict';
const db = require('../config/db');

// Puts a booking's time back on sale, unless another active booking still uses
// it (a family visit shares one). Only the update that actually reopens the
// time lowers the count, so it can't be lowered twice.
async function releaseSlotIfUnused(availableSlotId) {
  if (!availableSlotId) return;
  const [inUse] = await db.execute(
    `SELECT 1 FROM ip_bookings
     WHERE available_slot_id = ? AND status != 'cancelled' AND deleted_at IS NULL LIMIT 1`,
    [availableSlotId]
  );
  if (inUse.length > 0) return;

  const [reopened] = await db.execute(
    `UPDATE ip_available_slots SET is_available = 1, updated_at = NOW()
     WHERE available_slot_id = ? AND is_available = 0`,
    [availableSlotId]
  );
  if (reopened.affectedRows !== 1) return;

  const [[slot]] = await db.execute(
    'SELECT technician_slot_id, lab_slot_id FROM ip_available_slots WHERE available_slot_id = ?',
    [availableSlotId]
  );
  if (slot?.technician_slot_id) {
    await db.execute(
      'UPDATE ip_technician_slots SET booked_count = GREATEST(0, booked_count - 1) WHERE tech_slot_id = ?',
      [slot.technician_slot_id]
    );
  } else if (slot?.lab_slot_id) {
    await db.execute(
      'UPDATE ip_lab_slots SET booked_count = GREATEST(0, booked_count - 1) WHERE lab_slot_id = ?',
      [slot.lab_slot_id]
    );
  }
}

// Moves a booking, with its whole family visit, onto another free time and
// gives the old time back. `slot` is { available_slot_id, technician_slot_id }.
// Returns false, changing nothing, if that time has just been taken.
async function moveBookingToSlot(bookingId, slot) {
  const [claimed] = await db.execute(
    `UPDATE ip_available_slots SET is_available = 0, updated_at = NOW()
     WHERE available_slot_id = ? AND is_available = 1`,
    [slot.available_slot_id]
  );
  if (claimed.affectedRows === 0) return false;

  const [[booking]] = await db.execute(
    'SELECT available_slot_id, visit_group_id FROM ip_bookings WHERE booking_id = ? LIMIT 1',
    [bookingId]
  );
  await db.execute(
    `UPDATE ip_bookings SET available_slot_id = ?, updated_at = NOW()
     WHERE (booking_id = ? OR visit_group_id = ?) AND status != 'cancelled' AND deleted_at IS NULL`,
    [slot.available_slot_id, bookingId, booking?.visit_group_id ?? null]
  );
  if (slot.technician_slot_id) {
    await db.execute(
      'UPDATE ip_technician_slots SET booked_count = booked_count + 1 WHERE tech_slot_id = ?',
      [slot.technician_slot_id]
    );
  }
  await releaseSlotIfUnused(booking?.available_slot_id);
  return true;
}

module.exports = { releaseSlotIfUnused, moveBookingToSlot };
