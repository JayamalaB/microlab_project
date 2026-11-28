// saveSlots on a slot that already has bookings (controllers/
// technicianController.js). Such a slot is never rebuilt; before this fix a
// duration picked for it was silently dropped, so a slot saved earlier with
// no duration never got appointment times (the app kept asking for a
// duration, and dispatch's appointment-time filter never matched the
// technician).
jest.mock('../../config/db');
jest.mock('../../config/settings');
jest.mock('../../services/clientSync');
jest.mock('../../socket/bookingSocket', () => ({
  triggerScheduledDispatch: jest.fn(), freeTechnician: jest.fn(), unassignAndRedispatch: jest.fn(),
  stopDispatch: jest.fn(), redispatchBooking: jest.fn(), forceTechnicianOffline: jest.fn(),
}));
jest.mock('../../services/technicianBranches', () => ({
  getTechnicianBranches: jest.fn(async () => [{ branchId: 4, name: 'PEELAMEDU', isDefault: true }]),
  describeTechnicians: jest.fn(async (ids) => ids.join(', ')),
}));
const db      = require('../../config/db');
const request = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { technicianToken, primeAuthCheck } = require('../helpers/jwt');
const { createMockConnection } = require('../helpers/mockConnection');

const technicians = buildTestApp('/api/technicians', require('../../routes/technicians'));
const techToken   = technicianToken({ id: 17 });
const FUTURE = '2099-01-01';

beforeAll(() => { jest.spyOn(process.stdout, 'write').mockImplementation(() => true); });

// Slot 2 runs 14:00–16:00 → 8 times at 15 min, 4 at 30 min.
function save(existing, slots, presentTimes = []) {
  const conn = createMockConnection();
  conn.query.mockImplementation(async (sql) => {
    if (/FROM ip_technician_slots ts/.test(sql)) return [existing];
    if (/SELECT slot_start, slot_end FROM ip_slots/.test(sql)) return [[{ slot_start: '14:00:00', slot_end: '16:00:00' }]];
    if (/SELECT slot_time FROM ip_available_slots/.test(sql)) return [presentTimes.map(t => ({ slot_time: t }))];
    return /^\s*SELECT/.test(sql) ? [[]] : [{ insertId: 99 }];
  });
  db.getConnection.mockResolvedValue(conn);
  db.execute.mockReset().mockResolvedValue([[], {}]);
  primeAuthCheck(db, techToken);
  db.execute.mockResolvedValueOnce([[{ branch_id: 4 }]]); // ip_technicians own branch
  return { conn, res: request(technicians).put('/api/technicians/17/slots').set('Authorization', `Bearer ${techToken}`).send({ slots }) };
}
const run = (conn, re) => conn.query.mock.calls.filter(c => re.test(c[0]));
const timeInserts = (conn) => run(conn, /INSERT INTO ip_available_slots/).map(c => String(c[1][2]).slice(0, 5));

test('booked slot with no duration: takes the duration and gets its times', async () => {
  const existing = [{ tech_slot_id: 1048, slot_id: 2, duration_minutes: null, slot_date: FUTURE, has_bookings: 1 }];
  const { conn, res } = save(existing, [{ date: FUTURE, slot_ids: [2], durations: { 2: 15 } }]);

  const r = await res;
  expect(r.status).toBe(200);
  expect(r.body.keptDurations).toEqual([]);

  const upd = run(conn, /SET duration_minutes = \?, max_bookings = GREATEST\(\?, booked_count\)/);
  expect(upd).toHaveLength(1);
  expect(upd[0][1]).toEqual([15, 8, 1048]);
  expect(timeInserts(conn)).toEqual(['14:00', '14:15', '14:30', '14:45', '15:00', '15:15', '15:30', '15:45']);
  // never rebuilt — its bookings point at it
  expect(run(conn, /DELETE FROM ip_technician_slots WHERE/)).toHaveLength(0);
  expect(run(conn, /INSERT INTO ip_technician_slots/)).toHaveLength(0);
});

test('booked slot with a different duration: keeps its own, the app is told', async () => {
  const existing = [{ tech_slot_id: 1046, slot_id: 2, duration_minutes: 30, slot_date: FUTURE, has_bookings: 1 }];
  const { conn, res } = save(
    existing, [{ date: FUTURE, slot_ids: [2], durations: { 2: 15 } }],
    ['14:00:00', '14:30:00', '15:00:00', '15:30:00'],
  );

  const r = await res;
  expect(r.status).toBe(200);
  expect(r.body.keptDurations).toEqual([{ date: FUTURE, slotId: 2, durationMinutes: 30 }]);
  expect(run(conn, /SET duration_minutes = \?/)).toHaveLength(0);
  expect(timeInserts(conn)).toEqual([]); // its 30-min times are all there
});

test('booked slot, same duration: nothing to report', async () => {
  const existing = [{ tech_slot_id: 1046, slot_id: 2, duration_minutes: 15, slot_date: FUTURE, has_bookings: 1 }];
  const { conn, res } = save(existing, [{ date: FUTURE, slot_ids: [2], durations: { 2: 15 } }],
    ['14:00:00', '14:15:00', '14:30:00', '14:45:00', '15:00:00', '15:15:00', '15:30:00', '15:45:00']);

  const r = await res;
  expect(r.body.keptDurations).toEqual([]);
  expect(run(conn, /SET duration_minutes = \?/)).toHaveLength(0);
});

test('unbooked slot with no duration: rebuilt with the new duration, as before', async () => {
  const existing = [{ tech_slot_id: 80, slot_id: 2, duration_minutes: null, slot_date: FUTURE, has_bookings: 0 }];
  const { conn, res } = save(existing, [{ date: FUTURE, slot_ids: [2], durations: { 2: 30 } }]);

  const r = await res;
  expect(r.status).toBe(200);
  expect(run(conn, /DELETE FROM ip_technician_slots WHERE/)).toHaveLength(1);
  const ins = run(conn, /INSERT INTO ip_technician_slots/)[0][1];
  expect(ins[4]).toBe(4);   // max_bookings = 4 times
  expect(ins[5]).toBe(30);  // duration_minutes
  expect(timeInserts(conn)).toEqual(['14:00', '14:30', '15:00', '15:30']);
});
