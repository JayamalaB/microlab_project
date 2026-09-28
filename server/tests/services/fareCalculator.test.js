// Tests server/services/fareCalculator.js — Home Collection fare
// (Branch → Customer distance-based pricing).
//
// computeFare() is pure (no DB), so it's tested directly against the exact
// worked examples from the fare-calculation spec (Scenarios A/B/C).
// calculateHomeCollectionFare() is tested via a plain fake `dbConn` object
// (not jest.mock('../../config/db')) — the function accepts dbConn as a
// parameter specifically so callers (and tests) don't have to go through the
// shared pool; see fareCalculator.js's own comment on why.
const {
  calculateHomeCollectionFare,
  computeFare,
  FareCalculationError,
} = require('../../services/fareCalculator');

function fakeDbConn({ branchRows = [], rateRows = [] } = {}) {
  return {
    execute: jest.fn()
      .mockResolvedValueOnce([branchRows]) // getBranchCoordinates
      .mockResolvedValueOnce([rateRows]),  // getActiveKmRate
  };
}

const branchCoords = [{ latitude: '13.0827', longitude: '80.2707' }];
const baseRate = { rate_id: 3, rate_per_km: '15.00', base_fare: '49.00', included_distance_km: '3.00', max_service_distance_km: null };

describe('fareCalculator.computeFare — pure formula, matches the spec worked examples', () => {
  // Scenario A — distance within the included radius: no extra charge at all.
  test('Scenario A: 2km, included 3km → fare is base fare only', () => {
    const r = computeFare({ distanceKm: 2, ratePerKm: 15, baseFare: 49, includedDistanceKm: 3 });
    expect(r.extraDistanceKm).toBe(0);
    expect(r.extraCharge).toBe(0);
    expect(r.finalFare).toBe(49);
  });

  // Scenario B — the spec's own headline example.
  test('Scenario B: 8km, included 3km, ₹15/km → ₹124', () => {
    const r = computeFare({ distanceKm: 8, ratePerKm: 15, baseFare: 49, includedDistanceKm: 3 });
    expect(r.extraDistanceKm).toBe(5);
    expect(r.extraCharge).toBe(75);
    expect(r.finalFare).toBe(124);
  });

  // Scenario C — fractional distance.
  test('Scenario C: 10.5km, included 3km, ₹15/km → ₹161.50', () => {
    const r = computeFare({ distanceKm: 10.5, ratePerKm: 15, baseFare: 49, includedDistanceKm: 3 });
    expect(r.extraDistanceKm).toBe(7.5);
    expect(r.extraCharge).toBe(112.5);
    expect(r.finalFare).toBe(161.5);
  });

  test('distance exactly at the included boundary charges nothing extra', () => {
    const r = computeFare({ distanceKm: 3, ratePerKm: 15, baseFare: 49, includedDistanceKm: 3 });
    expect(r.extraDistanceKm).toBe(0);
    expect(r.finalFare).toBe(49);
  });
});

describe('fareCalculator.calculateHomeCollectionFare', () => {
  test('happy path: computes and returns a full priced result', async () => {
    const dbConn = fakeDbConn({ branchRows: branchCoords, rateRows: [baseRate] });
    const result = await calculateHomeCollectionFare({
      branchId: 3, pickupLat: 13.0827, pickupLng: 80.35, dbConn,
    });
    expect(result.rateId).toBe(3);
    expect(result.baseFare).toBe(49);
    expect(result.includedDistanceKm).toBe(3);
    expect(result.finalFare).toBeGreaterThan(49); // some distance beyond the branch itself
    expect(dbConn.execute).toHaveBeenCalledTimes(2);
  });

  test('missing pickup coordinates → MISSING_COORDINATES, no DB call at all', async () => {
    const dbConn = fakeDbConn();
    await expect(
      calculateHomeCollectionFare({ branchId: 3, pickupLat: null, pickupLng: null, dbConn })
    ).rejects.toMatchObject({ code: 'MISSING_COORDINATES' });
    expect(dbConn.execute).not.toHaveBeenCalled();
  });

  test('non-finite pickup coordinates are rejected the same way as missing ones', async () => {
    const dbConn = fakeDbConn();
    await expect(
      calculateHomeCollectionFare({ branchId: 3, pickupLat: 'not-a-number', pickupLng: 80.27, dbConn })
    ).rejects.toBeInstanceOf(FareCalculationError);
  });

  test('branch with no coordinates on file → BRANCH_LOCATION_UNAVAILABLE, never falls back to any other location', async () => {
    const dbConn = fakeDbConn({ branchRows: [] }); // getBranchCoordinates finds nothing
    await expect(
      calculateHomeCollectionFare({ branchId: 3, pickupLat: 13.08, pickupLng: 80.27, dbConn })
    ).rejects.toMatchObject({ code: 'BRANCH_LOCATION_UNAVAILABLE' });
  });

  test('no active rate for today → RATE_NOT_FOUND, never a guessed default', async () => {
    const dbConn = fakeDbConn({ branchRows: branchCoords, rateRows: [] });
    await expect(
      calculateHomeCollectionFare({ branchId: 3, pickupLat: 13.08, pickupLng: 80.27, dbConn })
    ).rejects.toMatchObject({ code: 'RATE_NOT_FOUND' });
  });

  test('active rate missing base_fare/included_distance_km → RATE_CONFIG_INCOMPLETE', async () => {
    const incompleteRate = { ...baseRate, base_fare: null };
    const dbConn = fakeDbConn({ branchRows: branchCoords, rateRows: [incompleteRate] });
    await expect(
      calculateHomeCollectionFare({ branchId: 3, pickupLat: 13.08, pickupLng: 80.27, dbConn })
    ).rejects.toMatchObject({ code: 'RATE_CONFIG_INCOMPLETE' });
  });

  test('distance beyond max_service_distance_km → OUTSIDE_SERVICE_AREA, booking not priced', async () => {
    const cappedRate = { ...baseRate, max_service_distance_km: '5.00' };
    const dbConn = fakeDbConn({ branchRows: branchCoords, rateRows: [cappedRate] });
    // ~0.9 lng degrees at this latitude is roughly 90km+ away — comfortably beyond a 5km cap.
    await expect(
      calculateHomeCollectionFare({ branchId: 3, pickupLat: 13.0827, pickupLng: 81.2, dbConn })
    ).rejects.toMatchObject({ code: 'OUTSIDE_SERVICE_AREA' });
  });

  test('max_service_distance_km left NULL enforces no cap at all', async () => {
    const dbConn = fakeDbConn({ branchRows: branchCoords, rateRows: [baseRate] }); // baseRate.max_service_distance_km is null
    const result = await calculateHomeCollectionFare({
      branchId: 3, pickupLat: 13.0827, pickupLng: 81.2, dbConn, // same "far" pickup as the capped test above
    });
    expect(result.finalFare).toBeGreaterThan(0); // succeeds instead of throwing OUTSIDE_SERVICE_AREA
  });

  test("the active-rate query orders by effective_from DESC — most recently effective row wins when multiple are is_active", async () => {
    // getActiveKmRate's own SQL does the ordering/filtering in the database;
    // this test only proves calculateHomeCollectionFare uses whichever
    // single row its query returns (LIMIT 1) without any additional
    // in-application re-selection — i.e. it trusts the query, doesn't
    // second-guess it. The query text itself is asserted below.
    const dbConn = fakeDbConn({ branchRows: branchCoords, rateRows: [{ ...baseRate, rate_id: 9, base_fare: '99.00' }] });
    const result = await calculateHomeCollectionFare({ branchId: 3, pickupLat: 13.08, pickupLng: 80.27, dbConn });
    expect(result.rateId).toBe(9);
    expect(result.baseFare).toBe(99);
    const rateQuerySql = dbConn.execute.mock.calls[1][0];
    expect(rateQuerySql).toMatch(/is_active\s*=\s*1/);
    expect(rateQuerySql).toMatch(/effective_from\s*<=\s*\?/);
    expect(rateQuerySql).toMatch(/ORDER BY effective_from DESC/);
    expect(rateQuerySql).toMatch(/LIMIT 1/);
  });
});
