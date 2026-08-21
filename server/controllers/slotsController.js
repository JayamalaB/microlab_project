const db   = require('../config/db');
const fs   = require('fs');
const path = require('path');

function formatTimeTo12h(timeStr) {
  const parts = String(timeStr).split(':');
  let h = parseInt(parts[0], 10);
  const m = (parts[1] || '00').padStart(2, '0');
  const period = h < 12 ? 'AM' : 'PM';
  h = h % 12 || 12;
  return `${h}:${m} ${period}`;
}

const LOG_FILE = path.join(__dirname, '..', 'logs', 'slots.log');
function writeLog(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false }).replace(',', '') + ' IST';
  const line = `[${ist}] ${msg}\n`;
  process.stdout.write(line);
  fs.appendFileSync(LOG_FILE, line, 'utf8');
}

// ── GET /api/slots?branch_id=&date=&slot_type= ───────────────────────────────
exports.getSlots = async (req, res) => {
  const { branch_id, date, slot_type } = req.query;
  writeLog(`[getSlots] received — branch_id=${branch_id} date=${date} slot_type=${slot_type}`);

  if (!date || !slot_type) {
    writeLog(`[getSlots] validation failed — missing date or slot_type`);
    return res.status(400).json({
      success: false,
      message: 'date and slot_type are required',
    });
  }

  // Compute today's date and current time in IST (UTC+5:30).
  // Passed as SQL params so no reliance on MySQL timezone config.
  const istOffsetMs = (5 * 60 + 30) * 60 * 1000;
  const istNow      = new Date(Date.now() + istOffsetMs);
  const todayIST    = istNow.toISOString().slice(0, 10); // 'YYYY-MM-DD'
  const cutoffTime  = `${String(istNow.getUTCHours()).padStart(2, '0')}:${String(istNow.getUTCMinutes()).padStart(2, '0')}:00`;
  writeLog(`[getSlots] today_IST=${todayIST} cutoff=${cutoffTime}`);

  try {
    let rows;

    if (slot_type === 'home_collection') {
      writeLog(`[getSlots] querying ip_available_slots for home_collection date=${date} branch_id=${branch_id}`);

      // Debug: what technician_slot_ids exist in ip_available_slots for this date?
      const [avDebug] = await db.execute(
        `SELECT available_slot_id, technician_slot_id FROM ip_available_slots
         WHERE slot_date = ? AND booking_type = 'home_collection' AND is_available = 1`,
        [date]
      );
      writeLog(`[getSlots] ip_available_slots rows for date=${date}: ${JSON.stringify(avDebug)}`);

      // Debug: what tech_slot_ids exist in ip_technician_slots for this branch?
      const [tsDebug] = await db.execute(
        `SELECT tech_slot_id, branch_id, booked_count, max_bookings FROM ip_technician_slots
         WHERE branch_id = ? AND slot_date = ?`,
        [branch_id, date]
      );
      writeLog(`[getSlots] ip_technician_slots rows for branch_id=${branch_id} date=${date}: ${JSON.stringify(tsDebug)}`);
      [rows] = await db.execute(
        `SELECT
           MIN(av.available_slot_id)               AS time_slot_id,
           MIN(ts.slot_id)                         AS slot_id,
           TIME_FORMAT(av.slot_time, '%H:%i')      AS time,
           TIME_FORMAT(av.slot_time, '%h:%i %p')   AS label,
           SUM(ts.max_bookings - ts.booked_count)  AS remaining
         FROM ip_available_slots av
         JOIN ip_technician_slots ts
           ON ts.tech_slot_id = av.technician_slot_id
         WHERE av.slot_date    = ?
           AND av.booking_type = 'home_collection'
           AND ts.branch_id    = ?
           AND av.is_available = 1
           AND ts.booked_count < ts.max_bookings
           AND (? != ? OR av.slot_time > ?)
         GROUP BY av.slot_time
         ORDER BY av.slot_time`,
        [date, branch_id, date, todayIST, cutoffTime]
      );
    } else {
      if (!branch_id) {
        writeLog(`[getSlots] validation failed — branch_id missing for lab_visit`);
        return res.status(400).json({
          success: false,
          message: 'branch_id is required for lab_visit',
        });
      }
      writeLog(`[getSlots] querying ip_available_slots for lab_visit date=${date} branch_id=${branch_id}`);
      [rows] = await db.execute(
        `SELECT
           MIN(av.available_slot_id)               AS time_slot_id,
           MIN(av.lab_slot_id)                     AS lab_slot_id,
           TIME_FORMAT(av.slot_time, '%H:%i')      AS time,
           TIME_FORMAT(av.slot_time, '%h:%i %p')   AS label,
           SUM(ls.max_bookings - ls.booked_count)  AS remaining
         FROM ip_available_slots av
         JOIN ip_lab_slots ls
           ON ls.lab_slot_id = av.lab_slot_id
         WHERE av.slot_date    = ?
           AND av.booking_type = 'lab_visit'
           AND ls.branch_id    = ?
           AND av.is_available = 1
           AND ls.booked_count < ls.max_bookings
           AND (? != ? OR av.slot_time > ?)
         GROUP BY av.slot_time
         ORDER BY av.slot_time`,
        [date, branch_id, date, todayIST, cutoffTime]
      );
    }

    writeLog(`[getSlots] found ${rows.length} slot(s) — ${JSON.stringify(rows.map(r => ({ id: r.time_slot_id, label: r.label, remaining: r.remaining })))}`);

    let fallback = null;

    if (rows.length === 0 && branch_id) {
      const isToday = date === todayIST;

      // Check working hours for the selected date
      const [wh] = await db.execute(
        `SELECT start_time, end_time FROM ip_branch_working_hours
         WHERE branch_id = ? AND slot_type = ? AND work_date = ? AND is_active = 1
         LIMIT 1`,
        [branch_id, slot_type, date]
      );

      if (wh.length > 0) {
        const startStr = String(wh[0].start_time);
        const endStr   = String(wh[0].end_time);

        if (isToday) {
          // Fallback start = now + 1 hour
          const [nh, nm] = cutoffTime.split(':').map(Number);
          const fbStartMins = nh * 60 + nm + 60;
          const [endH, endM] = endStr.split(':').map(Number);
          const endMins = endH * 60 + endM;

          const rawH = Math.floor(fbStartMins / 60);
          const rawM = fbStartMins % 60;
          // Round: >= 30 min → next hour, < 30 min → current hour
          const roundedH = rawM >= 30 ? rawH + 1 : rawH;
          const roundedMins = roundedH * 60;

          if (roundedMins < endMins) {
            const fbStartFmt = `${String(roundedH).padStart(2, '0')}:00`;
            fallback = { date, label: `${formatTimeTo12h(fbStartFmt)} – ${formatTimeTo12h(endStr)}` };
          }
        } else {
          // Future date — full working hours window
          fallback = { date, label: `${formatTimeTo12h(startStr)} – ${formatTimeTo12h(endStr)}` };
        }
      }

      if (!fallback) {
        // Find next active working day after selected date
        const [next] = await db.execute(
          `SELECT work_date, start_time, end_time FROM ip_branch_working_hours
           WHERE branch_id = ? AND slot_type = ? AND work_date > ? AND is_active = 1
           ORDER BY work_date ASC LIMIT 1`,
          [branch_id, slot_type, date]
        );

        if (next.length > 0) {
          const nr       = next[0];
          const startStr = String(nr.start_time);
          const endStr   = String(nr.end_time);
          const workDate = nr.work_date instanceof Date
            ? nr.work_date.toISOString().slice(0, 10)
            : String(nr.work_date).slice(0, 10);
          fallback = { date: workDate, label: `${formatTimeTo12h(startStr)} – ${formatTimeTo12h(endStr)}` };
        }
      }

      writeLog(`[getSlots] fallback=${JSON.stringify(fallback)}`);
    }

    res.json({ success: true, slots: rows, fallback });
  } catch (err) {
    writeLog(`[getSlots] ERROR — ${err.message} | code=${err.code} | sql=${err.sql}`);
    console.error('getSlots error:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};
