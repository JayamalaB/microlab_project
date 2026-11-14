const pool = require('../config/db');
const fs   = require('fs');
const path = require('path');
const { haversineKm } = require('./branchEligibility');

// Home Collection fare = round-trip km → ip_products range lookup.
// Round-trip km = Branch→Customer (haversine) × 2  (technician travels there AND back).
// The matching ip_products row (from_km ≤ round-trip ≤ to_km) supplies the
// price, test_code and name that become the service-charge product.
//
// Deliberately separate from technician-dispatch distance (bookingSocket.js's
// haversine, comparing live technician GPS ↔ customer) — that logic is
// completely untouched by this file and must stay that way.

const FARE_LOG = path.join(__dirname, '..', 'logs', 'fare.log');
function logFare(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' });
  const line = `[${ist}] ${msg}\n`;
  try { fs.appendFileSync(FARE_LOG, line, 'utf8'); } catch (_) {}
}

class FareCalculationError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'FareCalculationError';
    this.code = code;
  }
}

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

const INDIA_BOUNDS = { minLat: 6, maxLat: 37.5, minLng: 68, maxLng: 97.5 };
function _isInsideIndia(lat, lng) {
  return lat >= INDIA_BOUNDS.minLat && lat <= INDIA_BOUNDS.maxLat &&
         lng >= INDIA_BOUNDS.minLng && lng <= INDIA_BOUNDS.maxLng;
}

// Returns the ip_products row whose from_km ≤ doubledKm ≤ to_km, or null.
async function _getProductForDistance(doubledKm, dbConn = pool) {
  const [[product]] = await dbConn.execute(
    `SELECT product_id, product_name, test_code, product_price
     FROM ip_products
     WHERE from_km <= ? AND to_km >= ? AND product_active = 1
     LIMIT 1`,
    [doubledKm, doubledKm]
  );
  return product ?? null;
}

// Full flow: branch coords + pickup coords → km × 2 → product lookup → fare.
// Throws FareCalculationError for:
//   MISSING_COORDINATES         — pickup lat/lng not provided or not finite
//   INVALID_COORDINATES         — pickup outside India (e.g. 0,0 from failed GPS)
//   BRANCH_LOCATION_UNAVAILABLE — branch missing/soft-deleted/no coordinates
//   PRODUCT_NOT_FOUND           — no active ip_products row covers the doubled km
async function calculateHomeCollectionProduct({ branchId, pickupLat, pickupLng, dbConn = pool }) {
  const latNum = Number(pickupLat);
  const lngNum = Number(pickupLng);
  if (pickupLat == null || pickupLng == null || !Number.isFinite(latNum) || !Number.isFinite(lngNum)) {
    throw new FareCalculationError('MISSING_COORDINATES', 'Please set your collection location to see the Home Collection charge.');
  }
  if (!_isInsideIndia(latNum, lngNum)) {
    logFare(`HOME_COLLECTION_FARE branchId=${branchId} pickup=${latNum},${lngNum} result=INVALID_COORDINATES`);
    throw new FareCalculationError('INVALID_COORDINATES', 'Your collection location looks incorrect. Please set your location again or enter your pincode.');
  }

  const branch = await getBranchCoordinates(branchId, dbConn);
  if (!branch) {
    logFare(`HOME_COLLECTION_FARE branchId=${branchId} result=BRANCH_LOCATION_UNAVAILABLE (branch missing, deleted or has no coordinates)`);
    throw new FareCalculationError('BRANCH_LOCATION_UNAVAILABLE', 'We can\'t calculate the Home Collection charge for this branch right now. Please try again later.');
  }

  const distanceKm = haversineKm(branch.latitude, branch.longitude, latNum, lngNum);
  const doubledKm  = Number((distanceKm * 2).toFixed(2));

  const product = await _getProductForDistance(doubledKm, dbConn);
  if (!product) {
    logFare(`HOME_COLLECTION_FARE branchId=${branchId} pickup=${latNum},${lngNum} distanceKm=${distanceKm.toFixed(2)} doubledKm=${doubledKm} result=PRODUCT_NOT_FOUND`);
    throw new FareCalculationError('PRODUCT_NOT_FOUND', 'Home Collection pricing isn\'t available for your location right now. Please try again later.');
  }

  const finalFare = Math.round(Number(product.product_price));

  logFare(
    `HOME_COLLECTION_FARE branchId=${branchId} pickup=${latNum},${lngNum}` +
    ` distanceKm=${distanceKm.toFixed(2)} doubledKm=${doubledKm}` +
    ` productId=${product.product_id} productName="${product.product_name}"` +
    ` testCode=${product.test_code} finalFare=${finalFare}`
  );

  return {
    distanceKm: Number(distanceKm.toFixed(2)),
    doubledKm,
    product: {
      product_id:    product.product_id,
      product_name:  product.product_name,
      test_code:     product.test_code,
      product_price: Number(product.product_price),
    },
    finalFare,
  };
}

// Service charge for a one-way customer ↔ branch distance: up and down
// (km × 2), then the ip_products row whose km range covers it — the same
// lookup as calculateHomeCollectionProduct, for a distance already known.
// Returns { roundTripKm, product, price }, or { roundTripKm, product: null }
// when no product covers the km.
async function serviceChargeForKm(oneWayKm, dbConn = pool) {
  const roundTripKm = Number((Number(oneWayKm) * 2).toFixed(2));
  const product = await _getProductForDistance(roundTripKm, dbConn);
  logFare(`SERVICE_CHARGE oneWayKm=${oneWayKm} roundTripKm=${roundTripKm} ` +
    (product ? `productId=${product.product_id} productName="${product.product_name}" price=${product.product_price}` : 'result=PRODUCT_NOT_FOUND'));
  if (!product) return { roundTripKm, product: null, price: null };
  return {
    roundTripKm,
    product: {
      product_id:   product.product_id,
      product_name: product.product_name,
      test_code:    product.test_code,
    },
    price: Math.round(Number(product.product_price)),
  };
}

// If branchId belongs to a sub-branch, return its parent main branch id.
// Otherwise return branchId unchanged.
async function resolveMainBranchId(branchId, dbConn = pool) {
  if (!branchId) return branchId;
  const [[row]] = await dbConn.execute(
    `SELECT is_main_branch, base_branch_id FROM ip_branches WHERE branch_id = ? AND deleted_at IS NULL LIMIT 1`,
    [branchId]
  );
  if (!row || row.is_main_branch == 1 || !row.base_branch_id) return branchId;
  return row.base_branch_id;
}

module.exports = {
  calculateHomeCollectionProduct,
  serviceChargeForKm,
  getBranchCoordinates,
  resolveMainBranchId,
  FareCalculationError,
};
