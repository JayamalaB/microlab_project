// Tests services/dispatchDistance.js — customer → branch distances for
// dispatch: the original branch (saved once), the serving branch, and the
// signed difference / non-negative extra km between them.
jest.mock('../../config/db');
const db = require('../../config/db');
const dd = require('../../services/dispatchDistance');

// 1 km of latitude on the haversine sphere (R = 6371 km).
const KM_LAT = 180 / (Math.PI * 6371);
const CUSTOMER = { lat: 11.0, lng: 77.0 };
const at = (km) => ({ latitude: CUSTOMER.lat + km * KM_LAT, longitude: CUSTOMER.lng });
// Peelamedu 2 km, Coimbatore 6.1 km, a far branch 9 km, one without a location.
const BRANCHES = { 2: at(2), 1: at(6.1), 4: at(9), 8: { latitude: null, longitude: null } };

const missingColumn = () => Object.assign(new Error("Unknown column 'original_branch_id'"), { code: 'ER_BAD_FIELD_ERROR' });

function wire({ booking = null, stored = null, failColumns = false } = {}) {
  db.execute.mockReset().mockImplementation(async (sql, params = []) => {
    if (/FROM ip_branches WHERE branch_id = \?/.test(sql)) {
      const b = BRANCHES[params[0]];
      return [b ? [b] : []];
    }
    if (/SELECT original_branch_id, original_distance_km FROM ip_bookings/.test(sql)) {
      if (failColumns) throw missingColumn();
      return [stored ? [stored] : [{ original_branch_id: null, original_distance_km: null }]];
    }
    if (/SELECT branch_id, collection_latitude/.test(sql)) {
      if (failColumns) throw missingColumn();
      return [booking ? [booking] : []];
    }
    if (/FROM ip_technicians WHERE technician_id/.test(sql)) return [[{ branch_id: 1 }]];
    return [{ affectedRows: 1 }];
  });
}
const updates = () => db.execute.mock.calls.filter(c => /^\s*UPDATE ip_bookings b/.test(c[0]));

describe('customerToBranchKm', () => {
  test('straight line from the customer to the branch, 2 decimals', async () => {
    wire();
    expect(await dd.customerToBranchKm(2, CUSTOMER.lat, CUSTOMER.lng)).toBe(2);
    expect(await dd.customerToBranchKm(1, CUSTOMER.lat, CUSTOMER.lng)).toBe(6.1);
  });

  test('unknown when the branch or the customer has no location', async () => {
    wire();
    expect(await dd.customerToBranchKm(8, CUSTOMER.lat, CUSTOMER.lng)).toBeNull();
    expect(await dd.customerToBranchKm(99, CUSTOMER.lat, CUSTOMER.lng)).toBeNull();
    expect(await dd.customerToBranchKm(2, null, CUSTOMER.lng)).toBeNull();
    expect(await dd.customerToBranchKm(null, CUSTOMER.lat, CUSTOMER.lng)).toBeNull();
  });
});

describe('distanceDifference', () => {
  test('a farther serving branch: positive difference, same extra', () => {
    expect(dd.distanceDifference(6.1, 2)).toEqual({ differenceKm: 4.1, extraKm: 4.1 });
  });
  test('a nearer serving branch: negative difference, extra 0', () => {
    expect(dd.distanceDifference(6.1, 9)).toEqual({ differenceKm: -2.9, extraKm: 0 });
  });
  test('the same branch: 0 / 0', () => {
    expect(dd.distanceDifference(2, 2)).toEqual({ differenceKm: 0, extraKm: 0 });
  });
  test('unknown when either distance is unknown', () => {
    expect(dd.distanceDifference(null, 2)).toEqual({ differenceKm: null, extraKm: null });
    expect(dd.distanceDifference(6.1, null)).toEqual({ differenceKm: null, extraKm: null });
  });
  test('formatDifference', () => {
    expect(dd.formatDifference(4.1)).toBe('+4.10 km');
    expect(dd.formatDifference(-2.9)).toBe('-2.90 km');
    expect(dd.formatDifference(0)).toBe('0.00 km');
    expect(dd.formatDifference(null)).toBe('unknown');
  });
});

describe('loadOriginalBaseline', () => {
  test('first dispatch: the starting branch is the original, saved for the whole visit only where empty', async () => {
    wire();
    const base = await dd.loadOriginalBaseline(900, 2, CUSTOMER.lat, CUSTOMER.lng);
    expect(base).toEqual({ originalBranchId: 2, originalDistanceKm: 2, saved: true });
    const [sql, params] = updates()[0];
    expect(sql).toMatch(/original_branch_id\s+= COALESCE\(b\.original_branch_id, \?\)/);
    expect(sql).toMatch(/b\.visit_group_id = p\.visit_group_id/); // family siblings too
    expect(params).toEqual([900, 2, 2]);
  });

  test('a redispatch after another branch served keeps the first original', async () => {
    // branch_id was changed to the serving branch (1) on accept; the saved
    // original (2, 2 km) must stay the baseline.
    wire({ stored: { original_branch_id: 2, original_distance_km: '2.00' } });
    const base = await dd.loadOriginalBaseline(900, 1, CUSTOMER.lat, CUSTOMER.lng);
    expect(base).toMatchObject({ originalBranchId: 2, originalDistanceKm: 2 });
  });

  test('before the migration: worked out from the starting branch, nothing saved', async () => {
    wire({ failColumns: true });
    const base = await dd.loadOriginalBaseline(900, 2, CUSTOMER.lat, CUSTOMER.lng);
    expect(base).toEqual({ originalBranchId: 2, originalDistanceKm: 2, saved: false });
    expect(updates()).toHaveLength(0);
  });
});

describe('recordServingBranch', () => {
  const booking = (over = {}) => ({
    branch_id: 1, collection_latitude: CUSTOMER.lat, collection_longitude: CUSTOMER.lng,
    original_branch_id: 2, original_distance_km: '2.00', ...over,
  });

  test('Peelamedu → Coimbatore: served 6.10 km, difference and extra +4.10 km, for the whole visit', async () => {
    wire({ booking: booking() });
    const r = await dd.recordServingBranch(900, { servedBranchId: 1, servedDistanceKm: 6.1 });
    expect(r).toEqual({
      originalBranchId: 2, originalDistanceKm: 2, servedBranchId: 1, servedDistanceKm: 6.1, differenceKm: 4.1, extraKm: 4.1,
    });
    const [sql, params] = updates()[0];
    expect(sql).toMatch(/b\.visit_group_id = p\.visit_group_id/);
    expect(params).toEqual([900, 2, 2, 1, 6.1, 4.1, 4.1]);
  });

  test('a nearer branch served: the difference is negative, extra stays 0', async () => {
    wire({ booking: booking({ original_branch_id: 4, original_distance_km: '9.00' }) });
    const r = await dd.recordServingBranch(900, { servedBranchId: 1, servedDistanceKm: 6.1 });
    expect(r).toMatchObject({ differenceKm: -2.9, extraKm: 0 });
  });

  test('the saved original wins over one passed in', async () => {
    wire({ booking: booking() });
    const r = await dd.recordServingBranch(900, { servedBranchId: 1, originalBranchId: 1, originalDistanceKm: 6.1 });
    expect(r).toMatchObject({ originalBranchId: 2, originalDistanceKm: 2, differenceKm: 4.1 });
  });

  test('missing values are worked out from the booking (late accept after the search ended)', async () => {
    wire({ booking: booking() });
    const r = await dd.recordServingBranch(900, {});
    expect(r).toMatchObject({ servedBranchId: 1, servedDistanceKm: 6.1, originalBranchId: 2, differenceKm: 4.1 });
  });

  test('admin assignment of a never-dispatched booking: the booking\'s branch is the original', async () => {
    wire({ booking: booking({ branch_id: 2, original_branch_id: null, original_distance_km: null }) });
    const r = await dd.recordServingBranch(900, { servedBranchId: 1 });
    expect(r).toMatchObject({ originalBranchId: 2, originalDistanceKm: 2, servedBranchId: 1, servedDistanceKm: 6.1, extraKm: 4.1 });
  });

  test('before the migration: skipped with a reason, never throws', async () => {
    wire({ failColumns: true });
    expect(await dd.recordServingBranch(900, { servedBranchId: 1 })).toEqual({
      skipped: 'distance columns missing — run add_dispatch_distance_columns.sql',
    });
  });

  test('a database error is reported as skipped, never thrown', async () => {
    db.execute.mockReset().mockRejectedValue(new Error('db down'));
    const spy = jest.spyOn(console, 'error').mockImplementation(() => {});
    expect(await dd.recordServingBranch(900, {})).toEqual({ skipped: 'db down' });
    spy.mockRestore();
  });
});

test('technicianBranchId is the technician\'s own branch', async () => {
  wire();
  expect(await dd.technicianBranchId(17)).toBe(1);
  expect(await dd.technicianBranchId(null)).toBeNull();
});
