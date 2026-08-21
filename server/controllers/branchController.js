const db   = require('../config/db');
const fs   = require('fs');
const path = require('path');
const { haversineKm, _technicianSummaries, _hasAvailableSlots } = require('../services/branchEligibility');

// ── File logging — same pattern as otp.log (authController.js) and
//    dispatch.log/collection.log (socket/bookingSocket.js): timestamped,
//    appended to disk, mirrored to stdout. Purely additive — every call site
//    below still logs to the console exactly as before.
const LOG_DIR  = path.join(__dirname, '..', 'logs');
const LOG_FILE = path.join(LOG_DIR, 'branch.log');
if (!fs.existsSync(LOG_DIR)) fs.mkdirSync(LOG_DIR);

function blog(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false })
                .replace(',', '') + ' IST';
  const line = `[${ist}] ${msg}\n`;
  process.stdout.write(line);
  fs.appendFileSync(LOG_FILE, line, 'utf8');
}

// "06:30:00" → "6:30 AM"
function _fmtTimeLabel(timeStr) {
  const [h, m] = timeStr.split(':').map(Number);
  const period = h < 12 ? 'AM' : 'PM';
  const h12 = h % 12 || 12;
  return `${h12}:${String(m).padStart(2, '0')} ${period}`;
}

// "06:30:00" → "06:30"
function _fmtTime(timeStr) {
  return timeStr.slice(0, 5);
}

function _fmtTechSummary(s) {
  if (!s || s.total === 0) return 'no technicians assigned';
  return `${s.total} tech(s) — ${s.online} online / ${s.offline} offline` +
         `  |  ${s.available} available / ${s.busy} busy`;
}

// Diagnostic-only: individual technician roster for one branch (id, name,
// online/offline, available/busy) — used to render the boxed table below for
// whichever branch actually wins the lookup. Read-only, no bearing on matching.
async function _technicianRoster(branchId) {
  const [rows] = await db.execute(
    `SELECT
       t.technician_id,
       u.user_name AS technician_name,
       ll.online_status,
       ll.task_status
     FROM ip_technicians t
     JOIN ip_users u ON u.user_id = t.user_id
     LEFT JOIN ip_technician_live_location ll ON ll.technician_id = t.technician_id
     WHERE t.branch_id = ?
     ORDER BY u.user_name ASC`,
    [branchId]
  );
  return rows;
}

// Renders the roster as a box-drawn table (one multi-line blog() call — a
// single timestamp for the whole table instead of one per row).
function _fmtTechTable(branchName, branchId, techs) {
  const headers = ['ID', 'Name', 'Online', 'Status'];
  const dataRows = techs.map(t => [
    String(t.technician_id),
    t.technician_name || '—',
    t.online_status === 'online' ? 'ONLINE' : 'OFFLINE',
    !t.task_status ? 'UNKNOWN' : (t.task_status === 'idle' ? 'AVAILABLE' : 'BUSY'),
  ]);

  const widths = headers.map((h, i) =>
    Math.max(h.length, ...dataRows.map(r => r[i].length), 0)
  );
  const pad     = (s, w) => s + ' '.repeat(w - s.length);
  const border  = (l, m, r) => l + widths.map(w => '─'.repeat(w + 2)).join(m) + r;
  const rowLine = cells => '│ ' + cells.map((c, i) => pad(c, widths[i])).join(' │ ') + ' │';

  const lines = [`   👥 Technicians @ ${branchName} (id=${branchId}) — ${dataRows.length} total`];
  lines.push('   ' + border('┌', '┬', '┐'));
  lines.push('   ' + rowLine(headers));
  lines.push('   ' + border('├', '┼', '┤'));
  if (dataRows.length === 0) {
    const innerWidth = widths.reduce((a, w) => a + w + 3, 0) - 1;
    lines.push('   │ ' + pad('no technicians assigned', innerWidth) + '│');
  } else {
    dataRows.forEach(r => lines.push('   ' + rowLine(r)));
  }
  lines.push('   ' + border('└', '┴', '┘'));

  const online    = dataRows.filter(r => r[2] === 'ONLINE').length;
  const offline   = dataRows.length - online;
  const available = dataRows.filter(r => r[3] === 'AVAILABLE').length;
  const busy      = dataRows.filter(r => r[3] === 'BUSY').length;
  const unknown   = dataRows.filter(r => r[3] === 'UNKNOWN').length;
  lines.push(
    `   Summary: ${dataRows.length} total  |  ${online} online / ${offline} offline` +
    `  |  ${available} available / ${busy} busy` +
    (unknown ? ` / ${unknown} no live-location data` : '')
  );
  return lines.join('\n');
}

// ── GET /api/branches/lookup?pincode=&place=&lat=&lng=&date= ─────────────────
exports.lookupBranch = async (req, res) => {
  const { pincode, place } = req.query;
  const patientLat = req.query.lat ? parseFloat(req.query.lat) : null;
  const patientLng = req.query.lng ? parseFloat(req.query.lng) : null;

  if (!pincode && !place && patientLat == null) {
    blog('⚠️  [BRANCH LOOKUP] REJECTED — no pincode, place, or lat/lng provided');
    return res.status(400).json({
      success: false,
      message: 'Provide at least one of: pincode, place, lat+lng',
    });
  }

  // Explicit signal from the client (sent by the GPS/Current-Live-Location
  // path in customer_dashboard_screen.dart) takes priority over guessing from
  // param combinations — the app reverse-geocodes GPS into a pincode and
  // sends both together, so "pincode present" alone can't tell GPS apart from
  // manual entry. Falls back to the old lat/lng-without-pincode heuristic for
  // any caller that doesn't send `source` yet (e.g. branch_selection_screen.dart).
  const isGpsSource = req.query.source === 'gps'
    || (patientLat != null && patientLng != null && !pincode);

  const inputMethod = isGpsSource
    ? 'Current Live Location'
    : (pincode || place)
      ? 'Manual Address/Pincode'
      : 'Unknown';

  blog(
    `\n🔍 [BRANCH LOOKUP] method=${inputMethod}` +
    `  pincode=${pincode ?? '—'}  place=${place ?? '—'}` +
    `  patientLat=${patientLat ?? '—'}  patientLng=${patientLng ?? '—'}`
  );

  let matchReason = null; // set on whichever step matches, used in the final summary log
  let isFallback   = false; // GPS path only: true when the winner isn't the true nearest branch
  let gpsExhausted  = false; // GPS path only: candidates existed but none passed the eligibility walk

  // Date the GPS eligibility walk checks slot availability against. Not sent
  // by any current caller (branch is picked before date/slot selection in the
  // UI), so this defaults to "today" IST — the dominant same-day booking case.
  // A caller can pass ?date=YYYY-MM-DD explicitly if that ever changes.
  const lookupDate = (req.query.date && String(req.query.date).trim())
    || new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });

  try {
    let rows = [];

    // ── 1. Exact pincode match ───────────────────────────────────────────────
    // Skipped for GPS-sourced requests even when a pincode is also present
    // (the app derives one from reverse-geocoding) — Current Live Location
    // must go through the eligibility-checked nearest-branch walk in step 2,
    // not shortcut past it via an incidental exact pincode match.
    if (pincode && !isGpsSource) {
      [rows] = await db.execute(
        `SELECT branch_id, branch_name AS name, branch_address AS address,
                branch_city AS location, branch_pincode AS pincode,
                branch_phone AS telephone_no, branch_mobile AS mobile_no,
                branch_email AS email, branch_latitude AS latitude,
                branch_longitude AS longitude
         FROM ip_branches
         WHERE branch_pincode = ? AND deleted_at IS NULL
         LIMIT 1`,
        [pincode.trim()]
      );
      if (rows.length) {
        matchReason = 'PINCODE_EXACT';
        blog(`   ✅ matched by exact pincode — id=${rows[0].branch_id} name=${rows[0].name}`);
      } else {
        blog(`   ✗ no branch has pincode="${pincode.trim()}"`);
      }
    } else if (pincode && isGpsSource) {
      blog(`   ↷ skipping pincode-exact shortcut (pincode="${pincode.trim()}") — GPS-sourced, routing to eligibility walk`);
    }

    // ── 2. Nearest branch by Haversine distance ──────────────────────────────
    if (rows.length === 0 && patientLat != null && patientLng != null) {
      const [allBranches] = await db.execute(
        `SELECT branch_id, branch_name AS name, branch_address AS address,
                branch_city AS location, branch_pincode AS pincode,
                branch_phone AS telephone_no, branch_mobile AS mobile_no,
                branch_email AS email, branch_latitude AS latitude,
                branch_longitude AS longitude
         FROM ip_branches
         WHERE branch_latitude IS NOT NULL AND branch_longitude IS NOT NULL
           AND deleted_at IS NULL`
      );

      if (allBranches.length > 0) {
        const withDist = allBranches.map(b => ({
          ...b,
          distKm: haversineKm(patientLat, patientLng, b.latitude, b.longitude),
        }));
        withDist.sort((a, b) => a.distKm - b.distKm);

        // Full visibility dump — EVERY nearby branch, unconditionally. Kept
        // separate from the eligibility walk below (which stops early once a
        // winner is found) so the "which branches were nearby" answer never
        // shrinks to just the one(s) actually checked.
        const allTechSummaries = await _technicianSummaries(withDist.map(c => c.branch_id));
        blog(`   📋 nearby branches considered (${withDist.length}, nearest first):`);
        withDist.forEach((cand, i) => {
          blog(
            `      ${i === 0 ? '➡' : ' '} ${i + 1}. id=${cand.branch_id}  ${cand.name}` +
            `  ${cand.distKm.toFixed(2)} km  |  ${_fmtTechSummary(allTechSummaries.get(cand.branch_id))}`
          );
        });

        // ── Eligibility walk (GPS path only) ────────────────────────────────
        // Business requirement: don't just take the nearest branch — walk
        // nearest-first until one has >=1 bookable slot for lookupDate. No
        // cap on how many are checked — every branch with real capacity
        // must be reachable, not just the nearest handful by rank. Reuses
        // the haversine sort above and the tech summaries already fetched
        // for the full dump — no new distance/eligibility algorithm, no
        // duplicate technician query.
        //
        // hasOnlineTech is still computed and logged below (for visibility
        // into who's currently reachable), but it is NOT part of the
        // qualification decision: a technician's real-time online_status
        // has no bearing on whether they'll be free for a date/time that
        // hasn't been chosen yet (no time is known at this stage — see
        // findEligibleBranches in branchEligibility.js for the time-aware
        // check used once dispatch does know the requested time). Capacity
        // (_hasAvailableSlots) is the sole gate now, so a branch is never
        // skipped just because its technician happens to be busy on an
        // unrelated, non-conflicting booking.
        blog(`   🔎 eligibility walk (slot capacity for ${lookupDate}) — checking all ${withDist.length}:`);

        let winner = null;
        for (let i = 0; i < withDist.length; i++) {
          const cand = withDist[i];
          const techSummary   = allTechSummaries.get(cand.branch_id);
          const hasOnlineTech = !!(techSummary && techSummary.online > 0);
          const hasSlots      = await _hasAvailableSlots(cand.branch_id, lookupDate);
          const qualifies     = hasSlots;

          blog(
            `      ${i + 1}. id=${cand.branch_id}  ${cand.name}  ${cand.distKm.toFixed(2)} km` +
            `  |  slots=${hasSlots ? 'yes' : 'no'}  |  online-tech=${hasOnlineTech ? 'yes' : 'no'}` +
            `  → ${qualifies ? 'QUALIFIES' : 'skip'}`
          );

          if (qualifies) { winner = cand; break; }
        }

        if (winner) {
          rows        = [winner];
          matchReason = 'GPS_NEAREST';
          isFallback  = winner.branch_id !== withDist[0].branch_id;
          blog(
            `   ✅ ${isFallback ? 'FALLBACK match' : 'matched by nearest distance'} — ${winner.name}` +
            ` (${winner.distKm.toFixed(2)} km away)` +
            (isFallback
              ? `  — nearest branch (id=${withDist[0].branch_id} ${withDist[0].name}) had no available slot for ${lookupDate}`
              : '')
          );
        } else {
          gpsExhausted = true;
          blog(
            `   ✗ [GPS FALLBACK EXHAUSTED] checked all ${withDist.length} nearby branch(es) for ${lookupDate}` +
            ` — none had an available slot` +
            (place ? `  (city/name-LIKE fallback SKIPPED for place="${place}" — would bypass the eligibility check)` : '')
          );
        }
      } else {
        blog('   ✗ no branches have latitude/longitude configured — GPS match skipped');
      }
    }

    // ── 3. City LIKE fallback ────────────────────────────────────────────────
    // Skipped once the GPS eligibility walk has explicitly exhausted its
    // candidates — a plain city-name text match must not silently override
    // that determination with a branch that was never eligibility-checked.
    if (rows.length === 0 && place && !gpsExhausted) {
      [rows] = await db.execute(
        `SELECT branch_id, branch_name AS name, branch_address AS address,
                branch_city AS location, branch_pincode AS pincode,
                branch_phone AS telephone_no, branch_mobile AS mobile_no,
                branch_email AS email, branch_latitude AS latitude,
                branch_longitude AS longitude
         FROM ip_branches
         WHERE LOWER(branch_city) LIKE LOWER(?) AND deleted_at IS NULL
         LIMIT 1`,
        [`%${place.trim()}%`]
      );
      if (rows.length) {
        matchReason = 'CITY_LIKE';
        blog(`   ✅ matched by city LIKE — id=${rows[0].branch_id} name=${rows[0].name}`);
      } else {
        blog(`   ✗ no branch city matches "${place.trim()}"`);
      }
    }

    // ── 4. Name LIKE fallback ────────────────────────────────────────────────
    if (rows.length === 0 && place && !gpsExhausted) {
      [rows] = await db.execute(
        `SELECT branch_id, branch_name AS name, branch_address AS address,
                branch_city AS location, branch_pincode AS pincode,
                branch_phone AS telephone_no, branch_mobile AS mobile_no,
                branch_email AS email, branch_latitude AS latitude,
                branch_longitude AS longitude
         FROM ip_branches
         WHERE LOWER(branch_name) LIKE LOWER(?) AND deleted_at IS NULL
         LIMIT 1`,
        [`%${place.trim()}%`]
      );
      if (rows.length) {
        matchReason = 'NAME_LIKE';
        blog(`   ✅ matched by name LIKE — id=${rows[0].branch_id} name=${rows[0].name}`);
      } else {
        blog(`   ✗ no branch name matches "${place.trim()}"`);
      }
    }

    if (rows.length === 0) {
      blog(
        `⚠️  [BRANCH LOOKUP] NO MATCH — method=${inputMethod} gpsExhausted=${gpsExhausted} ` +
        `pincode=${pincode ?? '—'} place=${place ?? '—'} lat=${patientLat ?? '—'} lng=${patientLng ?? '—'}`
      );
      // gpsExhausted: geographically valid branches existed, but none passed
      // the eligibility walk (online tech + slots) — distinct message from the
      // plain "nothing matched at all" case. Only the GPS path can set this;
      // manual pincode/place 404s are completely unaffected.
      return res.status(404).json({
        success: false,
        message: gpsExhausted
          ? 'No nearby branches have available appointments. Please choose another date or time.'
          : 'No branch found for this location. Try a nearby pincode or area name.',
      });
    }

    const b = rows[0];
    const winnerTechRoster = await _technicianRoster(b.branch_id);
    blog(_fmtTechTable(b.name, b.branch_id, winnerTechRoster));
    blog(
      `✅ [BRANCH LOOKUP] RESOLVED — method=${inputMethod} reason=${matchReason} isFallback=${isFallback} ` +
      `→ branch id=${b.branch_id} name=${b.name} pincode=${b.pincode ?? '—'}`
    );

    return res.json({
      success: true,
      branch: {
        branchId:    b.branch_id,
        name:        b.name,
        address:     b.address,
        location:    b.location,
        pincode:     b.pincode,
        telephoneNo: b.telephone_no,
        mobileNo:    b.mobile_no,
        email:       b.email,
        latitude:    b.latitude  ? parseFloat(b.latitude)  : null,
        longitude:   b.longitude ? parseFloat(b.longitude) : null,
        isFallback,
      },
      ...(isFallback && {
        message: 'The nearest branch has no availability right now — showing the next nearest branch with available slots.',
      }),
    });
  } catch (err) {
    blog(`❌ [BRANCH LOOKUP] ERROR — ${err.message}`);
    console.error('❌ lookupBranch FAILED:', err.message);
    return res.status(500).json({ success: false, message: 'Server error', detail: err.message });
  }
};

// ── GET /api/branches/slots?branchId=&date= ──────────────────────────────────
exports.getAvailableSlots = async (req, res) => {
  const { branchId, date } = req.query;

  if (!branchId || !date) {
    blog(`⚠️  [SLOTS] REJECTED — missing branchId=${branchId ?? '—'} or date=${date ?? '—'}`);
    return res.status(400).json({
      success: false,
      message: 'branchId and date are required',
    });
  }

  blog(`\n🕐 [SLOTS] branchId=${branchId} date=${date}`);

  try {
    const [rows] = await db.execute(
      `SELECT
         s.slot_id,
         s.slot_label,
         s.slot_start              AS start_time,
         s.slot_end                AS end_time,
         SUM(ts.max_bookings)      AS max_users,
         SUM(ts.booked_count)      AS booked_count,
         SUM(ts.max_bookings - ts.booked_count) AS remaining
       FROM ip_technician_slots ts
       JOIN ip_slots s ON s.slot_id = ts.slot_id
       WHERE ts.branch_id    = ?
         AND ts.slot_date    = ?
         AND ts.is_available = 1
         AND ts.booked_count < ts.max_bookings
         AND s.slot_active   = 1
       GROUP BY s.slot_id, s.slot_label, s.slot_start, s.slot_end
       ORDER BY s.slot_start ASC`,
      [branchId, date]
    );

    // For each slot, fetch distinct available appointment times from ip_available_slots
    const slotsWithIntervals = await Promise.all(rows.map(async r => {
      const [timeRows] = await db.execute(
        `SELECT DISTINCT ias.slot_time
         FROM ip_available_slots ias
         JOIN ip_technician_slots ts ON ts.tech_slot_id = ias.technician_slot_id
         WHERE ts.branch_id   = ?
           AND ts.slot_id     = ?
           AND ts.slot_date   = ?
           AND ias.is_available = 1
         ORDER BY ias.slot_time ASC`,
        [branchId, r.slot_id, date]
      );

      const timeIntervals = timeRows.map(t => ({
        time:  _fmtTime(t.slot_time),         // "06:30"
        label: _fmtTimeLabel(t.slot_time),    // "6:30 AM"
      }));

      return {
        slotId:        r.slot_id,
        label:         r.slot_label,
        startTime:     r.start_time,
        endTime:       r.end_time,
        maxUsers:      Number(r.max_users),
        bookedCount:   Number(r.booked_count),
        remaining:     Number(r.remaining),
        isAvailable:   true,
        timeIntervals,   // [] when no duration configured (old flow)
      };
    }));

    blog(`✅ Found ${rows.length} available slot(s) for branch=${branchId} date=${date}`);

    // ── Diagnostic-only technician roster for this branch/date ─────────────────
    // Read-only logging of who is assigned to this branch, their live status,
    // and their registered slots — mirrors (but does not affect) the real
    // dispatch eligibility logic in bookingSocket.js. Wrapped in try/catch so a
    // logging failure can never break the actual slots response above.
    try {
      const [techRows] = await db.execute(
        `SELECT
           t.technician_id,
           u.user_name        AS technician_name,
           ll.online_status,
           ll.task_status,
           ll.fcm_token,
           ts.tech_slot_id,
           ts.slot_id,
           s.slot_label,
           ts.is_available    AS slot_is_available,
           ts.booked_count,
           ts.max_bookings,
           ias.slot_time
         FROM ip_technicians t
         JOIN ip_users u ON u.user_id = t.user_id
         LEFT JOIN ip_technician_live_location ll ON ll.technician_id = t.technician_id
         LEFT JOIN ip_technician_slots ts
           ON ts.technician_id = t.technician_id
          AND ts.branch_id     = t.branch_id
          AND ts.slot_date     = ?
         LEFT JOIN ip_slots s ON s.slot_id = ts.slot_id
         LEFT JOIN ip_available_slots ias
           ON ias.technician_slot_id = ts.tech_slot_id
          AND ias.is_available = 1
         WHERE t.branch_id = ?
         ORDER BY u.user_name ASC, s.slot_start ASC, ias.slot_time ASC`,
        [date, branchId]
      );

      const techMap = new Map();
      for (const r of techRows) {
        if (!techMap.has(r.technician_id)) {
          techMap.set(r.technician_id, {
            id: r.technician_id,
            name: r.technician_name,
            onlineStatus: r.online_status ?? 'unknown',
            taskStatus: r.task_status ?? 'unknown',
            hasFcm: !!r.fcm_token,
            slots: new Map(),
          });
        }
        if (r.slot_id != null) {
          const tech = techMap.get(r.technician_id);
          if (!tech.slots.has(r.slot_id)) {
            tech.slots.set(r.slot_id, {
              label: r.slot_label,
              isAvailable: !!r.slot_is_available,
              booked: r.booked_count,
              max: r.max_bookings,
              times: new Set(),
            });
          }
          if (r.slot_time) tech.slots.get(r.slot_id).times.add(_fmtTime(r.slot_time));
        }
      }

      blog(`   👥 [SLOTS] Technician roster for branch=${branchId} (${techMap.size} assigned):`);
      const eligible = [];
      for (const tech of techMap.values()) {
        const online = tech.onlineStatus === 'online';
        const busy   = tech.taskStatus && tech.taskStatus !== 'idle';
        const slotList = [...tech.slots.values()];
        const slotSummary = slotList.length
          ? slotList.map(sl =>
              `${sl.label}${sl.times.size ? ' @ ' + [...sl.times].join(',') : ''}` +
              ` (${sl.booked}/${sl.max}${sl.isAvailable ? '' : ' inactive'})`
            ).join('; ')
          : 'none registered for this date';
        const hasCapacity      = slotList.some(sl => sl.isAvailable && sl.booked < sl.max);
        const dispatchEligible = hasCapacity && (online || tech.hasFcm);
        if (dispatchEligible) eligible.push(`${tech.name}(${tech.id})`);

        blog(
          `      • id=${tech.id} ${tech.name}` +
          `  online=${online ? 'ONLINE' : 'OFFLINE'}` +
          `  status=${busy ? 'BUSY' : 'AVAILABLE'}` +
          `  fcm=${tech.hasFcm ? 'yes' : 'no'}` +
          `  slots=[${slotSummary}]` +
          `  → ${dispatchEligible ? 'ELIGIBLE' : 'not eligible'}`
        );
      }
      blog(
        `   🎯 [SLOTS] Dispatch-eligible technicians for branch=${branchId} date=${date}: ` +
        (eligible.length ? eligible.join(', ') : 'NONE') +
        `\n   ℹ️  Branch selected because it had ${rows.length} slot(s) with remaining capacity` +
        ` on ${date} (see match reason in the preceding [BRANCH LOOKUP] log for this request).`
      );
    } catch (rosterErr) {
      blog(`   ⚠️  [SLOTS] technician roster logging failed (non-fatal) — ${rosterErr.message}`);
      console.error('   ⚠️  [SLOTS] technician roster logging failed (non-fatal):', rosterErr.message);
    }

    return res.json({
      success:  true,
      date,
      branchId: Number(branchId),
      slots:    slotsWithIntervals,
    });
  } catch (err) {
    blog(`❌ [SLOTS] ERROR — branchId=${branchId} date=${date} — ${err.message}`);
    console.error('❌ getAvailableSlots FAILED:', err.message);
    return res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── GET /api/branches?pincode=&city= ─────────────────────────────────────────
exports.getBranches = async (req, res) => {
  try {
    const { pincode, city } = req.query;

    let query = `SELECT branch_id AS id, branch_name AS name,
                        branch_address AS address, branch_city AS location,
                        branch_pincode AS pincode
                 FROM ip_branches
                 WHERE branch_active = 1 AND deleted_at IS NULL`;
    const params = [];

    if (pincode && pincode.trim()) {
      query += ' AND branch_pincode = ?';
      params.push(pincode.trim());
    } else if (city && city.trim()) {
      query += ' AND branch_city LIKE ?';
      params.push(`%${city.trim()}%`);
    }

    query += ' ORDER BY branch_name ASC';

    const [rows] = await db.query(query, params);
    res.json({ success: true, data: rows });
  } catch (err) {
    console.error('getBranches error:', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};
