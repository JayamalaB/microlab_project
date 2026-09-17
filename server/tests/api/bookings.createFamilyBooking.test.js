// Tests POST /api/bookings/family — bookingController.js: createFamilyBooking
//
// Same conn.execute/transaction shape as createBooking, but looping once per
// family member, all inside ONE transaction and ONE visit_group_id — this is
// what lets a technician later see and act on the whole family visit as a
// unit (ip_bookings.visit_group_id ties the sibling bookings together).
//
// This controller also reads two feature-flag settings (config/settings.js)
// — family_booking_enabled and family_booking_max_members. That module reads
// from an in-memory cache that only ever gets populated by settings.init()
// at server startup (never called in these tests), so in a real request
// against this test app the cache is empty and both settings silently fall
// back to their hard-coded defaults (enabled=true, max=4) — no mocking
// needed for the success-path tests. The "feature disabled" test below
// mocks config/settings directly to exercise that one path explicitly.
//
// Covers: TC-FAMBOOK-01/02 (validation — too few / too many members, before
// any DB call), TC-FAMBOOK-03 (feature flag off), TC-FAMBOOK-04 (pay-later
// family booking creates N sibling bookings sharing one visit_group_id),
// TC-FAMBOOK-05 (a paid family booking syncs each member to Jayamala).
jest.mock('../../config/db');
jest.mock('../../config/settings');
jest.mock('../../services/clientSync');
const db          = require('../../config/db');
const settings    = require('../../config/settings');
const clientSync  = require('../../services/clientSync');
const request     = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { customerToken, primeAuthCheck } = require('../helpers/jwt');
const { createMockConnection } = require('../helpers/mockConnection');

const bookingRoutes = require('../../routes/bookings');
const app = buildTestApp('/api/bookings', bookingRoutes);
const token = customerToken({ id: 501, userId: 42, clientId: 10 });

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  db.getConnection.mockReset();
  clientSync.syncBookingToClient.mockReset().mockResolvedValue({ success: true });
  // Mirror the real empty-cache defaults so success-path tests don't need
  // to think about the feature flags at all.
  settings.getBool.mockReset().mockReturnValue(true);
  settings.get.mockReset().mockReturnValue('4');
});

function member(patientId, price = 300) {
  return { patientId, totalAmount: price, items: [{ packageId: 7, finalPrice: price }] };
}

// Queues the 8 conn.execute responses one member with 1 item consumes:
// patient_id_ref, INSERT ip_bookings, UPDATE booking_ref (derived from the
// row's own insertId — see bookingController.js's LT-002 fix comment),
// INSERT ip_patient_bookings, item-lookup, INSERT ip_booking_items,
// INSERT ip_payment_transactions, doc-required lookup — in that exact real
// order.
function queueMemberCalls(conn, bookingId) {
  conn.execute
    .mockResolvedValueOnce([[{ patient_id_ref: null }]])
    .mockResolvedValueOnce([{ insertId: bookingId }])
    .mockResolvedValueOnce([{}]) // UPDATE booking_ref
    .mockResolvedValueOnce([{}])
    .mockResolvedValueOnce([[{ product_id: 7, product_name: 'CBC' }]])
    .mockResolvedValueOnce([{}])
    .mockResolvedValueOnce([{}])
    .mockResolvedValueOnce([[]]); // no doc-required item
}

describe('POST /api/bookings/family', () => {
  test('rejects an unauthenticated request', async () => {
    const res = await request(app).post('/api/bookings/family').send({ members: [] });
    expect(res.status).toBe(401);
  });

  // TC-FAMBOOK-01 — fewer than 2 members isn't a "family" booking.
  test('rejects fewer than 2 members before touching the database', async () => {
    primeAuthCheck(db, token);
    const res = await request(app).post('/api/bookings/family')
      .set('Authorization', `Bearer ${token}`)
      .send({ members: [member(501)] });

    expect(res.status).toBe(400);
    expect(res.body.message).toMatch(/at least 2 members/i);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  // TC-FAMBOOK-02 — more than the configured max (default 4) is rejected.
  test('rejects more members than the configured maximum', async () => {
    primeAuthCheck(db, token);
    const res = await request(app).post('/api/bookings/family')
      .set('Authorization', `Bearer ${token}`)
      .send({ members: [member(1), member(2), member(3), member(4), member(5)] });

    expect(res.status).toBe(400);
    expect(res.body.message).toMatch(/maximum 4 members/i);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  // TC-FAMBOOK-03 — the feature flag itself, off.
  test('rejects family booking when the feature flag is disabled', async () => {
    settings.getBool.mockReturnValue(false);
    primeAuthCheck(db, token);
    const res = await request(app).post('/api/bookings/family')
      .set('Authorization', `Bearer ${token}`)
      .send({ members: [member(501), member(502)] });

    expect(res.status).toBe(403);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  // TC-FAMBOOK-04 — the core success path: 2 members, pay-later. Both
  // bookings must share the same visit_group_id, and — unlike single
  // createBooking, which always syncs regardless of payment status — an
  // unpaid family booking is NOT synced to Jayamala immediately (the code
  // only loops and calls syncBookingToClient `if (isPaid)`).
  test('a pay-later family booking creates one sibling booking per member', async () => {
    primeAuthCheck(db, token);
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    queueMemberCalls(conn, 900);
    queueMemberCalls(conn, 901);

    const res = await request(app).post('/api/bookings/family')
      .set('Authorization', `Bearer ${token}`)
      .send({ members: [member(501), member(502)], paymentType: 'pay_later' });

    expect(res.status).toBe(201);
    expect(res.body.success).toBe(true);
    expect(res.body.bookings).toHaveLength(2);
    expect(res.body.bookings.map(b => b.bookingId)).toEqual([900, 901]);
    expect(conn.commit).toHaveBeenCalled();
    expect(conn.execute).toHaveBeenCalledTimes(16); // 8 per member × 2 members
    // visit_group_id is now derived from the FIRST member's own real
    // booking_id (guaranteed unique by the database) instead of Date.now()
    // — see bookingController.js's own comment on why (LT-011 fix). The
    // first member's row gets it via the follow-up UPDATE (its own id
    // wasn't known yet at INSERT time), so that INSERT's own visit_group_id
    // param is still null; the second member already has the derived value
    // and carries it straight in its own INSERT.
    expect(res.body.visitGroupId).toBe('VG-000900');
    // (INSERT param order: ..., patient_id, patient_id_ref, payment_status,
    // visit_group_id, created_by — so visit_group_id is 2nd-from-last.)
    const firstMemberInsertVisitGroupId = conn.execute.mock.calls[1][1].at(-2);
    expect(firstMemberInsertVisitGroupId).toBeNull();
    const firstMemberUpdateParams = conn.execute.mock.calls[2][1];
    expect(firstMemberUpdateParams).toEqual(['BK-000900', 'VG-000900', 900]);
    const secondMemberInsertVisitGroupId = conn.execute.mock.calls[9][1].at(-2);
    expect(secondMemberInsertVisitGroupId).toBe('VG-000900');
    // Unpaid — no immediate Jayamala sync for either sibling.
    expect(clientSync.syncBookingToClient).not.toHaveBeenCalled();
  });

  // TC-FAMBOOK-05 — a fully paid family booking auto-confirms AND syncs
  // every sibling booking to Jayamala individually (one call per member).
  test('a fully paid family booking confirms and syncs every member', async () => {
    primeAuthCheck(db, token);
    const conn = createMockConnection();
    db.getConnection.mockResolvedValue(conn);
    // 9 calls per member now: the 8 from queueMemberCalls (which already
    // includes the UPDATE booking_ref step) plus the isPaid-only "UPDATE
    // status='confirmed'", inserted after the payment transaction and
    // before the doc-lookup.
    conn.execute
      .mockResolvedValueOnce([[{ patient_id_ref: null }]])
      .mockResolvedValueOnce([{ insertId: 900 }])
      .mockResolvedValueOnce([{}])   // UPDATE booking_ref
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([[{ product_id: 7, product_name: 'CBC' }]])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}])   // INSERT ip_payment_transactions
      .mockResolvedValueOnce([{}])   // UPDATE status='confirmed'
      .mockResolvedValueOnce([[]])   // doc-required lookup
      .mockResolvedValueOnce([[{ patient_id_ref: null }]])
      .mockResolvedValueOnce([{ insertId: 901 }])
      .mockResolvedValueOnce([{}])   // UPDATE booking_ref
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([[{ product_id: 7, product_name: 'CBC' }]])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([{}])
      .mockResolvedValueOnce([[]]);

    const res = await request(app).post('/api/bookings/family')
      .set('Authorization', `Bearer ${token}`)
      .send({
        members: [member(501), member(502)],
        paymentType: 'full', razorpayPaymentId: 'pay_fam123',
      });

    expect(res.status).toBe(201);
    expect(conn.execute).toHaveBeenCalledTimes(18); // 9 per member × 2 members
    expect(clientSync.syncBookingToClient).toHaveBeenCalledTimes(2);
    expect(clientSync.syncBookingToClient).toHaveBeenCalledWith(900, expect.objectContaining({ action: 'new_booking' }));
    expect(clientSync.syncBookingToClient).toHaveBeenCalledWith(901, expect.objectContaining({ action: 'new_booking' }));
  });
});
