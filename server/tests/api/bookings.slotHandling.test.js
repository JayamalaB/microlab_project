// A time can be booked once, a cancelled booking gives its time back and stops
// its search, and saving a technician's slots never touches a booked one.
jest.mock('../../config/db');
jest.mock('../../config/settings');
jest.mock('../../services/clientSync');
jest.mock('../../services/itemPrices', () => ({ checkItemPrices: async () => ({ ok: true }) }));
jest.mock('../../socket/bookingSocket', () => ({
  triggerScheduledDispatch: jest.fn(),
  freeTechnician: jest.fn(),
  unassignAndRedispatch: jest.fn(),
  stopDispatch: jest.fn(),
  redispatchBooking: jest.fn().mockResolvedValue(),
  forceTechnicianOffline: jest.fn(),
}));
const db         = require('../../config/db');
const settings   = require('../../config/settings');
const clientSync = require('../../services/clientSync');
const { stopDispatch, redispatchBooking } = require('../../socket/bookingSocket');
const request    = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { customerToken, technicianToken, primeAuthCheck } = require('../helpers/jwt');
const { createMockConnection } = require('../helpers/mockConnection');

const bookings    = buildTestApp('/api/bookings', require('../../routes/bookings'));
const technicians = buildTestApp('/api/technicians', require('../../routes/technicians'));
const custToken = customerToken({ clientId: 2001 });
const techToken = technicianToken({ id: 17 });

const items = [{ packageId: 7, finalPrice: 500 }];

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  db.getConnection.mockReset();
  settings.getBool.mockReset().mockImplementation((_k, def) => def);
  settings.get.mockReset().mockImplementation((_k, def) => def);
  settings.getList.mockReset().mockImplementation((_k, def) => def);
  clientSync.syncBookingToClient.mockReset().mockResolvedValue({ success: true });
  stopDispatch.mockReset().mockReturnValue(false);
  redispatchBooking.mockClear();
});

describe('booking a time', () => {
  function connWhereSlotIs(affectedRows) {
    let id = 900;
    const conn = createMockConnection();
    conn.execute.mockImplementation(async (sql) => {
      if (/INSERT INTO ip_bookings/.test(sql)) return [{ insertId: id++ }];
      if (/UPDATE ip_available_slots/.test(sql)) return [{ affectedRows }];
      return /^\s*SELECT/.test(sql) ? [[]] : [{}];
    });
    db.getConnection.mockResolvedValue(conn);
    return conn;
  }
  const post = (path, body) => {
    primeAuthCheck(db, custToken);
    return request(bookings).post(path).set('Authorization', `Bearer ${custToken}`)
      .send({ bookingType: 'lab_visit', availableSlotId: 55, paymentType: 'pay_later', ...body });
  };

  test.each([
    ['a single booking', '/api/bookings', { patientId: 501, items }],
    ['a family visit', '/api/bookings/family', { members: [{ patientId: 501, items }, { patientId: 502, items }] }],
  ])('%s is refused with nothing saved when the time was just taken', async (_n, path, body) => {
    const conn = connWhereSlotIs(0);
    const res = await post(path, body);
    expect(res.status).toBe(409);
    expect(res.body.code).toBe('SLOT_TAKEN');
    expect(conn.rollback).toHaveBeenCalled();
    expect(conn.commit).not.toHaveBeenCalled();
  });

  test('the update only succeeds while the time is free', async () => {
    const conn = connWhereSlotIs(1);
    const res = await post('/api/bookings', { patientId: 501, items });
    expect(res.status).toBe(201);
    const [[sql]] = conn.execute.mock.calls.filter(c => /UPDATE ip_available_slots/.test(c[0]));
    expect(sql).toMatch(/AND is_available = 1/);
  });

  test('slot-status tells the app whether a time is still free', async () => {
    primeAuthCheck(db, custToken);
    db.execute.mockResolvedValueOnce([[{ is_available: 0 }]]);
    const res = await request(bookings).get('/api/bookings/slot-status/55').set('Authorization', `Bearer ${custToken}`);
    expect(res.body.available).toBe(false);
  });
});

describe('cancelling', () => {
  const booking = (over) => ({
    booking_id: 900, booking_ref: 'B1', status: 'pending', booking_type: 'lab_visit', total_amount: 500,
    available_slot_id: 55, booking_date: '2099-01-01', patient_id: 501, visit_group_id: null,
    amount_paid: 0, items_total: 500, ...over,
  });

  function wire({ row = booking(), stillInUse = false, nextMember = null } = {}) {
    primeAuthCheck(db, custToken);
    db.execute.mockImplementation(async (sql) => {
      if (/SELECT b\.booking_id, b\.booking_ref, b\.status/.test(sql)) return [[row]];
      if (/SELECT 1 FROM ip_bookings\s+WHERE available_slot_id/.test(sql)) return [stillInUse ? [{ 1: 1 }] : []];
      if (/SET is_available = 1/.test(sql)) return [{ affectedRows: 1 }];
      if (/SELECT technician_slot_id, lab_slot_id/.test(sql)) return [[{ technician_slot_id: 8, lab_slot_id: null }]];
      if (/WHERE visit_group_id = \? AND status IN/.test(sql)) return [nextMember ? [nextMember] : []];
      return /^\s*SELECT/.test(sql) ? [[]] : [{ affectedRows: 1 }];
    });
  }
  const cancel = () => request(bookings).post('/api/bookings/900/cancel').set('Authorization', `Bearer ${custToken}`).send({});
  const reopened = () => db.execute.mock.calls.filter(c => /SET is_available = 1/.test(c[0]));

  test('stops a running search and gives the time back', async () => {
    wire();
    const res = await cancel();
    expect(res.status).toBe(200);
    expect(stopDispatch).toHaveBeenCalledWith(900);
    expect(reopened()).toHaveLength(1);
    expect(db.execute.mock.calls.some(c => /booked_count = GREATEST\(0, booked_count - 1\)/.test(c[0]))).toBe(true);
  });

  test('keeps the time while another family member still uses it', async () => {
    wire({ row: booking({ visit_group_id: 'VG-1' }), stillInUse: true });
    await cancel();
    expect(reopened()).toHaveLength(0);
  });

  test('a time another update already reopened is not counted down twice', async () => {
    wire();
    const inner = db.execute.getMockImplementation();
    db.execute.mockImplementation(async (sql, p) => (
      /SET is_available = 1/.test(sql) ? [{ affectedRows: 0 }] : inner(sql, p)
    ));
    await cancel();
    expect(db.execute.mock.calls.some(c => /booked_count - 1/.test(c[0]))).toBe(false);
  });

  test('the family search moves to the next member if it was on this one', async () => {
    wire({ row: booking({ visit_group_id: 'VG-1' }), stillInUse: true, nextMember: { booking_id: 901 } });
    stopDispatch.mockReturnValue(true);
    await cancel();
    expect(redispatchBooking).toHaveBeenCalledWith(901, { reason: 'member_cancelled' });
  });

  test('no search running means no new search', async () => {
    wire({ row: booking({ visit_group_id: 'VG-1' }), nextMember: { booking_id: 901 } });
    await cancel();
    expect(redispatchBooking).not.toHaveBeenCalled();
  });
});

describe('saving technician slots', () => {
  const FUTURE = '2099-01-01';
  const row = (over) => ({
    tech_slot_id: 80, slot_id: 2, duration_minutes: 30, slot_date: FUTURE, has_bookings: 0, ...over,
  });

  function save(existing, slots) {
    const conn = createMockConnection();
    conn.query.mockImplementation(async (sql) => {
      if (/FROM ip_technician_slots ts/.test(sql)) return [existing];
      if (/SELECT slot_start, slot_end FROM ip_slots/.test(sql)) return [[{ slot_start: '09:00:00', slot_end: '10:00:00' }]];
      if (/SELECT slot_time FROM ip_available_slots/.test(sql)) return [[{ slot_time: '09:00:00' }]];
      return /^\s*SELECT/.test(sql) ? [[]] : [{ insertId: 99 }];
    });
    db.getConnection.mockResolvedValue(conn);
    primeAuthCheck(db, techToken);
    db.execute.mockResolvedValueOnce([[{ branch_id: 4 }]]);
    return { conn, res: request(technicians).put('/api/technicians/17/slots').set('Authorization', `Bearer ${techToken}`).send({ slots }) };
  }
  const run = (conn, re) => conn.query.mock.calls.filter(c => re.test(c[0]));
  const day = (ids, durations) => [{ date: FUTURE, slot_ids: ids, durations }];

  test('a booked slot the technician keeps is not deleted or rebuilt', async () => {
    const { conn, res } = save([row({ has_bookings: 1 })], day([2], { 2: 30 }));
    expect((await res).status).toBe(200);
    expect(run(conn, /DELETE FROM ip_technician_slots/)).toHaveLength(0);
    expect(run(conn, /DELETE FROM ip_available_slots/)).toHaveLength(0);
    expect(run(conn, /INSERT INTO ip_technician_slots/)).toHaveLength(0);
  });

  test('a booked slot the technician unticks keeps its booked times and withdraws the free ones', async () => {
    const { conn, res } = save([row({ has_bookings: 1 })], day([]));
    await res;
    expect(run(conn, /DELETE FROM ip_technician_slots/)).toHaveLength(0);
    const [[sql]] = run(conn, /DELETE FROM ip_available_slots/);
    expect(sql).toMatch(/AND is_available = 1/);
    expect(run(conn, /SET is_available = \? WHERE tech_slot_id/)[0][1]).toEqual([0, 80]);
  });

  test('ticking a booked slot again puts back only the missing free times', async () => {
    const { conn, res } = save([row({ has_bookings: 1 })], day([2], { 2: 30 }));
    await res;
    const inserted = run(conn, /INSERT INTO ip_available_slots/).map(c => c[1][2]);
    expect(inserted.map(t => String(t).slice(0, 5))).toEqual(['09:30']); // 09:00 already has a row
  });

  test('an unbooked slot the technician unticks is deleted', async () => {
    const { conn, res } = save([row()], day([]));
    await res;
    expect(run(conn, /DELETE FROM ip_technician_slots WHERE tech_slot_id/)).toHaveLength(1);
  });

  test('an unbooked slot with a new duration is rebuilt', async () => {
    const { conn, res } = save([row()], day([2], { 2: 15 }));
    await res;
    expect(run(conn, /DELETE FROM ip_technician_slots WHERE tech_slot_id/)).toHaveLength(1);
    expect(run(conn, /INSERT INTO ip_technician_slots/)).toHaveLength(1);
  });

  test('an unchanged slot is left as it is', async () => {
    const { conn, res } = save([row()], day([2], { 2: 30 }));
    await res;
    expect(run(conn, /^DELETE/)).toHaveLength(0);
    expect(run(conn, /INSERT INTO/)).toHaveLength(0);
  });

  test('a new slot is added', async () => {
    const { conn, res } = save([], day([3], { 3: 30 }));
    await res;
    expect(run(conn, /INSERT INTO ip_technician_slots/)).toHaveLength(1);
    expect(run(conn, /INSERT INTO ip_available_slots/)).toHaveLength(2);
  });
});
