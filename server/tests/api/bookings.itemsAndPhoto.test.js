// Tests technician-initiated package/test addition & removal, and
// collection-photo upload — all live in bookingController.js/routes/bookings.js
// even though they're technician actions, because the same booking-items
// table is shared with the customer app's own package selection screen.
// The `auth` middleware doesn't check role, so a technician's token works
// here exactly like a customer's would — this file uses a technician token
// since that's the real-world caller for these three actions during a visit.
//
// POST   /api/bookings/:bookingId/items              — addItem
// DELETE /api/bookings/:bookingId/items/:bookingItemId — removeItem
// POST   /api/bookings/:bookingId/collection-photo    — saveCollectionProofPhoto
jest.mock('../../config/db');
jest.mock('../../services/clientSync');
const db         = require('../../config/db');
const clientSync = require('../../services/clientSync');
const request    = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { technicianToken, primeAuthCheck } = require('../helpers/jwt');

const bookingRoutes = require('../../routes/bookings');
const app = buildTestApp('/api/bookings', bookingRoutes);
const token = technicianToken({ id: 17 });

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  clientSync.syncBookingToClient.mockReset().mockResolvedValue({ success: true });
});

describe('POST /api/bookings/:bookingId/items (addItem)', () => {
  test('rejects a request missing productId', async () => {
    primeAuthCheck(db, token);
    const res = await request(app).post('/api/bookings/900/items')
      .set('Authorization', `Bearer ${token}`).send({});
    expect(res.status).toBe(400);
  });

  test('an inactive/unknown product is rejected', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[]]); // product_active=1 filter excludes it
    const res = await request(app).post('/api/bookings/900/items')
      .set('Authorization', `Bearer ${token}`).send({ productId: 7 });
    expect(res.status).toBe(404);
  });

  // TC-ITEM-01 — adding a package both inserts the line item AND rolls
  // total_amount/amount_due upward on the parent booking (the "keep total
  // in sync" fix called out in the code's own comment) — no Jayamala sync
  // fires here (that's deferred to the consolidated visit_completed request).
  test('adding a package inserts the item and increases the booking total', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[{ product_id: 9, product_name: 'Lipid Profile', product_category: 'Pathology', product_price: '300.00', document_required: 0 }]])
      .mockResolvedValueOnce([[{ patient_id: 501 }]])   // booking lookup
      .mockResolvedValueOnce([{ insertId: 5 }])          // INSERT ip_booking_items
      .mockResolvedValueOnce([{}]);                      // UPDATE ip_bookings total_amount/amount_due

    const res = await request(app).post('/api/bookings/900/items')
      .set('Authorization', `Bearer ${token}`).send({ productId: 9 });

    expect(res.status).toBe(201);
    expect(res.body.item).toEqual({ bookingItemId: 5, productId: 9, name: 'Lipid Profile', category: 'Pathology', price: 300 });
    // calls[0] is the auth middleware's own check, so the UPDATE is calls[4].
    expect(db.execute.mock.calls[4][1]).toEqual([300, 300, '900']);
    expect(clientSync.syncBookingToClient).not.toHaveBeenCalled();
  });
});

describe('DELETE /api/bookings/:bookingId/items/:bookingItemId (removeItem)', () => {
  test('an item that does not belong to this booking is rejected', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[]]); // item lookup finds nothing
    const res = await request(app).delete('/api/bookings/900/items/5')
      .set('Authorization', `Bearer ${token}`);
    expect(res.status).toBe(404);
  });

  // TC-ITEM-02 — removing a package rolls the total back down (GREATEST(0, …)
  // floor prevents it from going negative) AND, unlike addItem, DOES still
  // fire an immediate syncBookingToClient('package_removed') — an asymmetry
  // between add and remove worth flagging in the test report, not a bug this
  // task is allowed to fix.
  test('removing a package rolls back the total and syncs the removal immediately', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[{ product_id: 9, name: 'Lipid Profile', price: 300 }]]) // item lookup
      .mockResolvedValueOnce([{ affectedRows: 1 }])   // DELETE
      .mockResolvedValueOnce([{}]);                   // UPDATE ip_bookings rollback

    const res = await request(app).delete('/api/bookings/900/items/5')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    // calls[0] is the auth check, so the rollback UPDATE is calls[3].
    expect(db.execute.mock.calls[3][1]).toEqual([300, 300, '900']);
    expect(clientSync.syncBookingToClient).toHaveBeenCalledWith(900, expect.objectContaining({
      action: 'package_removed',
      removedTest: { id: 9, name: 'Lipid Profile', price: 300 },
    }));
  });
});

describe('POST /api/bookings/:bookingId/collection-photo', () => {
  test('rejects a request missing imageUrl', async () => {
    primeAuthCheck(db, token);
    const res = await request(app).post('/api/bookings/900/collection-photo')
      .set('Authorization', `Bearer ${token}`).send({});
    expect(res.status).toBe(400);
  });

  test('a booking that does not exist (or is soft-deleted) is rejected', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[]]); // deleted_at IS NULL filter excludes it
    const res = await request(app).post('/api/bookings/900/collection-photo')
      .set('Authorization', `Bearer ${token}`).send({ imageUrl: 'https://cdn.example.com/900_proof.jpg' });
    expect(res.status).toBe(404);
  });

  // TC-PHOTO-01 — the photo is stored with file_description='collection_proof'
  // and doc_status='pending_review'; per the code comment, no immediate
  // Jayamala sync fires — the photo only reaches Jayamala later, read fresh
  // from the DB by the consolidated visit_completed request.
  test('uploads a collection proof photo and stores it against the booking', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[{ patient_id: 501 }]])
      .mockResolvedValueOnce([{ insertId: 12 }]);

    const res = await request(app).post('/api/bookings/900/collection-photo')
      .set('Authorization', `Bearer ${token}`)
      .send({ imageUrl: 'https://cdn.example.com/uploads/900_proof.jpg?sig=abc' });

    expect(res.status).toBe(201);
    expect(res.body.docId).toBe(12);
    // calls[0] is the auth check, so the INSERT is calls[2].
    // 'collection_proof' is a hardcoded literal in the SQL text itself, not
    // a bound parameter — it belongs in the query string assertion, not the
    // params array.
    const [insertSql, insertParams] = db.execute.mock.calls[2];
    expect(insertSql).toMatch(/'collection_proof'/);
    expect(insertParams).toContain('900_proof.jpg'); // query-string stripped from the derived filename
    expect(clientSync.syncBookingToClient).not.toHaveBeenCalled();
  });
});
