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
  process.stdout.write(line);
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
  if (!branchId) {
    logFare(`GET_BRANCH_COORDS branchId=null → skipped`);
    return null;
  }
  const [[branch]] = await dbConn.execute(
    `SELECT branch_latitude AS latitude, branch_longitude AS longitude
     FROM ip_branches
     WHERE branch_id = ? AND deleted_at IS NULL
       AND branch_latitude IS NOT NULL AND branch_longitude IS NOT NULL
     LIMIT 1`,
    [branchId]
  );
  if (!branch) {
    logFare(`GET_BRANCH_COORDS branchId=${branchId} → NOT FOUND (missing, deleted, or no coordinates)`);
  } else {
    logFare(`GET_BRANCH_COORDS branchId=${branchId} → lat=${branch.latitude} lng=${branch.longitude}`);
  }
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
    `SELECT product_id, product_name, test_code, product_price, from_km, to_km
     FROM ip_products
     WHERE from_km <= ? AND to_km >= ? AND product_active = 1
     LIMIT 1`,
    [doubledKm, doubledKm]
  );
  if (!product) {
    logFare(`PRODUCT_LOOKUP doubledKm=${doubledKm} → NO MATCHING PRODUCT (check ip_products from_km/to_km ranges)`);
  } else {
    logFare(`PRODUCT_LOOKUP doubledKm=${doubledKm} → productId=${product.product_id} name="${product.product_name}" range=[${product.from_km}–${product.to_km}km] price=₹${product.product_price}`);
  }
  return product ?? null;
}

// Full flow: branch coords + pickup coords → km × 2 → product lookup → fare.
// Throws FareCalculationError for:
//   MISSING_COORDINATES         — pickup lat/lng not provided or not finite
//   INVALID_COORDINATES         — pickup outside India (e.g. 0,0 from failed GPS)
//   BRANCH_LOCATION_UNAVAILABLE — branch missing/soft-deleted/no coordinates
//   PRODUCT_NOT_FOUND           — no active ip_products row covers the doubled km
async function calculateHomeCollectionProduct({ branchId, pickupLat, pickupLng, dbConn = pool }) {
  logFare(`─── FARE CALC START branchId=${branchId} pickup=${pickupLat},${pickupLng}`);
  const latNum = Number(pickupLat);
  const lngNum = Number(pickupLng);
  if (pickupLat == null || pickupLng == null || !Number.isFinite(latNum) || !Number.isFinite(lngNum)) {
    logFare(`FARE CALC ERROR branchId=${branchId} → MISSING_COORDINATES (pickupLat=${pickupLat} pickupLng=${pickupLng})`);
    throw new FareCalculationError('MISSING_COORDINATES', 'Please set your collection location to see the Home Collection charge.');
  }
  if (!_isInsideIndia(latNum, lngNum)) {
    logFare(`FARE CALC ERROR branchId=${branchId} pickup=${latNum},${lngNum} → INVALID_COORDINATES (outside India bounds)`);
    throw new FareCalculationError('INVALID_COORDINATES', 'Your collection location looks incorrect. Please set your location again or enter your pincode.');
  }

  const branch = await getBranchCoordinates(branchId, dbConn);
  if (!branch) {
    logFare(`FARE CALC ERROR branchId=${branchId} → BRANCH_LOCATION_UNAVAILABLE`);
    throw new FareCalculationError('BRANCH_LOCATION_UNAVAILABLE', 'We can\'t calculate the Home Collection charge for this branch right now. Please try again later.');
  }

  const distanceKm = haversineKm(branch.latitude, branch.longitude, latNum, lngNum);
  const doubledKm  = Number((distanceKm * 2).toFixed(2));
  logFare(`HAVERSINE branchId=${branchId} branch=(${branch.latitude},${branch.longitude}) pickup=(${latNum},${lngNum}) oneWayKm=${distanceKm.toFixed(2)} roundTripKm=${doubledKm}`);

  const product = await _getProductForDistance(doubledKm, dbConn);
  if (!product) {
    logFare(`FARE CALC ERROR branchId=${branchId} roundTripKm=${doubledKm} → PRODUCT_NOT_FOUND`);
    throw new FareCalculationError('PRODUCT_NOT_FOUND', 'Home Collection pricing isn\'t available for your location right now. Please try again later.');
  }

  const finalFare = Math.round(Number(product.product_price));

  logFare(
    `─── FARE CALC OK branchId=${branchId} pickup=(${latNum},${lngNum})` +
    ` oneWayKm=${distanceKm.toFixed(2)} roundTripKm=${doubledKm}` +
    ` productId=${product.product_id} productName="${product.product_name}"` +
    ` testCode=${product.test_code} finalFare=₹${finalFare}`
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
  if (!branchId) {
    logFare(`RESOLVE_BRANCH branchId=null → skipped`);
    return branchId;
  }
  const [[row]] = await dbConn.execute(
    `SELECT branch_name, is_main_branch, base_branch_id FROM ip_branches WHERE branch_id = ? AND deleted_at IS NULL LIMIT 1`,
    [branchId]
  );
  if (!row) {
    logFare(`RESOLVE_BRANCH branchId=${branchId} → NOT FOUND in ip_branches`);
    return branchId;
  }
  if (row.is_main_branch == 1 || !row.base_branch_id) {
    logFare(`RESOLVE_BRANCH branchId=${branchId} name="${row.branch_name}" is_main_branch=${row.is_main_branch} → already main, no change`);
    return branchId;
  }
  logFare(`RESOLVE_BRANCH branchId=${branchId} name="${row.branch_name}" is_main_branch=${row.is_main_branch} base_branch_id=${row.base_branch_id} → resolved to mainBranchId=${row.base_branch_id}`);
  return row.base_branch_id;
}

module.exports = {
  calculateHomeCollectionProduct,
  serviceChargeForKm,
  getBranchCoordinates,
  resolveMainBranchId,
  FareCalculationError,
};
