// Tests /api/prescriptions/* — controllers/prescriptionController.js
// Both the customer app and technician app call POST / (same endpoint), so
// this file exercises it under BOTH token shapes to prove the
// customer-vs-technician branch (isTechnicianUpload, keyed off req.user.userId
// only existing on a technician JWT) actually behaves differently for each.
jest.mock('../../config/db');
jest.mock('../../services/clientSync');
const db         = require('../../config/db');
const clientSync = require('../../services/clientSync');
const request    = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { customerToken, technicianToken, primeAuthCheck } = require('../helpers/jwt');

const prescriptionRoutes = require('../../routes/prescriptions');
const app = buildTestApp('/api/prescriptions', prescriptionRoutes);
const custToken = customerToken({ id: 501, userId: 42, clientId: 10 });
const techToken = technicianToken({ id: 17 });

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  clientSync.syncBookingToClient.mockReset().mockResolvedValue({ success: true });
});

describe('POST /api/prescriptions', () => {
  test('rejects an unauthenticated request', async () => {
    const res = await request(app).post('/api/prescriptions').send({});
    expect(res.status).toBe(401);
  });

  test('rejects a request missing imageUrls', async () => {
    primeAuthCheck(db, custToken);
    const res = await request(app).post('/api/prescriptions')
      .set('Authorization', `Bearer ${custToken}`)
      .send({ bookingId: 900, patientId: 501 });
    expect(res.status).toBe(400);
  });

  // TC-RX-01 — a customer uploading their own prescription syncs
  // immediately to Jayamala (customer bookings never pass through the
  // technician OTP flow, so this is their only path to the client server).
  test('a customer upload saves the document and syncs immediately', async () => {
    primeAuthCheck(db, custToken);
    db.execute.mockResolvedValueOnce([{ insertId: 301 }]);

    const res = await request(app).post('/api/prescriptions')
      .set('Authorization', `Bearer ${custToken}`)
      .send({ bookingId: 900, patientId: 501, imageUrls: ['https://cdn.example.com/rx1.jpg'] });

    expect(res.status).toBe(201);
    expect(res.body.docIds).toEqual([301]);
    expect(clientSync.syncBookingToClient).toHaveBeenCalledWith(
      900, expect.objectContaining({ action: 'prescription_uploaded', type: 'patient_user' })
    );
  });

  // TC-RX-02 — a technician upload (on-site, during a visit) saves the
  // document but deliberately does NOT sync immediately — it's picked up
  // later by the consolidated visit_completed request instead.
  test('a technician upload saves the document without an immediate sync', async () => {
    primeAuthCheck(db, techToken);
    db.execute.mockResolvedValueOnce([{ insertId: 302 }]);

    const res = await request(app).post('/api/prescriptions')
      .set('Authorization', `Bearer ${techToken}`)
      .send({ bookingId: 900, patientId: 501, imageUrls: ['https://cdn.example.com/rx2.jpg'] });

    expect(res.status).toBe(201);
    expect(res.body.docIds).toEqual([302]);
    expect(clientSync.syncBookingToClient).not.toHaveBeenCalled();
  });

  // Multiple images in one call insert one document row each, in order.
  test('multiple images in one call each get their own doc_id', async () => {
    primeAuthCheck(db, custToken);
    db.execute
      .mockResolvedValueOnce([{ insertId: 401 }])
      .mockResolvedValueOnce([{ insertId: 402 }]);

    const res = await request(app).post('/api/prescriptions')
      .set('Authorization', `Bearer ${custToken}`)
      .send({
        bookingId: 900, patientId: 501,
        imageUrls: ['https://cdn.example.com/rx_a.jpg', 'https://cdn.example.com/rx_b.jpg'],
      });

    expect(res.status).toBe(201);
    expect(res.body.docIds).toEqual([401, 402]);
  });
});

describe('GET /api/prescriptions/:bookingId', () => {
  // TC-RX-03 — a family visit's prescriptions are pulled in from every
  // sibling booking sharing the same visit_group_id, not just this booking_id.
  test('returns prescription documents across the whole visit group', async () => {
    primeAuthCheck(db, custToken);
    db.execute.mockResolvedValueOnce([[
      { doc_id: 1, file_path: 'rx1.jpg', file_description: 'prescription', booking_id: 900, patient_id: 501 },
      { doc_id: 2, file_path: 'rx2.jpg', file_description: 'prescription', booking_id: 901, patient_id: 502 },
    ]]);

    const res = await request(app).get('/api/prescriptions/900')
      .set('Authorization', `Bearer ${custToken}`);

    expect(res.status).toBe(200);
    expect(res.body.docs).toHaveLength(2);
    expect(res.body.docs.map(d => d.booking_id)).toEqual([900, 901]);
  });
});

describe('PATCH /api/prescriptions/:docId/verify', () => {
  test('a document that does not exist is rejected', async () => {
    primeAuthCheck(db, custToken);
    db.execute.mockResolvedValueOnce([{ affectedRows: 0 }]);
    const res = await request(app).patch('/api/prescriptions/999/verify')
      .set('Authorization', `Bearer ${custToken}`);
    expect(res.status).toBe(404);
  });

  test('marks a document verified', async () => {
    primeAuthCheck(db, custToken);
    db.execute.mockResolvedValueOnce([{ affectedRows: 1 }]);
    const res = await request(app).patch('/api/prescriptions/301/verify')
      .set('Authorization', `Bearer ${custToken}`);
    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
  });
});
