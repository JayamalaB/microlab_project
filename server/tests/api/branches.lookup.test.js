// Tests GET /api/branches/lookup — which branch a customer gets.
jest.mock('../../config/db');
jest.mock('../../config/settings');
jest.mock('../../services/branchCodes', () => ({ getBranchCode: jest.fn().mockResolvedValue('04') }));
jest.mock('../../utils/dbLogger');
const db       = require('../../config/db');
const settings = require('../../config/settings');
const request  = require('supertest');
const { buildTestApp } = require('../helpers/testApp');

const app = buildTestApp('/api/branches', require('../../routes/branches'));

const branch = (id, latitude, longitude) => ({
  branch_id: id, name: `Branch ${id}`, address: 'Addr', location: 'City', pincode: '638001',
  telephone_no: null, mobile_no: null, email: null, latitude, longitude,
});
const NEAR = branch(1, '11.30', '77.70');
const FAR  = branch(2, '12.30', '77.70');

let withSlots;

// Answers by query text, like the real database would.
function wireDb({ byPincode = [], byCity = [], all = [] } = {}) {
  db.execute.mockReset().mockImplementation(async (sql, params = []) => {
    if (/FROM ip_available_slots ias/.test(sql)) return [withSlots.includes(params[0]) ? [{ 1: 1 }] : []];
    if (/WHERE branch_pincode = \?/.test(sql)) return [byPincode];
    if (/LOWER\(branch_city\)/.test(sql)) return [byCity];
    if (/WHERE branch_latitude IS NOT NULL/.test(sql)) return [all];
    return [[]];
  });
}
const get = (query) => request(app).get('/api/branches/lookup').query(query);
const slotChecks = () => db.execute.mock.calls.filter(c => /FROM ip_available_slots ias/.test(c[0]));

beforeAll(() => {
  jest.spyOn(process.stdout, 'write').mockImplementation(() => true);
  jest.spyOn(console, 'error').mockImplementation(() => {});
});
beforeEach(() => {
  withSlots = [1, 2];
  settings.get.mockReset().mockImplementation((_k, def) => def);
});

describe('GPS lookup', () => {
  const gps = { lat: '11.30', lng: '77.70', pincode: '638001', source: 'gps' };

  test('takes the nearest branch with a bookable time', async () => {
    wireDb({ all: [FAR, NEAR] });
    const res = await get(gps);
    expect(res.body.branch.branchId).toBe(1);
    expect(res.body.branch.isFallback).toBe(false);
  });

  test('moves to the next branch when the nearest has nothing bookable', async () => {
    withSlots = [2];
    wireDb({ all: [FAR, NEAR] });
    const res = await get(gps);
    expect(res.body.branch.branchId).toBe(2);
    expect(res.body.branch.isFallback).toBe(true);
  });

  test('looks over the coming days, not only today', async () => {
    wireDb({ all: [NEAR] });
    await get(gps);
    const [branchId, fromDate, toDate] = slotChecks()[0][1];
    expect(branchId).toBe(1);
    const days = (new Date(toDate) - new Date(fromDate)) / 86400000;
    expect(days).toBe(7);
  });

  test('the number of days comes from ip_settings', async () => {
    settings.get.mockImplementation((k, def) => (k === 'branch_lookup_days' ? '3' : def));
    wireDb({ all: [NEAR] });
    await get(gps);
    const [, fromDate, toDate] = slotChecks()[0][1];
    expect((new Date(toDate) - new Date(fromDate)) / 86400000).toBe(3);
  });

  test('a date the caller knows is checked on its own', async () => {
    wireDb({ all: [NEAR] });
    await get({ ...gps, date: '2099-01-01' });
    const [, fromDate, toDate] = slotChecks()[0][1];
    expect(fromDate).toBe('2099-01-01');
    expect(toDate).toBe('2099-01-01');
  });

  test('a time already past today does not count', async () => {
    wireDb({ all: [NEAR] });
    await get(gps);
    expect(slotChecks()[0][0]).toMatch(/ts\.slot_date != \? OR ias\.slot_time > \?/);
  });

  test('nothing bookable anywhere is a 404', async () => {
    withSlots = [];
    wireDb({ all: [NEAR] });
    expect((await get(gps)).status).toBe(404);
  });
});

describe('manual pincode', () => {
  test('several branches on one pincode: nearest with a bookable time', async () => {
    withSlots = [2];
    wireDb({ byPincode: [NEAR, FAR] });
    const res = await get({ pincode: '638001', lat: '11.30', lng: '77.70' });
    expect(res.body.branch.branchId).toBe(2);
  });

  test('a matched branch with nothing bookable falls to the nearest that has', async () => {
    withSlots = [2];
    wireDb({ byPincode: [NEAR], all: [NEAR, FAR] });
    const res = await get({ pincode: '638001', lat: '11.30', lng: '77.70' });
    expect(res.body.branch.branchId).toBe(2);
  });

  test('with no location known, the one match is still returned', async () => {
    withSlots = [];
    wireDb({ byPincode: [NEAR] });
    const res = await get({ pincode: '638001' });
    expect(res.body.branch.branchId).toBe(1);
  });
});

test('a city with several branches gets the nearest', async () => {
  wireDb({ byCity: [FAR, NEAR] });
  const res = await get({ place: 'Erode', lat: '11.30', lng: '77.70', pincode: undefined });
  expect(res.body.branch.branchId).toBe(1);
});

test('every lookup query leaves out inactive branches', async () => {
  wireDb({ byCity: [NEAR], all: [] });
  await get({ place: 'Erode', pincode: '638001', lat: '11.30', lng: '77.70' });
  const branchQueries = db.execute.mock.calls.map(c => c[0]).filter(sql => /FROM ip_branches/.test(sql) && /branch_name AS name/.test(sql));
  expect(branchQueries.length).toBeGreaterThan(0);
  branchQueries.forEach(sql => expect(sql).toMatch(/branch_active = 1/));
});
