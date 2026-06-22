const db = require('../config/db');

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
// Lookup order:
//  1. Exact match on branches.pincode
//  2. Nearest branch by Haversine distance   (requires lat + lng params)
//  3. LIKE match on branches.location        (city name fallback)
//  4. LIKE match on branches.name
//  5. branch_service_areas                   (extended service area)
exports.lookupBranch = async (req, res) => {
  const { pincode, place } = req.query;
  const patientLat = req.query.lat  ? parseFloat(req.query.lat)  : null;
  const patientLng = req.query.lng  ? parseFloat(req.query.lng)  : null;

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
        `SELECT branch_id, name, address, location,
                pincode, telephone_no, mobile_no, email,
                latitude, longitude
         FROM branches
         WHERE pincode = ?
         LIMIT 1`,
        [pincode.trim()]
      );
      if (rows.length) console.log(`   ✅ matched by exact pincode`);
    }

    // ── 2. Nearest branch by Haversine distance ──────────────────────────────
    if (rows.length === 0 && patientLat != null && patientLng != null) {
      const [allBranches] = await db.execute(
        `SELECT branch_id, name, address, location,
                pincode, telephone_no, mobile_no, email,
                latitude, longitude
         FROM branches
         WHERE latitude IS NOT NULL AND longitude IS NOT NULL`
      );

      if (allBranches.length > 0) {
        // Calculate distance to every branch and sort ascending
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

    // ── 3. Location LIKE fallback (city name) ────────────────────────────────
    if (rows.length === 0 && place) {
      [rows] = await db.execute(
        `SELECT branch_id, name, address, location,
                pincode, telephone_no, mobile_no, email,
                latitude, longitude
         FROM branches
         WHERE LOWER(location) LIKE LOWER(?)
         LIMIT 1`,
        [`%${place.trim()}%`]
      );
      if (rows.length) console.log(`   ✅ matched by location LIKE`);
    }

    // ── 4. Name LIKE fallback ────────────────────────────────────────────────
    if (rows.length === 0 && place) {
      [rows] = await db.execute(
        `SELECT branch_id, name, address, location,
                pincode, telephone_no, mobile_no, email,
                latitude, longitude
         FROM branches
         WHERE LOWER(name) LIKE LOWER(?)
         LIMIT 1`,
        [`%${place.trim()}%`]
      );
      if (rows.length) console.log(`   ✅ matched by name LIKE`);
    }

    // ── 5. branch_service_areas fallback ────────────────────────────────────
    if (rows.length === 0) {
      const param  = pincode ? pincode.trim()           : null;
      const placeP = place   ? `%${place.trim()}%`      : null;

      if (param) {
        const [saRows] = await db.execute(
          `SELECT b.branch_id, b.name, b.address, b.location,
                  b.pincode, b.telephone_no, b.mobile_no, b.email,
                  b.latitude, b.longitude
           FROM branch_service_areas bsa
           JOIN branches b ON b.branch_id = bsa.branch_id
           WHERE bsa.pincode = ?
           LIMIT 1`,
          [param]
        );
        if (saRows.length) {
          rows = saRows;
          console.log(`   ✅ matched via branch_service_areas (pincode)`);
        }
      }

      if (rows.length === 0 && placeP) {
        const [saRows] = await db.execute(
          `SELECT b.branch_id, b.name, b.address, b.location,
                  b.pincode, b.telephone_no, b.mobile_no, b.email,
                  b.latitude, b.longitude
           FROM branch_service_areas bsa
           JOIN branches b ON b.branch_id = bsa.branch_id
           WHERE LOWER(bsa.place_name) LIKE LOWER(?)
           LIMIT 1`,
          [placeP]
        );
        if (saRows.length) {
          rows = saRows;
          console.log(`   ✅ matched via branch_service_areas (place)`);
        }
      }
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
// Returns available home-collection slots for a branch on a given date.
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
         ats.time_slot_id,
         ats.slot_id,
         s.slot_time   AS slot_label,
         s.start_time,
         s.end_time,
         ats.slot_time AS slot_time_value,
         ats.max_users,
         ats.booked_count,
         ats.is_available,
         (ats.max_users - ats.booked_count) AS remaining
       FROM available_time_slots ats
       JOIN slot s ON s.slot_id = ats.slot_id
       WHERE ats.branch_id    = ?
         AND ats.date         = ?
         AND ats.slot_type    = 'home_collection'
         AND ats.is_available = 1
         AND s.deleted_at IS NULL
       ORDER BY s.start_time ASC`,
      [branchId, date]
    );

    console.log(`✅ Found ${rows.length} available slot(s) for branch=${branchId} date=${date}`);

    return res.json({
      success:  true,
      date,
      branchId: Number(branchId),
      slots:    rows.map(r => ({
        timeSlotId:  r.time_slot_id,
        slotId:      r.slot_id,
        label:       r.slot_label,
        startTime:   r.start_time,
        endTime:     r.end_time,
        maxUsers:    r.max_users,
        bookedCount: r.booked_count,
        remaining:   r.remaining,
        isAvailable: r.is_available === 1,
      })),
    });
  } catch (err) {
    console.error('❌ getAvailableSlots FAILED:', err.message);
    return res.status(500).json({ success: false, message: 'Server error' });
  }
};
