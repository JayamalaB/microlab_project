const db = require('../config/db');

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

// Haversine distance in km between two lat/lng points
function haversineKm(lat1, lng1, lat2, lng2) {
  const R    = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLng = (lng2 - lng1) * Math.PI / 180;
  const a    = Math.sin(dLat / 2) ** 2
             + Math.cos(lat1 * Math.PI / 180)
             * Math.cos(lat2 * Math.PI / 180)
             * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.asin(Math.sqrt(a));
}

// ── GET /api/branches/lookup?pincode=&place=&lat=&lng= ───────────────────────
exports.lookupBranch = async (req, res) => {
  const { pincode, place } = req.query;
  const patientLat = req.query.lat ? parseFloat(req.query.lat) : null;
  const patientLng = req.query.lng ? parseFloat(req.query.lng) : null;

  if (!pincode && !place && patientLat == null) {
    return res.status(400).json({
      success: false,
      message: 'Provide at least one of: pincode, place, lat+lng',
    });
  }

  console.log(
    `\n🔍 [BRANCH LOOKUP] pincode=${pincode ?? '—'}  place=${place ?? '—'}` +
    `  patientLat=${patientLat ?? '—'}  patientLng=${patientLng ?? '—'}`
  );

  try {
    let rows = [];

    // ── 1. Exact pincode match ───────────────────────────────────────────────
    if (pincode) {
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
      if (rows.length) console.log(`   ✅ matched by exact pincode`);
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
        rows = [withDist[0]];
        console.log(
          `   ✅ matched by nearest distance — ${withDist[0].name}` +
          ` (${withDist[0].distKm.toFixed(2)} km away)`
        );
      }
    }

    // ── 3. City LIKE fallback ────────────────────────────────────────────────
    if (rows.length === 0 && place) {
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
      if (rows.length) console.log(`   ✅ matched by city LIKE`);
    }

    // ── 4. Name LIKE fallback ────────────────────────────────────────────────
    if (rows.length === 0 && place) {
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
      if (rows.length) console.log(`   ✅ matched by name LIKE`);
    }

    if (rows.length === 0) {
      console.log('⚠️  No branch found for given pincode/place/location');
      return res.status(404).json({
        success: false,
        message: 'No branch found for this location. Try a nearby pincode or area name.',
      });
    }

    const b = rows[0];
    console.log(`✅ Branch → id=${b.branch_id}  name=${b.name}`);

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
      },
    });
  } catch (err) {
    console.error('❌ lookupBranch FAILED:', err.message);
    return res.status(500).json({ success: false, message: 'Server error', detail: err.message });
  }
};

// ── GET /api/branches/slots?branchId=&date= ──────────────────────────────────
exports.getAvailableSlots = async (req, res) => {
  const { branchId, date } = req.query;

  if (!branchId || !date) {
    return res.status(400).json({
      success: false,
      message: 'branchId and date are required',
    });
  }

  console.log(`\n🕐 [SLOTS] branchId=${branchId} date=${date}`);

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

    // For each slot, fetch distinct available appointment times from ip_avilable_slots
    const slotsWithIntervals = await Promise.all(rows.map(async r => {
      const [timeRows] = await db.execute(
        `SELECT DISTINCT ias.slot_time
         FROM ip_avilable_slots ias
         JOIN ip_technician_slots ts ON ts.technician_slot_id = ias.technician_slot_id
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

    console.log(`✅ Found ${rows.length} available slot(s) for branch=${branchId} date=${date}`);

    return res.json({
      success:  true,
      date,
      branchId: Number(branchId),
      slots:    slotsWithIntervals,
    });
  } catch (err) {
    console.error('❌ getAvailableSlots FAILED:', err.message);
    return res.status(500).json({ success: false, message: 'Server error' });
  }
};
