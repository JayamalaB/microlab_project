// Tests picking branches per slot when a technician saves availability —
// controllers/technicianController.js saveSlots / getSlots, and the customer
// slot list (controllers/slotsController.js) offering a slot only at the
// branches picked for it (services/slotBranches.js).
//
// One slot, one capacity: offered at several branches, the first booking
// takes it for all of them.
jest.mock('../../config/db');
jest.mock('../../config/settings');
jest.mock('../../services/clientSync');
jest.mock('../../socket/bookingSocket', () => ({
  triggerScheduledDispatch: jest.fn(), freeTechnician: jest.fn(), unassignAndRedispatch: jest.fn(),
  stopDispatch: jest.fn(), redispatchBooking: jest.fn(), forceTechnicianOffline: jest.fn(),
}));
// Technician 17: own branch 4, also works at branch 7 (ASMX). Branch 9: not theirs.
jest.mock('../../services/technicianBranches', () => ({
  getTechnicianBranches: jest.fn(async () => [
    { branchId: 4, name: 'PEELAMEDU', isDefault: true },
    { branchId: 7, name: 'COIMBATORE', isDefault: false },
  ]),
  describeTechnicians: jest.fn(async (ids) => ids.join(', ')),
}));
const db      = require('../../config/db');
const request = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { technicianToken, primeAuthCheck } = require('../helpers/jwt');
const { createMockConnection } = require('../helpers/mockConnection');

const technicians = buildTestApp('/api/technicians', require('../../routes/technicians'));
const slotsApp    = buildTestApp('/api/slots', require('../../routes/slots'));
const techToken   = technicianToken({ id: 17 });
const FUTURE = '2099-01-01';

beforeAll(() => { jest.spyOn(process.stdout, 'write').mockImplementation(() => true); });

describe('saving slots with their branches', () => {
  function save(existing, slots) {
    const conn = createMockConnection();
    conn.query.mockImplementation(async (sql) => {
      if (/FROM ip_technician_slots ts/.test(sql)) return [existing];
      if (/SELECT slot_start, slot_end FROM ip_slots/.test(sql)) return [[{ slot_start: '14:00:00', slot_end: '16:00:00' }]];
      return /^\s*SELECT/.test(sql) ? [[]] : [{ insertId: 99 }];
    });
    db.getConnection.mockResolvedValue(conn);
    db.execute.mockReset().mockResolvedValue([[], {}]);
    primeAuthCheck(db, techToken);
    db.execute.mockResolvedValueOnce([[{ branch_id: 4 }]]); // ip_technicians own branch
    return { conn, res: request(technicians).put('/api/technicians/17/slots').set('Authorization', `Bearer ${techToken}`).send({ slots }) };
  }
  const run = (conn, re) => conn.query.mock.calls.filter(c => re.test(c[0]));
  const branchInserts = (conn) => run(conn, /INSERT INTO ip_technician_slot_branches/).map(c => c[1]);
  const slotInsert = (conn) => run(conn, /INSERT INTO ip_technician_slots/)[0][1];

  test('a slot offered at both branches: one slot row, two branch rows', async () => {
    const { conn, res } = save([], [{ date: FUTURE, slot_ids: [2], durations: { 2: 30 }, branches: { 2: [4, 7] } }]);
    expect((await res).status).toBe(200);
    expect(run(conn, /INSERT INTO ip_technician_slots/)).toHaveLength(1);   // one capacity
    expect(slotInsert(conn)[3]).toBe(4);                                     // branch_id = first picked
    expect(branchInserts(conn)).toEqual([[99, 4, 99, 7]]);
  });

  test('picked separately per day', async () => {
    const { conn, res } = save([], [
      { date: '2099-01-01', slot_ids: [2], branches: { 2: [7] } },
      { date: '2099-01-02', slot_ids: [2], branches: { 2: [4, 7] } },
    ]);
    await res;
    expect(branchInserts(conn)).toEqual([[99, 7], [99, 4, 99, 7]]);
  });

  test('a branch the technician does not work at is dropped', async () => {
    const { conn, res } = save([], [{ date: FUTURE, slot_ids: [2], branches: { 2: [9, 7] } }]);
    await res;
    expect(branchInserts(conn)).toEqual([[99, 7]]);
  });

  test('no branch picked (single-branch technician, older app): the own branch', async () => {
    const { conn, res } = save([], [{ date: FUTURE, slot_ids: [2], durations: { 2: 30 } }]);
    await res;
    expect(slotInsert(conn)[3]).toBe(4);
    expect(branchInserts(conn)).toEqual([[99, 4]]);
  });

  test('a kept slot gets the branches picked now', async () => {
    const existing = [{ tech_slot_id: 80, slot_id: 2, duration_minutes: 30, slot_date: FUTURE, has_bookings: 0 }];
    const { conn, res } = save(existing, [{ date: FUTURE, slot_ids: [2], durations: { 2: 30 }, branches: { 2: [7] } }]);
    await res;
    expect(run(conn, /SET is_available = 1, branch_id = \?/)[0][1]).toEqual([7, 80]);
    expect(run(conn, /DELETE FROM ip_technician_slot_branches/)[0][1]).toEqual([80]);
    expect(branchInserts(conn)).toEqual([[80, 7]]);
  });

  test('a removed slot loses its branch rows too', async () => {
    const existing = [{ tech_slot_id: 80, slot_id: 2, duration_minutes: 30, slot_date: FUTURE, has_bookings: 0 }];
    const { conn, res } = save(existing, [{ date: FUTURE, slot_ids: [] }]);
    await res;
    expect(run(conn, /DELETE FROM ip_technician_slot_branches/)[0][1]).toEqual([80]);
    expect(run(conn, /DELETE FROM ip_technician_slots WHERE/)).toHaveLength(1);
  });
});

describe('the technician\'s saved slots', () => {
  test('come back with their branches, and the technician\'s branch list for the picker', async () => {
    db.execute.mockReset().mockResolvedValue([[], {}]);
    primeAuthCheck(db, techToken);
    db.execute
      .mockResolvedValueOnce([[{ slot_id: 2, slot_label: '2-4 PM' }]])  // master slots
      .mockResolvedValueOnce([[
        { slot_id: 2, slot_date: FUTURE, branch_id: 4, slot_branch_ids: '4,7' },
        { slot_id: 3, slot_date: FUTURE, branch_id: 4, slot_branch_ids: null },  // saved before picking
      ]]);
    const res = await request(technicians).get('/api/technicians/17/slots').set('Authorization', `Bearer ${techToken}`);
    expect(res.status).toBe(200);
    expect(res.body.techSlots.map(s => s.branch_ids)).toEqual([[4, 7], [4]]);
    expect(res.body.branches.map(b => b.branchId)).toEqual([4, 7]);
  });
});

describe('customer slot list', () => {
  test('lists only slots offered at the branch: picked for it, or older slots of that branch', async () => {
    db.execute.mockReset().mockImplementation(async (sql) => {
      if (/AS remaining/.test(sql)) return [[{ time_slot_id: 11, slot_id: 2, time: '14:00', label: '02:00 PM', remaining: 1 }]];
      if (/SELECT ts\.tech_slot_id, ts\.technician_id/.test(sql)) return [[{ tech_slot_id: 80, technician_id: 17 }]];
      return [[]];
    });
    const res = await request(slotsApp).get('/api/slots').query({ branch_id: 7, date: FUTURE, slot_type: 'home_collection' });
    expect(res.status).toBe(200);
    expect(res.body.slots).toHaveLength(1);
    const [sql, params] = db.execute.mock.calls.find(c => /AS remaining/.test(c[0]));
    expect(sql).toMatch(/ip_technician_slot_branches sb\s+WHERE sb\.tech_slot_id = ts\.tech_slot_id AND sb\.branch_id = \?/);
    expect(sql).toMatch(/ts\.branch_id = \? AND NOT EXISTS/);
    expect(params.slice(0, 3)).toEqual([FUTURE, '7', '7']); // branch_id from the query string
  });
});
