const db   = require('../config/db');
const fs   = require('fs');
const path = require('path');

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
    res.json({ success: true, slots: rows });
  } catch (err) {
    writeLog(`[getSlots] ERROR — ${err.message} | code=${err.code} | sql=${err.sql}`);
    console.error('getSlots error:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};
