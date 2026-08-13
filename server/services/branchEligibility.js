const db = require('../config/db');

// Shared branch-eligibility primitives — used by both branchController.js
// (patient-facing branch lookup, single-winner) and bookingSocket.js
// (technician dispatch, needs the FULL ordered candidate list for
// cross-branch fallback). Moved here verbatim from branchController.js so
// both callers use the exact same logic — no duplicated business rules.

// ── Appointment-based slot tracking ─────────────────────────────────────────
// technicianId → Map<bookingId, { slotDate, startMinutes, endMinutes, slotId }>
// Each inner entry represents one committed appointment window, populated on
// booking_accepted (bookingSocket.js) and rebuilt from DB on server start by
// initDispatchState() (also bookingSocket.js). Moved here (verbatim, from
// bookingSocket.js) so branch-eligibility checks (findEligibleBranches below)
// can consult the exact same committed-window data dispatch itself uses,
// instead of a second, divergent copy. There is exactly one instance of this
// Map — Node's require() cache guarantees every file that requires this
// module gets the same object by reference, never a fresh copy.
const technicianActiveSlots = new Map();

// ── Appointment slot overlap check ──────────────────────────────────────────
// Returns true if the given technician already has a committed appointment
// window on bookingDate that covers requestedStart (minutes since midnight).
// Techs with no entry in technicianActiveSlots (old model) always return
// false — their availability is governed by the global isAvailable flag
// instead. Moved here verbatim from bookingSocket.js — same reasoning as
// technicianActiveSlots above.
function _hasSlotConflict(techId, bookingDate, requestedStart) {
  const activeSlots = technicianActiveSlots.get(techId);
  if (!activeSlots || activeSlots.size === 0) return false;
  for (const [, win] of activeSlots) {
    if (win.slotDate !== bookingDate) continue;
    // Conflict: new appointment starts inside an existing committed window
    if (requestedStart >= win.startMinutes && requestedStart < win.endMinutes) return true;
  }
  return false;
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

// Time-aware eligibility check — does this branch have at least one
// technician who is genuinely free for this exact requested appointment
// time? Composes two existing, unchanged primitives rather than
// reimplementing either:
//   1. ip_available_slots + ip_technician_slots — same join shape already
//      used by getAvailableSlots' interval query (branchController.js),
//      just scoped down to one branch + one exact slot_time instead of
//      listing every interval — finds which technicians even have this
//      exact time still marked bookable.
//   2. _hasSlotConflict() — the exact same committed-window overlap check
//      dispatch's own Checkpoint A/B already use, so a branch can never be
//      judged eligible here in a way dispatch would then disagree with.
async function _hasAvailableTechnicianForTime(branchId, date, requestedStart) {
  const hh = String(Math.floor(requestedStart / 60)).padStart(2, '0');
  const mm = String(requestedStart % 60).padStart(2, '0');
  const slotTime = `${hh}:${mm}:00`;

  const [rows] = await db.execute(
    `SELECT DISTINCT ts.technician_id
     FROM ip_available_slots ias
     JOIN ip_technician_slots ts ON ts.tech_slot_id = ias.technician_slot_id
     WHERE ts.branch_id    = ?
       AND ts.slot_date    = ?
       AND ts.is_available = 1
       AND ias.slot_time   = ?
       AND ias.is_available = 1`,
    [branchId, date, slotTime]
  );
  if (rows.length === 0) return false;

  return rows.some(r => !_hasSlotConflict(r.technician_id, date, requestedStart));
}

// Full ordered list of every branch eligible for `date` (and, when
// requestedStart is given, for that exact appointment time), nearest-first
// by distance from (patientLat, patientLng). No cap — unlike
// branchController.js's lookupBranch (which only ever needs the first
// winner and stops there), bookingSocket.js's cross-branch dispatch
// fallback needs every candidate so it can step to the next one when a
// branch's technicians are exhausted.
//
// requestedStart (minutes since midnight, optional): when the caller
// already knows the exact appointment time being dispatched (the
// cross-branch fallback case — dispatch always knows this by then),
// eligibility is checked per-technician via _hasAvailableTechnicianForTime
// (exact time + no conflict). When omitted (no specific time context, e.g.
// transport bookings), falls back to the existing coarse
// _hasAvailableSlots() capacity check — unchanged from before.
async function findEligibleBranches(patientLat, patientLng, date, requestedStart = null) {
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

  const eligible = [];
  for (const cand of withDist) {
    const qualifies = requestedStart != null
      ? await _hasAvailableTechnicianForTime(cand.branch_id, date, requestedStart)
      : await _hasAvailableSlots(cand.branch_id, date);
    if (qualifies) {
      eligible.push({ branchId: cand.branch_id, name: cand.name, distKm: cand.distKm });
    }
  }
  return eligible;
}

module.exports = {
  haversineKm,
  _technicianSummaries,
  _hasAvailableSlots,
  _hasAvailableTechnicianForTime,
  findEligibleBranches,
  technicianActiveSlots,
  _hasSlotConflict,
};
