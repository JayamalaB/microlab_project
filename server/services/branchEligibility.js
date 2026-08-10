const db = require('../config/db');

// Shared branch-eligibility primitives — used by both branchController.js
// (patient-facing branch lookup, single-winner) and bookingSocket.js
// (technician dispatch, needs the FULL ordered candidate list for
// cross-branch fallback). Moved here verbatim from branchController.js so
// both callers use the exact same logic — no duplicated business rules.

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

// Technician headcount per branch (total / online / offline / available /
// busy). Branch assignment (ip_technicians.branch_id) and live status
// (ip_technician_live_location) are not date-dependent.
async function _technicianSummaries(branchIds) {
  if (!branchIds || branchIds.length === 0) return new Map();
  const placeholders = branchIds.map(() => '?').join(',');
  const [rows] = await db.execute(
    `SELECT
       t.branch_id,
       COUNT(*)                                                       AS total,
       SUM(CASE WHEN ll.online_status = 'online' THEN 1 ELSE 0 END)   AS online,
       SUM(CASE WHEN ll.online_status IS NULL
                 OR ll.online_status != 'online' THEN 1 ELSE 0 END)   AS offline,
       SUM(CASE WHEN ll.task_status = 'idle' THEN 1 ELSE 0 END)       AS available,
       SUM(CASE WHEN ll.task_status IS NOT NULL
                 AND ll.task_status != 'idle' THEN 1 ELSE 0 END)      AS busy
     FROM ip_technicians t
     LEFT JOIN ip_technician_live_location ll ON ll.technician_id = t.technician_id
     WHERE t.branch_id IN (${placeholders})
     GROUP BY t.branch_id`,
    branchIds
  );
  const map = new Map();
  rows.forEach(r => map.set(r.branch_id, {
    total:     Number(r.total),
    online:    Number(r.online),
    offline:   Number(r.offline),
    available: Number(r.available),
    busy:      Number(r.busy),
  }));
  return map;
}

// Existence-only check reusing the exact WHERE conditions from
// getAvailableSlots' core query (branchController.js) — same
// capacity/registration logic, just LIMIT 1 instead of fetching full slot +
// time-interval data.
async function _hasAvailableSlots(branchId, date) {
  const [[row]] = await db.execute(
    `SELECT 1
     FROM ip_technician_slots ts
     JOIN ip_slots s ON s.slot_id = ts.slot_id
     WHERE ts.branch_id    = ?
       AND ts.slot_date    = ?
       AND ts.is_available = 1
       AND ts.booked_count < ts.max_bookings
       AND s.slot_active   = 1
     LIMIT 1`,
    [branchId, date]
  );
  return !!row;
}

// Full ordered list of every branch with >=1 online technician AND >=1
// available slot for `date`, nearest-first by distance from
// (patientLat, patientLng). No cap — unlike branchController.js's
// lookupBranch (which only ever needs the first winner and stops there),
// bookingSocket.js's cross-branch dispatch fallback needs every candidate so
// it can step to the next one when a branch's technicians are exhausted.
async function findEligibleBranches(patientLat, patientLng, date) {
  if (patientLat == null || patientLng == null) return [];

  const [allBranches] = await db.execute(
    `SELECT branch_id, branch_name AS name,
            branch_latitude AS latitude, branch_longitude AS longitude
     FROM ip_branches
     WHERE branch_latitude IS NOT NULL AND branch_longitude IS NOT NULL
       AND deleted_at IS NULL`
  );
  if (allBranches.length === 0) return [];

  const withDist = allBranches.map(b => ({
    ...b,
    distKm: haversineKm(patientLat, patientLng, b.latitude, b.longitude),
  }));
  withDist.sort((a, b) => a.distKm - b.distKm);

  const techSummaries = await _technicianSummaries(withDist.map(c => c.branch_id));

  const eligible = [];
  for (const cand of withDist) {
    const summary        = techSummaries.get(cand.branch_id);
    const hasOnlineTech  = !!(summary && summary.online > 0);
    const hasSlots       = hasOnlineTech ? await _hasAvailableSlots(cand.branch_id, date) : false;
    if (hasOnlineTech && hasSlots) {
      eligible.push({ branchId: cand.branch_id, name: cand.name, distKm: cand.distKm });
    }
  }
  return eligible;
}

module.exports = { haversineKm, _technicianSummaries, _hasAvailableSlots, findEligibleBranches };
