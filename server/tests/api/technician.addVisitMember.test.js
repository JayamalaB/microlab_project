// Tests POST /api/technicians/add-visit-member — technicianController.js: addVisitMember
// The "family member handling" flow: a technician on-site adds one or more
// extra people to the visit they're already at. Unlike createFamilyBooking
// (customer app, dispatched fresh), these new bookings are created already
// 'confirmed' and their ip_technician_collection row starts at 'arrived'
// (not 'assigned') — the technician is standing there, there's no dispatch
// step to go through.
jest.mock('../../config/db');
const db      = require('../../config/db');
const request = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { technicianToken, primeAuthCheck } = require('../helpers/jwt');
const { createMockConnection } = require('../helpers/mockConnection');

const technicianRoutes = require('../../routes/technicians');
const app = buildTestApp('/api/technicians', technicianRoutes);
const token = technicianToken({ id: 17 });

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  db.getConnection.mockReset();
});

function post(body) {
  primeAuthCheck(db, token);
  return request(app).post('/api/technicians/add-visit-member')
    .set('Authorization', `Bearer ${token}`).send(body);
}

describe('POST /api/technicians/add-visit-member', () => {
  test('rejects an unauthenticated request', async () => {
    const res = await request(app).post('/api/technicians/add-visit-member').send({});
    expect(res.status).toBe(401);
  });

  test('rejects a request missing parentBookingId', async () => {
    const res = await post({ members: [{ name: 'Asha', mobile: '9876500001' }] });
    expect(res.status).toBe(400);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('rejects a request with no members', async () => {
    const res = await post({ parentBookingId: 900, members: [] });
    expect(res.status).toBe(400);
  });

  test('rejects more than 4 members in one call', async () => {
    const members = Array.from({ length: 5 }, (_, i) => ({ name: `M${i}`, mobile: `98765000${i}0` }));
    const res = await post({ parentBookingId: 900, members });
    expect(res.status).toBe(400);
    expect(res.body.message).toMatch(/maximum 4/i);
  });

  test('rejects a member with neither patientId nor (name + mobile)', async () => {
    const res = await post({ parentBookingId: 900, members: [{ name: 'Asha' }] }); // mobile missing
    expect(res.status).toBe(400);
  });

  test('a parent booking not assigned to this technician is rejected and rolled back', async () => {
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    conn.execute.mockResolvedValueOnce([[]]); // parent lookup finds nothing

    const res = await post({ parentBookingId: 900, members: [{ name: 'Asha', mobile: '9876500001' }] });

    expect(res.status).toBe(404);
    expect(conn.rollback).toHaveBeenCalled();
    expect(conn.commit).not.toHaveBeenCalled();
  });

  // TC-FAM-01 — the core success path: a brand-new patient (not found by
  // mobile), one test item, parent booking has no visit_group_id yet (gets
  // backfilled). New booking starts 'confirmed' with collection_status
  // 'arrived' — direct assignment, not the dispatch-queue 'assigned' state.
  test('adds a brand-new family member with one test, backfilling visit_group_id', async () => {
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    conn.execute
      .mockResolvedValueOnce([[{                                    // 1. parent context
        client_id: 10, branch_id: 3, booking_date: '2026-09-01',
        collection_address: '12 MG Road', postal_code: '600001', city: 'Chennai',
        collection_latitude: 13.05, collection_longitude: 80.25,
        available_slot_id: null, visit_group_id: null, slot_id: null,
      }]])
      .mockResolvedValueOnce([[{ user_name: 'Tech Suresh' }]])       // 2. technician name
      .mockResolvedValueOnce([{}])                                   // 3. backfill technician on parent
      .mockResolvedValueOnce([{}])                                   // 4. backfill visit_group_id on parent
      // member loop:
      .mockResolvedValueOnce([[]])                                   // 5. existing-patient-by-mobile — none
      .mockResolvedValueOnce([{ insertId: 601 }])                    // 6. INSERT ip_patients
      .mockResolvedValueOnce([[{ patient_id_ref: null }]])           // 7. patient_id_ref lookup
      .mockResolvedValueOnce([[{ product_id: 7, product_name: 'CBC', product_price: '500.00', offer: 'no', discount_percent: 0 }]]) // 8. product lookup
      .mockResolvedValueOnce([{ insertId: 950 }])                    // 9. INSERT ip_bookings (new member booking)
      .mockResolvedValueOnce([{}])                                   // 10. INSERT ip_patient_bookings
      .mockResolvedValueOnce([{}])                                   // 11. INSERT ip_booking_items
      .mockResolvedValueOnce([{}])                                   // 12. INSERT ip_payment_transactions
      .mockResolvedValueOnce([{}])                                   // 13. INSERT ip_technician_collection
      .mockResolvedValueOnce([{}]);                                  // 14. UPDATE ip_patient_bookings collection_status='arrived'

    const res = await post({
      parentBookingId: 900,
      members: [{ name: 'Asha Kumar', mobile: '9876500001', relation: 'Daughter', tests: [{ productId: 7 }] }],
    });

    expect(res.status).toBe(201);
    expect(res.body.success).toBe(true);
    expect(res.body.totalMembers).toBe(1);
    expect(res.body.totalVisitAmount).toBe(500);
    expect(res.body.members[0]).toMatchObject({ newBookingId: 950, patientId: 601, totalAmount: 500 });
    // Legacy single-member compat fields must also be present.
    expect(res.body.newBookingId).toBe(950);

    expect(conn.commit).toHaveBeenCalled();
    expect(conn.rollback).not.toHaveBeenCalled();
    expect(conn.execute).toHaveBeenCalledTimes(14);

    // New booking is created already 'confirmed' (direct on-site add).
    expect(conn.execute.mock.calls[8][0]).toMatch(/'confirmed'/);
    // Its visit_group_id matches the one just backfilled onto the parent.
    const newBookingParams = conn.execute.mock.calls[8][1];
    expect(newBookingParams).toEqual(expect.arrayContaining([expect.stringMatching(/^VG\d+$/)]));
    // ip_technician_collection starts 'arrived', not 'assigned' — no
    // dispatch step for a technician-initiated on-site addition.
    expect(conn.execute.mock.calls[12][0]).toMatch(/'arrived'/);
  });

  // TC-FAM-02 — an existing patient found by mobile is updated in place
  // (not re-created), and a member with no tests contributes ₹0 to the total.
  test('reuses an existing patient found by mobile, with no tests selected', async () => {
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    conn.execute
      .mockResolvedValueOnce([[{
        client_id: 10, branch_id: 3, booking_date: '2026-09-01',
        collection_address: '12 MG Road', postal_code: '600001', city: 'Chennai',
        collection_latitude: 13.05, collection_longitude: 80.25,
        available_slot_id: null, visit_group_id: 'VG_EXISTING', slot_id: null, // already has a group — no backfill call
      }]])
      .mockResolvedValueOnce([[{ user_name: 'Tech Suresh' }]])
      .mockResolvedValueOnce([{}])                                   // backfill technician
      // no visit_group_id backfill call this time — parent already has one
      .mockResolvedValueOnce([[{ patient_id: 602 }]])                // existing-patient-by-mobile — found
      .mockResolvedValueOnce([{}])                                   // UPDATE ip_patients (refresh details)
      .mockResolvedValueOnce([[{ patient_id_ref: null }]])           // patient_id_ref lookup
      // no product lookups — tests: []
      .mockResolvedValueOnce([{ insertId: 951 }])                    // INSERT ip_bookings
      .mockResolvedValueOnce([{}])                                   // INSERT ip_patient_bookings
      // no booking_items insert — no resolved products
      .mockResolvedValueOnce([{}])                                   // INSERT ip_payment_transactions
      .mockResolvedValueOnce([{}])                                   // INSERT ip_technician_collection
      .mockResolvedValueOnce([{}]);                                  // UPDATE ip_patient_bookings collection_status='arrived'

    const res = await post({
      parentBookingId: 900,
      members: [{ name: 'Ravi Kumar', mobile: '9876500002', relation: 'Son' }],
    });

    expect(res.status).toBe(201);
    expect(res.body.totalVisitAmount).toBe(0);
    expect(res.body.members[0].patientId).toBe(602);
    expect(conn.execute).toHaveBeenCalledTimes(11);
    expect(conn.execute.mock.calls[3][0]).toMatch(/SELECT patient_id FROM ip_patients/);
    expect(conn.execute.mock.calls[4][0]).toMatch(/UPDATE ip_patients/);
  });
});
