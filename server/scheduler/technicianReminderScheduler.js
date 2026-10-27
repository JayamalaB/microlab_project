'use strict';
// technicianReminderScheduler.js
//
// Runs every minute. Sends push alerts to the technician ASSIGNED to today's
// home-collection bookings while they have NOT started the journey
// (ip_technician_collection.collection_status = 'assigned'):
//
//   • Reminder   — 60 min before the appointment time ("Upcoming booking in
//                  60 min"). Skipped when the technician accepted the booking
//                  in the last 10 min: for later-day bookings the request is
//                  dispatched about 60 min before, so they have just seen it.
//   • Late alert — 5 min after the time, and again at 10 min, if the journey
//                  still hasn't started. Once they tap "Journey Started"
//                  (status 'en_route') no further alerts are sent.
//
// Each alert is claimed with an atomic UPDATE on its own *_sent_at column
// (migrations/add_technician_alert_columns.sql), so it is sent once even
// across restarts or two server instances. Family visits alert once (on the
// visit's first booking). All minutes are ip_settings values:
//   technician_reminder_enabled                (true)
//   technician_reminder_minutes_before         (60)
//   technician_reminder_skip_if_accepted_within (10)
//   technician_late_alert_minutes              ("5,10")

const fs       = require('fs');
const path     = require('path');
const cron     = require('node-cron');
const db       = require('../config/db');
const settings = require('../config/settings');
const { messaging } = require('../config/firebase');
const dbLogger = require('../utils/dbLogger');

const TECH_LOG = path.join(__dirname, '..', 'logs', 'technician.log');
function techLog(msg) {
  try {
    const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false }).replace(',', '') + ' IST';
    fs.appendFileSync(TECH_LOG, `[${ist}] ${msg}\n`, 'utf8');
  } catch (_) {}
  dbLogger.logTechnicianEvent(msg);
}

// Late alerts are not sent more than this long after the appointment time
// (e.g. right after a long server outage) — by then they would be noise.
const LATE_ALERT_MAX_MINUTES = 60;

function readConfig() {
  const late = String(settings.get('technician_late_alert_minutes', '5,10'))
    .split(',').map(s => parseInt(s.trim(), 10)).filter(n => Number.isFinite(n) && n > 0)
    .sort((a, b) => a - b).slice(0, 2);
  return {
    enabled:     settings.getBool('technician_reminder_enabled', true),
    before:      parseInt(settings.get('technician_reminder_minutes_before', '60'), 10) || 60,
    skipWithin:  parseInt(settings.get('technician_reminder_skip_if_accepted_within', '10'), 10) || 0,
    late:        late.length ? late : [5, 10],
  };
}

// Pure decision for one booking row — which alert (if any) is due now.
//   row.mins_to_appt        minutes until the appointment (negative = past)
//   row.mins_since_assigned minutes since the technician accepted
// Returns null, or { kind, column, alsoMark? }:
//   kind 'reminder' | 'reminder_skipped' | 'late1' | 'late2'
function decideAlert(row, cfg) {
  const m = Number(row.mins_to_appt);
  if (!Number.isFinite(m)) return null;

  if (m > 0) {
    if (m > cfg.before || row.reminder_sent_at) return null;
    const recent = row.mins_since_assigned != null && Number(row.mins_since_assigned) < cfg.skipWithin;
    return { kind: recent ? 'reminder_skipped' : 'reminder', column: 'reminder_sent_at' };
  }

  const late = -m;
  if (late > LATE_ALERT_MAX_MINUTES) return null;
  const [first, second] = cfg.late;
  if (second != null && late >= second && !row.late_alert_2_sent_at) {
    // Second alert also covers the first if the first was never sent.
    return { kind: 'late2', column: 'late_alert_2_sent_at', alsoMark: 'late_alert_1_sent_at', lateBy: second };
  }
  if (late >= first && (second == null || late < second) && !row.late_alert_1_sent_at) {
    return { kind: 'late1', column: 'late_alert_1_sent_at', lateBy: first };
  }
  return null;
}

// "14:30:00" → "2:30 PM"
function timeLabel(t) {
  const [h = 0, mi = 0] = String(t ?? '').split(':').map(Number);
  const h12 = ((h + 11) % 12) + 1;
  return `${h12}:${String(mi).padStart(2, '0')} ${h < 12 ? 'AM' : 'PM'}`;
}

function buildMessage(decision, row) {
  const at   = timeLabel(row.appt_time);
  const who  = row.patient_name || 'the customer';
  const area = row.city || '';
  if (decision.kind === 'reminder') {
    const mins = Math.max(1, Number(row.mins_to_appt));
    return {
      type:  'booking_reminder',
      title: `Upcoming booking in ${mins} min ⏰`,
      body:  `${at} · ${who}${area ? ` · ${area}` : ''}. Start your journey on time.`,
    };
  }
  return {
    type:  'booking_late_alert',
    title: `You're ${decision.lateBy} minutes late ⚠️`,
    body:  decision.kind === 'late2'
      ? `Booking at ${at} for ${who} — the customer is waiting. Start your journey or call the customer.`
      : `Booking at ${at} for ${who} — start your journey now.`,
  };
}

const DUE_ROWS_SQL = `
  SELECT tc.booking_id, tc.technician_id,
         tc.reminder_sent_at, tc.late_alert_1_sent_at, tc.late_alert_2_sent_at,
         TIMESTAMPDIFF(MINUTE, tc.assigned_at, NOW()) AS mins_since_assigned,
         b.booking_ref, b.city, p.patient_name,
         COALESCE(ias.slot_time, s.slot_start) AS appt_time,
         TIMESTAMPDIFF(MINUTE, NOW(),
           CONCAT(b.booking_date, ' ', COALESCE(ias.slot_time, s.slot_start))) AS mins_to_appt
  FROM ip_technician_collection tc
  JOIN ip_bookings b               ON b.booking_id = tc.booking_id
  LEFT JOIN ip_patients p          ON p.patient_id = b.patient_id
  LEFT JOIN ip_available_slots ias ON ias.available_slot_id = b.available_slot_id
  LEFT JOIN ip_technician_slots ts ON ts.tech_slot_id = ias.technician_slot_id
  LEFT JOIN ip_lab_slots ls        ON ls.lab_slot_id = COALESCE(ias.lab_slot_id, b.lab_slot_id)
  LEFT JOIN ip_slots s             ON s.slot_id = COALESCE(ts.slot_id, ls.slot_id)
  WHERE tc.collection_status = 'assigned'
    AND b.booking_type = 'home_collection'
    AND b.booking_date = CURDATE()
    AND b.deleted_at IS NULL
    AND b.status NOT IN ('cancelled', 'completed')
    AND COALESCE(ias.slot_time, s.slot_start) IS NOT NULL
    AND (b.visit_group_id IS NULL OR b.booking_id = (
          SELECT MIN(b2.booking_id) FROM ip_bookings b2
          WHERE b2.visit_group_id = b.visit_group_id AND b2.deleted_at IS NULL))`;

async function sendPush(technicianId, bookingId, msg) {
  const [[tech]] = await db.execute(
    `SELECT u.user_notification_token, tll.fcm_token AS live_fcm_token
     FROM ip_technicians t
     JOIN ip_users u ON u.user_id = t.user_id
     LEFT JOIN ip_technician_live_location tll ON tll.technician_id = t.technician_id
     WHERE t.technician_id = ? LIMIT 1`,
    [technicianId]
  );
  const token = tech?.user_notification_token || tech?.live_fcm_token;
  if (!token || !messaging) return { sent: false, reason: !token ? 'no FCM token' : 'messaging not initialised' };
  await messaging.send({
    token,
    notification: { title: msg.title, body: msg.body },
    data: { type: msg.type, booking_id: String(bookingId) },
    android: { priority: 'high', notification: { channelId: 'booking_updates' } },
  });
  return { sent: true };
}

let lastSchemaWarning = 0;

async function tick() {
  const cfg = readConfig();
  if (!cfg.enabled) return;

  let rows;
  try {
    [rows] = await db.execute(DUE_ROWS_SQL);
  } catch (err) {
    if (err.code === 'ER_BAD_FIELD_ERROR' && Date.now() - lastSchemaWarning > 3600_000) {
      lastSchemaWarning = Date.now();
      console.error('[TechReminder] alert columns missing — run migrations/add_technician_alert_columns.sql');
    } else if (err.code !== 'ER_BAD_FIELD_ERROR') {
      console.error('[TechReminder] query failed:', err.message);
    }
    return;
  }

  for (const row of rows) {
    const decision = decideAlert(row, cfg);
    if (!decision) continue;

    // Atomic claim — only one tick/instance sends each alert, and only while
    // the journey still hasn't started.
    const extra = decision.alsoMark ? `, ${decision.alsoMark} = COALESCE(${decision.alsoMark}, NOW())` : '';
    const [claim] = await db.execute(
      `UPDATE ip_technician_collection
          SET ${decision.column} = NOW()${extra}
        WHERE booking_id = ? AND ${decision.column} IS NULL AND collection_status = 'assigned'`,
      [row.booking_id]
    );
    if (claim.affectedRows !== 1) continue;

    if (decision.kind === 'reminder_skipped') {
      techLog(`[TECH_REMINDER] skipped — technician_id=${row.technician_id} booking_id=${row.booking_id} accepted ${row.mins_since_assigned} min ago`);
      continue;
    }

    const msg = buildMessage(decision, row);
    try {
      const r = await sendPush(row.technician_id, row.booking_id, msg);
      techLog(`[TECH_${decision.kind === 'reminder' ? 'REMINDER' : 'LATE_ALERT'}] ${r.sent ? 'sent' : `not sent (${r.reason})`} — technician_id=${row.technician_id} booking_id=${row.booking_id} appt=${row.appt_time} mins_to_appt=${row.mins_to_appt}`);
    } catch (err) {
      techLog(`[TECH_ALERT_ERROR] technician_id=${row.technician_id} booking_id=${row.booking_id} kind=${decision.kind} error=${err.message}`);
    }
  }
}

module.exports = function initTechnicianReminderScheduler() {
  cron.schedule('* * * * *', () => {
    tick().catch(err => console.error('[TechReminder] tick error:', err.message));
  });
  console.log('[Scheduler] Technician reminder/late-alert scheduler started — checks every minute');
};
module.exports.decideAlert = decideAlert;
module.exports.buildMessage = buildMessage;
module.exports.timeLabel = timeLabel;
module.exports._tick = tick;
