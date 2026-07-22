const db            = require('../config/db');
const { messaging } = require('../config/firebase');
const fs            = require('fs');
const path          = require('path');

const CHANNEL_ID = 'booking_updates';
const LOG_FILE   = path.join(__dirname, '..', 'logs', 'customer_push.log');

function writeLog(msg) {
  const ist  = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false }).replace(',', '') + ' IST';
  const line = `[${ist}] ${msg}\n`;
  process.stdout.write(line);
  fs.appendFileSync(LOG_FILE, line, 'utf8');
}

/**
 * Sends a push notification to the app user who owns the booking.
 * Looks up the FCM token via ip_bookings.client_id → ip_users.
 * Silent no-op if Firebase is not initialised or no token is found.
 *
 * @param {number} bookingId
 * @param {string} title
 * @param {string} body
 * @param {Object} extraData   — extra key/value pairs for message.data (strings only)
 */
async function sendToBookingOwner(bookingId, title, body, extraData = {}) {
  writeLog(`[customerPush] called — booking_id=${bookingId} title="${title}"`);

  if (!messaging) {
    writeLog(`[customerPush] skipped — Firebase not initialised`);
    return;
  }

  try {
    const [[row]] = await db.execute(
      `SELECT u.user_notification_token, u.user_mobile_no, u.client_id
       FROM ip_bookings b
       JOIN ip_users u ON u.client_id = b.client_id
       WHERE b.booking_id = ? AND u.user_microlab_type = 'patient_user'
       LIMIT 1`,
      [bookingId]
    );

    writeLog(`[customerPush] db row — mobile=${row?.user_mobile_no ?? 'NULL'} client_id=${row?.client_id ?? 'NULL'} has_token=${!!row?.user_notification_token}`);

    const token = row?.user_notification_token;
    if (!token) {
      writeLog(`[customerPush] skipped — no FCM token for booking_id=${bookingId} mobile=${row?.user_mobile_no ?? 'unknown'}`);
      return;
    }

    writeLog(`[customerPush] sending FCM — token=...${token.slice(-10)}`);

    await messaging.send({
      token,
      notification: { title, body },
      data: { booking_id: String(bookingId), ...extraData },
      android: {
        priority: 'high',
        notification: { channelId: CHANNEL_ID },
      },
    });

    writeLog(`[customerPush] ✅ sent — booking_id=${bookingId} mobile=${row.user_mobile_no}`);
  } catch (err) {
    writeLog(`[customerPush] ❌ failed — booking_id=${bookingId}: ${err.message}`);
  }
}

module.exports = { sendToBookingOwner };
