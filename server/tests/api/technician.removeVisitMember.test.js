// Tests POST /api/technicians/remove-visit-member — technicianController.removeVisitMember
//
// A family member's booking is removed from the visit (marked cancelled and
// detached via visit_group_id = NULL) only while nothing is collected or paid
// for it, never for the main member, and only by the technician on the visit.
// The DB mock answers by SQL text, so the order of the controller's checks can
// change without breaking these tests.
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
      booking_id: MEMBER, booking_ref: '180591', reference_no: null, visit_group_id: 'VG1',
      status: 'confirmed', amount_paid: '0.00', service_charge_status: null,
      client_sync_status: null, patient_name: 'KEN',
    },
    onVisit: true,
    main: { booking_id: MAIN, booking_ref: '180590' },
    collection: { collection_status: 'arrived', collected_items: 0 },
    paid: '0.00',
    updateAffected: 1,
  };
}

beforeEach(() => {
  state = defaults();
  clientSync.syncBookingToClient.mockReset().mockResolvedValue(undefined);
  conn = createMockConnection();
  conn.execute.mockImplementation(async (sql) => {
    if (/UPDATE ip_bookings/.test(sql)) return [{ affectedRows: state.updateAffected }];
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
    if (/FROM ip_technicians t JOIN ip_users/.test(sql)) return [[{ user_name: 'Nirosh' }]];
    return [[], {}];
  });
});

function post(body) {
  primeAuthCheck(db, token);
  return request(app).post('/api/technicians/remove-visit-member')
    .set('Authorization', `Bearer ${token}`).send(body);
}

const bookingUpdate = () => conn.execute.mock.calls.find(c => /UPDATE ip_bookings/.test(c[0]));

describe('POST /api/technicians/remove-visit-member', () => {
  test('rejects an unauthenticated request', async () => {
    const res = await request(app).post('/api/technicians/remove-visit-member').send({ bookingId: MEMBER });
    expect(res.status).toBe(401);
  });

  test('bookingId is required', async () => {
    const res = await post({});
    expect(res.status).toBe(400);
  });

  test('removes the member: cancelled, detached from the visit, reason recorded', async () => {
    const res = await post({ bookingId: MEMBER, reason: '  Added by mistake  ' });
    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);

    const [sql, params] = bookingUpdate();
    expect(sql).toMatch(/status = 'cancelled'/);
    expect(sql).toMatch(/visit_group_id = NULL/);
    expect(sql).not.toMatch(/technician_cancel/); // that means "dropped the job"
    expect(params[0]).toBe('Removed from visit VG1 (main booking 180590) by technician Nirosh #17: Added by mistake');
    expect(params[1]).toBe(MEMBER);

    expect(conn.execute.mock.calls.some(c => /UPDATE ip_technician_collection SET collection_status = 'cancelled'/.test(c[0]))).toBe(true);
    expect(conn.commit).toHaveBeenCalled();
  });

  test('the reason is optional', async () => {
    const res = await post({ bookingId: MEMBER });
    expect(res.status).toBe(200);
    expect(bookingUpdate()[1][0]).toBe('Removed from visit VG1 (main booking 180590) by technician Nirosh #17');
  });

  test('a member ASMX never received is not cancelled there', async () => {
    await post({ bookingId: MEMBER });
    expect(clientSync.syncBookingToClient).not.toHaveBeenCalled();
  });

  test('a member already synced to ASMX is cancelled there too', async () => {
    state.member.reference_no = 'REF123';
    await post({ bookingId: MEMBER });
    expect(clientSync.syncBookingToClient).toHaveBeenCalledWith(
      MEMBER, expect.objectContaining({ type: 'technician', action: 'cancel' })
    );
  });

  test('the main member cannot be removed', async () => {
    state.main = { booking_id: MEMBER, booking_ref: '180591' };
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

  test('blocked once the member\'s collection is past sample collection', async () => {
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

  test('already removed → 400, nothing written', async () => {
    state.member.status = 'cancelled';
    const res = await post({ bookingId: MEMBER });
    expect(res.status).toBe(400);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('removed at the same moment by another request → 400 and rolled back', async () => {
    state.updateAffected = 0;
    const res = await post({ bookingId: MEMBER });
    expect(res.status).toBe(400);
    expect(conn.rollback).toHaveBeenCalled();
    expect(conn.commit).not.toHaveBeenCalled();
  });
});
