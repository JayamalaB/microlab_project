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
//
// A family visit moves together and dispatches once, on its first active
// member. A Lab Visit needs no technician: it moves to 'pending', the status
// a same-day Lab Visit has, and is not dispatched.
//
// A same-day booking is normally dispatched by the customer's app the moment
// it is created. If the app closed first, this picks it up a couple of minutes
// later, once.

const cron = require('node-cron');
const db   = require('../config/db');
const { triggerScheduledDispatch, redispatchBooking } = require('../socket/bookingSocket');

const startedHere = new Set(); // bookings this job started, so each is tried once

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
           b.visit_group_id,
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
           AND b.deleted_at IS NULL
           AND (
             ias.slot_time IS NULL
             OR TIMESTAMPDIFF(MINUTE, NOW(),
                  CONCAT(CURDATE(), ' ', ias.slot_time)) <= ?
           )
         ORDER BY b.booking_id ASC`,
        [LEAD_MIN]
      );

      for (const row of rows) {
        const bid = row.booking_id;

        // Atomically claim: only one cron tick will succeed per booking. This
        // takes the whole family visit, so its other members claim nothing
        // when their rows come up below.
        const [upd] = await db.execute(
          `UPDATE ip_bookings
           SET status = 'pending', updated_at = NOW()
           WHERE (booking_id = ? OR visit_group_id = ?)
             AND status = 'scheduled'
             AND deleted_at IS NULL`,
          [bid, row.visit_group_id ?? null]
        );
        if (upd.affectedRows === 0) continue; // another tick already claimed it

        if (row.booking_type === 'lab_visit') continue;

        const slotTime = row.slot_time
          ? String(row.slot_time).substring(0, 5) // "HH:MM:SS" → "HH:MM"
          : null;

        // booking_type in DB is 'home_collection'; dispatch engine expects 'lab'
        const dispatchType = (row.booking_type === 'home_collection') ? 'lab' : (row.booking_type ?? 'lab');

        console.log(
          `[Scheduler] Dispatching booking_id=${bid} ` +
          `slot_time=${slotTime ?? 'none'} type=${dispatchType}`
        );

        try {
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
        } catch (err) {
          // Hand it back, so the next tick tries again and the rest of this
          // tick's bookings still go out.
          console.error(`[Scheduler] dispatch failed booking_id=${bid}: ${err.message}`);
          await db.execute(
            `UPDATE ip_bookings SET status = 'scheduled', updated_at = NOW()
             WHERE (booking_id = ? OR visit_group_id = ?) AND status = 'pending' AND deleted_at IS NULL`,
            [bid, row.visit_group_id ?? null]
          );
        }
      }

      const [notStarted] = await db.execute(
        `SELECT b.booking_id
         FROM ip_bookings b
         WHERE b.status IN ('pending', 'confirmed')
           AND b.booking_type = 'home_collection'
           AND b.booking_date = CURDATE()
           AND b.deleted_at IS NULL
           AND b.created_at < NOW() - INTERVAL 2 MINUTE
           AND NOT EXISTS (SELECT 1 FROM ip_technician_collection tc WHERE tc.booking_id = b.booking_id)
           AND NOT EXISTS (SELECT 1 FROM ip_booking_requests br WHERE br.booking_id = b.booking_id)
           AND (b.visit_group_id IS NULL OR b.booking_id = (
                 SELECT MIN(b2.booking_id) FROM ip_bookings b2
                 WHERE b2.visit_group_id = b.visit_group_id
                   AND b2.status IN ('pending', 'confirmed') AND b2.deleted_at IS NULL))`
      );
      for (const { booking_id: bookingId } of notStarted) {
        if (startedHere.has(bookingId)) continue;
        startedHere.add(bookingId);
        await redispatchBooking(bookingId, { reason: 'app_did_not_start_dispatch' });
      }
    } catch (err) {
      console.error('[Scheduler] dispatchScheduler tick error:', err.message ?? err,
        '\n  code:', err.code, '| sqlState:', err.sqlState, '| sql:', err.sql?.substring(0, 120));
    }
  });

  console.log(`[Scheduler] Dispatch scheduler started — lead window: ${LEAD_MIN} min, checks every minute`);
};
