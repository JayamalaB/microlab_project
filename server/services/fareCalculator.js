const pool = require('../config/db');
const fs = require('fs');
const path = require('path');
const { haversineKm } = require('./branchEligibility');

// Home Collection fare = Branch → Customer distance-based pricing.
//
// Deliberately separate from technician-dispatch distance (bookingSocket.js's
// own haversine, comparing live technician GPS ↔ customer) — that logic is
// completely untouched by this file and must stay that way. This module only
// ever computes Branch ↔ Customer, for pricing, never for who gets dispatched.
//
// Fare = base_fare + max(0, distanceKm - included_distance_km) * rate_per_km,
// using whichever ip_km_rates row is currently active (is_active = 1) as of
// today (effective_from <= today), most-recently-effective row wins. No
// caching here (unlike config/settings.js's ip_settings cache) — rate
// lookups aren't a hot path, and correctness (never pricing off a stale
// rate) matters more than shaving a query.

const FARE_LOG = path.join(__dirname, '..', 'logs', 'fare.log');
function logFare(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' });
  const line = `[${ist}] ${msg}\n`;
  try { fs.appendFileSync(FARE_LOG, line, 'utf8'); } catch (_) {}
}

// code: machine-readable reason, used by callers to pick an HTTP status.
class FareCalculationError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'FareCalculationError';
    this.code = code;
  }
}

// Most-recently-effective active rate as of today (Asia/Kolkata, matching
// every other date comparison in this codebase). No precedent in this repo
// for "pick the active row as of a date" beyond slotsController.js's
// exact-date working-hours lookup, which isn't the same range-based idiom —
// this is new logic, kept intentionally simple: is_active=1 AND
// effective_from <= today, newest effective_from wins. Multiple is_active
// rows are tolerated (not assumed impossible) — whichever is most recently
// effective is used, rather than picking an arbitrary one.
// dbConn: an optional live transaction connection (conn.execute, as used by
// bookingController.js's createBooking) — defaults to the shared pool for
// standalone callers (the fare-quote GET endpoint, which has no transaction
// of its own). Letting the caller pass its own connection keeps a caller
// that's already inside a transaction reading through that same connection,
// consistent with every other query createBooking makes.
async function getActiveKmRate(dbConn = pool) {
  const todayIST = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const [[rate]] = await dbConn.execute(
    `SELECT rate_id, rate_per_km, base_fare, included_distance_km,
            max_service_distance_km, effective_from, notes
     FROM ip_km_rates
     WHERE is_active = 1 AND effective_from <= ?
     ORDER BY effective_from DESC, rate_id DESC
     LIMIT 1`,
    [todayIST]
  );
  return rate ?? null;
}

// branchId → {latitude, longitude} or null if the branch doesn't exist / is
// soft-deleted / has no coordinates on file. Never falls back to technician
// coordinates or any other location — a branch with no coordinates is a
// data-hygiene gap to report, not something to silently substitute for.
async function getBranchCoordinates(branchId, dbConn = pool) {
  if (!branchId) return null;
  const [[branch]] = await dbConn.execute(
    `SELECT branch_latitude AS latitude, branch_longitude AS longitude
     FROM ip_branches
     WHERE branch_id = ? AND deleted_at IS NULL
       AND branch_latitude IS NOT NULL AND branch_longitude IS NOT NULL
     LIMIT 1`,
    [branchId]
  );
  return branch ?? null;
}

// Pure calculation given already-resolved inputs — no DB access, easy to
// unit test directly against the spec's own worked examples (Scenarios A/B/C).
function computeFare({ distanceKm, ratePerKm, baseFare, includedDistanceKm }) {
  const extraDistanceKm = Math.max(0, distanceKm - includedDistanceKm);
  // toFixed(2)-then-Number, matching this codebase's existing money
  // convention of computing to 2 decimals server-side (e.g. bookingController
  // .js's refund-amount math) — display-side truncation to whole rupees
  // (.toInt() everywhere in the Flutter app) stays a client concern.
  const extraCharge = Number((extraDistanceKm * ratePerKm).toFixed(2));
  const finalFare    = Number((baseFare + extraCharge).toFixed(2));
  return { distanceKm: Number(distanceKm.toFixed(2)), extraDistanceKm: Number(extraDistanceKm.toFixed(2)), extraCharge, finalFare };
}

// Full flow: branch coords + pickup coords → priced, logged result.
// Throws FareCalculationError (never returns a guessed/default fare) for:
//   MISSING_COORDINATES        — pickup lat/lng not provided or not finite
//   BRANCH_LOCATION_UNAVAILABLE — branch missing/soft-deleted/no coordinates
//   RATE_NOT_FOUND              — no active ip_km_rates row for today
//   RATE_CONFIG_INCOMPLETE      — active row exists but base_fare/
//                                 included_distance_km is NULL (not yet
//                                 configured for Home Collection pricing)
//   OUTSIDE_SERVICE_AREA        — active row's max_service_distance_km is
//                                 set and the computed distance exceeds it
async function calculateHomeCollectionFare({ branchId, pickupLat, pickupLng, dbConn = pool }) {
  const latNum = Number(pickupLat);
  const lngNum = Number(pickupLng);
  if (pickupLat == null || pickupLng == null || !Number.isFinite(latNum) || !Number.isFinite(lngNum)) {
    throw new FareCalculationError('MISSING_COORDINATES', 'Pickup location is required to calculate the Home Collection fare');
  }

  const branch = await getBranchCoordinates(branchId, dbConn);
  if (!branch) {
    throw new FareCalculationError('BRANCH_LOCATION_UNAVAILABLE', 'Assigned branch location is unavailable — cannot calculate fare');
  }

  const rate = await getActiveKmRate(dbConn);
  if (!rate) {
    throw new FareCalculationError('RATE_NOT_FOUND', 'No active fare configuration found for today');
  }
  if (rate.base_fare == null || rate.included_distance_km == null) {
    throw new FareCalculationError('RATE_CONFIG_INCOMPLETE', 'Fare configuration is incomplete (missing base fare or included distance)');
  }

  const distanceKm = haversineKm(branch.latitude, branch.longitude, latNum, lngNum);

  if (rate.max_service_distance_km != null && distanceKm > Number(rate.max_service_distance_km)) {
    logFare(`HOME_COLLECTION_FARE branchId=${branchId} pickupDistanceKm=${distanceKm.toFixed(2)} rateId=${rate.rate_id} result=OUTSIDE_SERVICE_AREA maxServiceDistanceKm=${rate.max_service_distance_km}`);
    throw new FareCalculationError('OUTSIDE_SERVICE_AREA', `Pickup location is outside the service area for the assigned branch (${distanceKm.toFixed(1)} km, max ${rate.max_service_distance_km} km)`);
  }

  const ratePerKm          = Number(rate.rate_per_km);
  const baseFare            = Number(rate.base_fare);
  const includedDistanceKm  = Number(rate.included_distance_km);

  const { distanceKm: distKm, extraDistanceKm, extraCharge, finalFare } =
    computeFare({ distanceKm, ratePerKm, baseFare, includedDistanceKm });

  logFare(
    `HOME_COLLECTION_FARE branchId=${branchId} pickupDistanceKm=${distKm} ratePerKm=${ratePerKm} ` +
    `includedDistanceKm=${includedDistanceKm} baseFare=${baseFare} extraDistanceKm=${extraDistanceKm} ` +
    `extraCharge=${extraCharge} finalFare=${finalFare} rateId=${rate.rate_id}`
  );

  return {
    distanceKm: distKm,
    ratePerKm,
    baseFare,
    includedDistanceKm,
    extraDistanceKm,
    extraCharge,
    finalFare,
    rateId: rate.rate_id,
  };
}

module.exports = { calculateHomeCollectionFare, getActiveKmRate, getBranchCoordinates, computeFare, FareCalculationError };
