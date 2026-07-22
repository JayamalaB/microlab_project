const cron = require('node-cron');
const db   = require('../config/db');
const { syncBookingToClient } = require('./clientSync');

/**
 * Retries bookings stuck in client_sync_status = 'pending'.
 * Runs every 5 minutes. Picks up at most 20 rows per run to avoid floods.
 */
function startSyncRetryJob() {
  cron.schedule('*/5 * * * *', async () => {
    let rows;
    try {
      [rows] = await db.execute(
        `SELECT b.booking_id, p.patient_mobile
         FROM ip_bookings b
         JOIN ip_patients p ON p.patient_id = b.patient_id
         WHERE b.client_sync_status = 'pending'
           AND b.deleted_at IS NULL
         ORDER BY b.booking_id ASC
         LIMIT 20`
      );
    } catch (err) {
      console.error('[syncRetry] DB query failed:', err.message);
      return;
    }

    if (!rows.length) return;

    console.log(`[syncRetry] retrying ${rows.length} pending booking(s)`);
    for (const row of rows) {
      syncBookingToClient(row.booking_id, {
        mobile: row.patient_mobile,
        type:   'customer',
      }).catch(err => console.error(`[syncRetry] booking_id=${row.booking_id} error:`, err.message));
    }
  });

  console.log('[syncRetry] retry job scheduled — every 5 minutes');
}

module.exports = { startSyncRetryJob };
