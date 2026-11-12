'use strict';
const db = require('../config/db');
const { haversineKm } = require('./branchEligibility');

// Branch distances for home-collection dispatch.
//
// Every distance here is CUSTOMER LOCATION → BRANCH LOCATION: a straight line
// from the booking's collection point to the branch's saved latitude/longitude,
// one way — the same measure branch selection and the fare use. Technician
// GPS and branch-to-branch distance are never used.
//
//   original  the branch the booking started at, and its distance. Saved once
//             (ip_bookings.original_branch_id / original_distance_km) the first
//             time dispatch runs, so a later reassignment still measures from it.
//   served    the branch whose technician accepted, and its distance.
//   difference / extra   served − original, signed / never below 0.
//
// Nothing here touches the fare or payments. The columns come from
// migrations/add_dispatch_distance_columns.sql; before it is run, reads fall
// back to the booking's branch_id and writes are skipped — never an error.

const round2 = (n) => Math.round(n * 100) / 100;
const MISSING_COLUMN = 'ER_BAD_FIELD_ERROR';

// customer → branch, km (2 decimals), or null when the branch or the customer
// has no location.
async function customerToBranchKm(branchId, customerLat, customerLng) {
  if (branchId == null || customerLat == null || customerLng == null) return null;
  const lat = Number(customerLat);
  const lng = Number(customerLng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  const [[branch]] = await db.execute(
    `SELECT branch_latitude AS latitude, branch_longitude AS longitude
     FROM ip_branches WHERE branch_id = ? LIMIT 1`,
    [branchId]
  );
  if (branch?.latitude == null || branch?.longitude == null) return null;
  return round2(haversineKm(lat, lng, Number(branch.latitude), Number(branch.longitude)));
}

// served − original: { differenceKm (signed), extraKm (>= 0) }, both null when
// either distance is unknown.
function distanceDifference(servedKm, originalKm) {
  if (servedKm == null || originalKm == null) return { differenceKm: null, extraKm: null };
  const differenceKm = round2(Number(servedKm) - Number(originalKm));
  return { differenceKm, extraKm: Math.max(0, differenceKm) };
}

// "+4.10 km" / "-1.20 km" / "0.00 km" / "unknown"
function formatDifference(differenceKm) {
  if (differenceKm == null) return 'unknown';
  return `${differenceKm > 0 ? '+' : ''}${differenceKm.toFixed(2)} km`;
}

// Every booking in the visit (the booking, plus its family siblings).
const VISIT_WHERE = `b.deleted_at IS NULL
   AND (b.booking_id = p.booking_id
        OR (p.visit_group_id IS NOT NULL AND b.visit_group_id = p.visit_group_id))`;

// The original branch and distance for this booking, saved on first use.
// currentBranchId: the branch dispatch is starting from (the booking's
// branch_id) — the original when nothing was saved yet.
// Returns { originalBranchId, originalDistanceKm, saved } — saved=false when
// the columns don't exist yet. Never throws.
async function loadOriginalBaseline(bookingId, currentBranchId, customerLat, customerLng) {
  let stored = null;
  let columnsExist = true;
  try {
    const [[row]] = await db.execute(
      'SELECT original_branch_id, original_distance_km FROM ip_bookings WHERE booking_id = ? LIMIT 1',
      [bookingId]
    );
    stored = row ?? null;
  } catch (err) {
    if (err.code !== MISSING_COLUMN) throw err;
    columnsExist = false;
  }

  const originalBranchId = stored?.original_branch_id ?? currentBranchId ?? null;
  let originalDistanceKm = stored?.original_distance_km != null ? Number(stored.original_distance_km) : null;
  if (originalDistanceKm == null) {
    originalDistanceKm = await customerToBranchKm(originalBranchId, customerLat, customerLng);
  }

  // Saved only where still empty, so the first dispatch's values stay.
  if (columnsExist && originalBranchId != null) {
    await db.execute(
      `UPDATE ip_bookings b
       JOIN ip_bookings p ON p.booking_id = ?
       SET b.original_branch_id   = COALESCE(b.original_branch_id, ?),
           b.original_distance_km = COALESCE(b.original_distance_km, ?)
       WHERE ${VISIT_WHERE}`,
      [bookingId, originalBranchId, originalDistanceKm]
    );
  }
  return { originalBranchId, originalDistanceKm, saved: columnsExist };
}

// Saves the serving branch for the booking and its whole visit when a
// technician accepts (or an admin assigns). Any value not given is worked out
// from the booking: served branch → the booking's branch_id, served distance
// and original → from the saved original / locations.
// Returns the values saved, or { skipped: reason }. Never throws.
async function recordServingBranch(bookingId, { servedBranchId = null, servedDistanceKm = null,
  originalBranchId = null, originalDistanceKm = null } = {}) {
  try {
    const [[booking]] = await db.execute(
      `SELECT branch_id, collection_latitude, collection_longitude, original_branch_id, original_distance_km
       FROM ip_bookings WHERE booking_id = ? LIMIT 1`,
      [bookingId]
    );
    if (!booking) return { skipped: 'booking not found' };

    const lat = booking.collection_latitude;
    const lng = booking.collection_longitude;
    const servedId = servedBranchId ?? booking.branch_id ?? null;
    const servedKm = servedDistanceKm ?? await customerToBranchKm(servedId, lat, lng);
    // Never dispatched before (e.g. an admin assignment): the booking's own
    // branch is the original.
    const origId   = booking.original_branch_id ?? originalBranchId ?? booking.branch_id ?? servedId;
    const origKm   = booking.original_distance_km != null ? Number(booking.original_distance_km)
      : originalDistanceKm ?? await customerToBranchKm(origId, lat, lng);
    const { differenceKm, extraKm } = distanceDifference(servedKm, origKm);

    await db.execute(
      `UPDATE ip_bookings b
       JOIN ip_bookings p ON p.booking_id = ?
       SET b.original_branch_id     = COALESCE(b.original_branch_id, ?),
           b.original_distance_km   = COALESCE(b.original_distance_km, ?),
           b.served_branch_id       = ?,
           b.served_distance_km     = ?,
           b.distance_difference_km = ?,
           b.extra_distance_km      = ?
       WHERE ${VISIT_WHERE}`,
      [bookingId, origId, origKm, servedId, servedKm, differenceKm, extraKm]
    );
    return {
      originalBranchId: origId, originalDistanceKm: origKm,
      servedBranchId: servedId, servedDistanceKm: servedKm, differenceKm, extraKm,
    };
  } catch (err) {
    if (err.code === MISSING_COLUMN) return { skipped: 'distance columns missing — run add_dispatch_distance_columns.sql' };
    console.error(`❌ [dispatchDistance] serving branch not saved booking=${bookingId}: ${err.message}`);
    return { skipped: err.message };
  }
}

// ip_branches.branch_name, or null.
async function branchNameOf(branchId) {
  if (branchId == null) return null;
  const [[row]] = await db.execute('SELECT branch_name FROM ip_branches WHERE branch_id = ? LIMIT 1', [branchId]);
  return row?.branch_name ?? null;
}

// A technician's own branch (ip_technicians.branch_id) — the serving branch
// for an admin's manual assignment.
async function technicianBranchId(technicianId) {
  if (technicianId == null) return null;
  const [[row]] = await db.execute(
    'SELECT branch_id FROM ip_technicians WHERE technician_id = ? LIMIT 1',
    [technicianId]
  );
  return row?.branch_id ?? null;
}

module.exports = {
  customerToBranchKm, distanceDifference, formatDifference,
  loadOriginalBaseline, recordServingBranch, technicianBranchId, branchNameOf,
};
