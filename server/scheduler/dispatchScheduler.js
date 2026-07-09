'use strict';
// dispatchScheduler.js
//
// Runs every minute.  For each booking that is:
//   • status = 'scheduled'
//   • booking_date = today (IST)
//   • NOW() is within DISPATCH_LEAD_MINUTES of the appointment slot time
//     (or no slot was chosen — dispatch immediately on the booking date)
//
// It atomically moves the booking to status='pending' then fires the full
// dispatch engine via triggerScheduledDispatch (Lane 1 → Lane 2 → Lane 3).

const cron = require('node-cron');
const db   = require('../config/db');
const { triggerScheduledDispatch } = require('../socket/bookingSocket');

module.exports = function initDispatchScheduler(io) {
  const LEAD_MIN = parseInt(process.env.DISPATCH_LEAD_MINUTES ?? '60', 10);

  cron.schedule('* * * * *', async () => {
    try {
      // Find scheduled bookings on today's date whose slot time is within
      // LEAD_MIN minutes from now (or have no slot — dispatch immediately).
      const [rows] = await db.execute(
        `SELECT
           b.booking_id,
           b.patient_id,
           b.branch_id,
           b.booking_type,
           b.collection_address,
           b.collection_latitude   AS patient_lat,
           b.collection_longitude  AS patient_lng,
           b.available_slot_id,
           p.patient_name,
           p.patient_mobile,
           COALESCE(ts.slot_id, ls.slot_id) AS slot_id,
           ias.slot_time
         FROM ip_bookings b
         JOIN ip_patients p   ON p.patient_id  = b.patient_id
         LEFT JOIN ip_available_slots  ias ON ias.available_slot_id     = b.available_slot_id
         LEFT JOIN ip_technician_slots ts  ON ts.tech_slot_id           = ias.technician_slot_id
         LEFT JOIN ip_lab_slots        ls  ON ls.lab_slot_id            = ias.lab_slot_id
         WHERE b.status       = 'scheduled'
           AND b.booking_date = CURDATE()
           AND (
             ias.slot_time IS NULL
             OR TIMESTAMPDIFF(MINUTE, NOW(),
                  CONCAT(CURDATE(), ' ', ias.slot_time)) <= ?
           )`,
        [LEAD_MIN]
      );

      for (const row of rows) {
        const bid = row.booking_id;

        // Atomically claim: only one cron tick will succeed per booking.
        const [upd] = await db.execute(
          `UPDATE ip_bookings
           SET status = 'pending', updated_at = NOW()
           WHERE booking_id = ? AND status = 'scheduled'`,
          [bid]
        );
        if (upd.affectedRows === 0) continue; // another tick already claimed it

        const slotTime = row.slot_time
          ? String(row.slot_time).substring(0, 5) // "HH:MM:SS" → "HH:MM"
          : null;

        // booking_type in DB is 'home_collection'; dispatch engine expects 'lab'
        const dispatchType = (row.booking_type === 'home_collection') ? 'lab' : (row.booking_type ?? 'lab');

        console.log(
          `[Scheduler] Dispatching booking_id=${bid} ` +
          `slot_time=${slotTime ?? 'none'} type=${dispatchType}`
        );

        await triggerScheduledDispatch({
          bookingId:       bid,
          patientId:       row.patient_id,
          patientName:     row.patient_name  ?? 'Patient',
          patientMobile:   row.patient_mobile ?? '',
          patientAddress:  row.collection_address ?? 'Home Collection',
          patientLat:      row.patient_lat  ?? null,
          patientLng:      row.patient_lng  ?? null,
          hospital:        'MicroLab Home Collection',
          bookingType:     dispatchType,
          branchId:        row.branch_id    ?? null,
          slotId:          row.slot_id      ?? null,
          slotLabel:       null,
          appointmentTime: slotTime,
        }, io);
      }
    } catch (err) {
      console.error('[Scheduler] dispatchScheduler tick error:', err.message ?? err,
        '\n  code:', err.code, '| sqlState:', err.sqlState, '| sql:', err.sql?.substring(0, 120));
    }
  });

  console.log(`[Scheduler] Dispatch scheduler started — lead window: ${LEAD_MIN} min, checks every minute`);
};
