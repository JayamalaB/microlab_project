// Tests GET /api/bookings/fare-quote — server/controllers/bookingController.js:
// getHomeCollectionFareQuote. This is the pre-confirm fare display
// checkout_screen.dart calls once branchId + pickup coordinates are known —
// it must use the exact same server/services/fareCalculator.js logic
// createBooking itself uses (see that file's own comment on why the two
// aren't allowed to silently disagree).
jest.mock('../../config/db');
const db      = require('../../config/db');
const request = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { customerToken, primeAuthCheck } = require('../helpers/jwt');

const bookingRoutes = require('../../routes/bookings');
const app = buildTestApp('/api/bookings', bookingRoutes);
const token = customerToken({ id: 501, userId: 42, clientId: 10 });

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
});

const activeRateRow = {
  rate_id: 3, rate_per_km: '15.00', base_fare: '49.00',
  included_distance_km: '3.00', max_service_distance_km: null,
};
const branchCoordsRow = { latitude: '13.0827', longitude: '80.2707' };

describe('GET /api/bookings/fare-quote', () => {
  test('rejects an unauthenticated request', async () => {
    const res = await request(app).get('/api/bookings/fare-quote?branchId=3&lat=13.1&lng=80.3');
    expect(res.status).toBe(401);
  });

  test('returns a priced fare quote for a valid branch + pickup location', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[branchCoordsRow]])
      .mockResolvedValueOnce([[activeRateRow]]);

    const res = await request(app)
      .get('/api/bookings/fare-quote?branchId=3&lat=13.155&lng=80.2707')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.fare.rateId).toBe(3);
    expect(res.body.fare.baseFare).toBe(49);
    expect(res.body.fare.finalFare).toBeGreaterThan(0);
  });

  test('missing branchId is rejected before any fare-related DB call', async () => {
    primeAuthCheck(db, token);
    const res = await request(app)
      .get('/api/bookings/fare-quote?lat=13.1&lng=80.3')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(422);
    // Exactly 1 — the auth middleware's own session check (primeAuthCheck) —
    // and nothing from fareCalculator, since the 422 short-circuits first.
    expect(db.execute).toHaveBeenCalledTimes(1);
  });

  test('missing pickup coordinates surface the same MISSING_COORDINATES error createBooking would give', async () => {
    primeAuthCheck(db, token);
    const res = await request(app)
      .get('/api/bookings/fare-quote?branchId=3')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(422);
    expect(res.body.code).toBe('MISSING_COORDINATES');
  });

  test('a branch missing coordinates on file returns 422, not a silent fallback', async () => {
    primeAuthCheck(db, token);
    db.execute.mockResolvedValueOnce([[]]); // branch lookup finds nothing

    const res = await request(app)
      .get('/api/bookings/fare-quote?branchId=3&lat=13.1&lng=80.3')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(422);
    expect(res.body.code).toBe('BRANCH_LOCATION_UNAVAILABLE');
  });

  test('no active rate configuration returns 503', async () => {
    primeAuthCheck(db, token);
    db.execute
      .mockResolvedValueOnce([[branchCoordsRow]])
      .mockResolvedValueOnce([[]]);

    const res = await request(app)
      .get('/api/bookings/fare-quote?branchId=3&lat=13.1&lng=80.3')
      .set('Authorization', `Bearer ${token}`);

    expect(res.status).toBe(503);
    expect(res.body.code).toBe('RATE_NOT_FOUND');
  });
});
