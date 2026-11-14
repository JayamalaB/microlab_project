// Tests POST /api/technicians/remove-visit-member — technicianController.removeVisitMember
//
// Only a family member the technician added during the visit
// (source_channel 'technician_app') can be removed, only while nothing is
// collected or paid for it, never the main member, and only by the technician
// on the visit. Removal deletes the member's booking and its child rows; the
// patient is kept. The DB mock answers by SQL text, so the order of the
// controller's checks can change without breaking these tests.
jest.mock('../../config/db');
jest.mock('../../services/clientSync');
const db         = require('../../config/db');
const clientSync = require('../../services/clientSync');
const request    = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { technicianToken, primeAuthCheck } = require('../helpers/jwt');
const { createMockConnection } = require('../helpers/mockConnection');

const technicianRoutes = require('../../routes/technicians');
const app   = buildTestApp('/api/technicians', technicianRoutes);
const token = technicianToken({ id: 17 });

const MEMBER = 901;   // the member being removed
const MAIN   = 900;   // the visit's main booking

let conn;
let state;

function defaults() {
  return {
    member: {
      booking_id: MEMBER, booking_ref: '180591', visit_group_id: 'VG1', status: 'confirmed',
      source_channel: 'technician_app', amount_paid: '0.00', service_charge_status: null,
      patient_name: 'KEN',
    },
    onVisit: true,
    main: { booking_id: MAIN },
    collection: { collection_status: 'arrived', collected_items: 0 },
    paid: '0.00',
    bookingDeleted: 1,
  };
}

beforeEach(() => {
  state = defaults();
  clientSync.syncBookingToClient.mockReset().mockResolvedValue(undefined);
  conn = createMockConnection();
  conn.execute.mockImplementation(async (sql) => {
    if (/DELETE FROM ip_bookings/.test(sql)) return [{ affectedRows: state.bookingDeleted }];
    return [{ affectedRows: 1 }];
  });
  db.getConnection.mockReset().mockResolvedValue(conn);
  db.query.mockReset().mockResolvedValue([[], {}]);
  db.execute.mockReset().mockImplementation(async (sql) => {
    if (/FROM ip_bookings b\s+LEFT JOIN ip_patients/.test(sql)) return [[state.member].filter(Boolean)];
    if (/FROM ip_technician_collection tc\s+JOIN ip_bookings/.test(sql)) return [state.onVisit ? [{ ok: 1 }] : []];
    if (/ORDER BY booking_id ASC LIMIT 1/.test(sql)) return [[state.main].filter(Boolean)];
    if (/collected_items/.test(sql)) return [[state.collection]];
    if (/FROM ip_payment_transactions/.test(sql)) return [[{ paid: state.paid }]];
    return [[], {}];
  });
});

function post(body) {
  primeAuthCheck(db, token);
  return request(app).post('/api/technicians/remove-visit-member')
    .set('Authorization', `Bearer ${token}`).send(body);
}

const deletes = () => conn.execute.mock.calls.filter(c => /^\s*DELETE/.test(c[0]));

describe('POST /api/technicians/remove-visit-member', () => {
  test('rejects an unauthenticated request', async () => {
    const res = await request(app).post('/api/technicians/remove-visit-member').send({ bookingId: MEMBER });
    expect(res.status).toBe(401);
  });

  test('bookingId is required', async () => {
    const res = await post({});
    expect(res.status).toBe(400);
  });

  test('deletes the member: booking and every child row, in one transaction', async () => {
    const res = await post({ bookingId: MEMBER });
    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);

    const tables = deletes().map(c => c[0].match(/DELETE FROM (\w+)/)[1]);
    expect(tables).toEqual([
      'ip_booking_items', 'ip_booking_additional_charges', 'ip_booking_documents',
      'ip_patient_bookings', 'ip_technician_collection', 'ip_payment_transactions',
      'ip_bookings',
    ]);
    // ip_bookings goes last, after its children.
    expect(tables[tables.length - 1]).toBe('ip_bookings');
    for (const c of deletes()) expect(c[1]).toEqual([MEMBER]);
    expect(conn.beginTransaction).toHaveBeenCalled();
    expect(conn.commit).toHaveBeenCalled();
  });

  test('the patient is kept and no cancelled record is written', async () => {
    await post({ bookingId: MEMBER });
    const sql = conn.execute.mock.calls.map(c => c[0]).join('\n');
    expect(sql).not.toMatch(/ip_patients/);
    expect(sql).not.toMatch(/UPDATE/);
    expect(sql).not.toMatch(/cancelled/);
  });

  test('the booking delete re-checks technician-added and unpaid', async () => {
    await post({ bookingId: MEMBER });
    const del = deletes().find(c => /DELETE FROM ip_bookings/.test(c[0]));
    expect(del[0]).toMatch(/source_channel = 'technician_app'/);
    expect(del[0]).toMatch(/COALESCE\(amount_paid, 0\) = 0/);
  });

  test('nothing is sent to ASMX (a technician-added member reaches it only at handover)', async () => {
    await post({ bookingId: MEMBER });
    expect(clientSync.syncBookingToClient).not.toHaveBeenCalled();
  });

  test('a member booked by the customer cannot be removed', async () => {
    state.member.source_channel = 'mobile_app';
    const res = await post({ bookingId: MEMBER });
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('BOOKED_BY_CUSTOMER');
    expect(res.body.message).toMatch(/KEN was booked by the customer/);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('a member with no source_channel (admin / older bookings) cannot be removed', async () => {
    state.member.source_channel = null;
    const res = await post({ bookingId: MEMBER });
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('BOOKED_BY_CUSTOMER');
  });

  test('the main member cannot be removed', async () => {
    state.main = { booking_id: MEMBER };
    const res = await post({ bookingId: MEMBER });
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('MAIN_MEMBER');
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('the member carrying the service charge cannot be removed', async () => {
    state.member.service_charge_status = 'calculated';
    const res = await post({ bookingId: MEMBER });
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('MAIN_MEMBER');
  });

  test('blocked once a sample is collected (item ticked)', async () => {
    state.collection = { collection_status: 'arrived', collected_items: 1 };
    const res = await post({ bookingId: MEMBER });
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('SAMPLES_COLLECTED');
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test("blocked once the member's collection is past sample collection", async () => {
    state.collection = { collection_status: 'otp_verified', collected_items: 0 };
    const res = await post({ bookingId: MEMBER });
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('SAMPLES_COLLECTED');
  });

  test('blocked when anything is paid for the member', async () => {
    state.paid = '50.00';
    const res = await post({ bookingId: MEMBER });
    expect(res.status).toBe(400);
    expect(res.body.code).toBe('MEMBER_PAID');
    expect(res.body.message).toMatch(/KEN/);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('a technician not on the visit gets 404', async () => {
    state.onVisit = false;
    const res = await post({ bookingId: MEMBER });
    expect(res.status).toBe(404);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('a booking that is not part of a visit gets 404', async () => {
    state.member.visit_group_id = null;
    const res = await post({ bookingId: MEMBER });
    expect(res.status).toBe(404);
  });

  test('already gone → 404', async () => {
    state.member = null;
    const res = await post({ bookingId: MEMBER });
    expect(res.status).toBe(404);
  });

  test('paid or changed in the meantime → booking delete matches nothing, all rolled back', async () => {
    state.bookingDeleted = 0;
    const res = await post({ bookingId: MEMBER });
    expect(res.status).toBe(400);
    expect(conn.rollback).toHaveBeenCalled();
    expect(conn.commit).not.toHaveBeenCalled();
  });
});
