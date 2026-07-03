const db = require('../config/db');

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

  try {
    let rows = [];

    // 1. Exact pincode match
    if (pincode) {
      [rows] = await db.execute(
        `SELECT branch_id, branch_name, branch_address, branch_city,
                branch_pincode, branch_phone, branch_mobile, branch_email,
                branch_latitude, branch_longitude
         FROM ip_branches
         WHERE branch_pincode = ? AND branch_active = 1 AND deleted_at IS NULL LIMIT 1`,
        [pincode.trim()]
      );
    }

    // 2. Nearest branch by Haversine distance
    if (rows.length === 0 && patientLat != null && patientLng != null) {
      const [allBranches] = await db.execute(
        `SELECT branch_id, branch_name, branch_address, branch_city,
                branch_pincode, branch_phone, branch_mobile, branch_email,
                branch_latitude, branch_longitude
         FROM ip_branches
         WHERE branch_latitude IS NOT NULL AND branch_longitude IS NOT NULL
           AND branch_active = 1 AND deleted_at IS NULL`
      );
      if (allBranches.length > 0) {
        const withDist = allBranches.map(b => ({
          ...b,
          distKm: haversineKm(patientLat, patientLng, b.branch_latitude, b.branch_longitude),
        }));
        withDist.sort((a, b) => a.distKm - b.distKm);
        rows = [withDist[0]];
      }
    }

    // 3. City / location LIKE
    if (rows.length === 0 && place) {
      [rows] = await db.execute(
        `SELECT branch_id, branch_name, branch_address, branch_city,
                branch_pincode, branch_phone, branch_mobile, branch_email,
                branch_latitude, branch_longitude
         FROM ip_branches
         WHERE LOWER(branch_city) LIKE LOWER(?)
           AND branch_active = 1 AND deleted_at IS NULL LIMIT 1`,
        [`%${place.trim()}%`]
      );
    }

    // 4. Branch name LIKE
    if (rows.length === 0 && place) {
      [rows] = await db.execute(
        `SELECT branch_id, branch_name, branch_address, branch_city,
                branch_pincode, branch_phone, branch_mobile, branch_email,
                branch_latitude, branch_longitude
         FROM ip_branches
         WHERE LOWER(branch_name) LIKE LOWER(?)
           AND branch_active = 1 AND deleted_at IS NULL LIMIT 1`,
        [`%${place.trim()}%`]
      );
    }

    if (rows.length === 0) {
      return res.status(404).json({
        success: false,
        message: 'No branch found for this location. Try a nearby pincode or area name.',
      });
    }

    const b = rows[0];
    return res.json({
      success: true,
      branch: {
        branchId:    b.branch_id,
        name:        b.branch_name,
        address:     b.branch_address,
        location:    b.branch_city,
        pincode:     b.branch_pincode,
        telephoneNo: b.branch_phone,
        mobileNo:    b.branch_mobile,
        email:       b.branch_email,
        latitude:    b.branch_latitude  ? parseFloat(b.branch_latitude)  : null,
        longitude:   b.branch_longitude ? parseFloat(b.branch_longitude) : null,
      },
    });
  } catch (err) {
    console.error('lookupBranch error:', err.message);
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
