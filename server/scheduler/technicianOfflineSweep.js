'use strict';
// technicianOfflineSweep.js
//
// Backstop for technicians who disconnect without a clean signal (app
// killed, network lost, phone died). The 45s dispatch grace period in
// bookingSocket.js's socket 'disconnect' handler only manages the in-memory
// dispatch pool and deliberately never touches
// ip_technician_live_location.online_status — so without this sweep, that
// flag stays 'online' forever until the technician's next login. This job
// is independent of, and does not alter, the 45s grace period.
//
// Detection relies on the existing 20s 'technician_heartbeat' socket event
// (see bookingSocket.js), which already refreshes last_ping_at. A
// technician is swept once last_ping_at is older than the configured
// timeout — several missed heartbeats, not one.

const cron     = require('node-cron');
const db       = require('../config/db');
const settings = require('../config/settings');
const { markTechnicianOfflineStale } = require('../socket/bookingSocket');

module.exports = function initTechnicianOfflineSweep() {
  cron.schedule('*/30 * * * * *', async () => {
    try {
      const timeoutSec = parseInt(settings.get('technician_offline_timeout_sec', '90'), 10);
      const [rows] = await db.execute(
        `SELECT technician_id FROM ip_technician_live_location
         WHERE online_status = 'online'
           AND last_ping_at IS NOT NULL
           AND last_ping_at < (NOW() - INTERVAL ? SECOND)`,
        [timeoutSec]
      );
      for (const row of rows) {
        markTechnicianOfflineStale(row.technician_id);
      }
    } catch (err) {
      console.error('[technicianOfflineSweep] error:', err.message);
    }
  });

  console.log('[technicianOfflineSweep] started — interval=30s');
};
