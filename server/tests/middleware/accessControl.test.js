// Tests middleware/rolloutAuth.js and middleware/access.js through the real
// routes: who may reach a booking or a technician's data, and what happens to
// a call with no token before and after 'api_auth_required' is turned on.
jest.mock('../../config/db');
jest.mock('../../config/settings');
const db       = require('../../config/db');
const settings = require('../../config/settings');
const request  = require('supertest');
const { buildTestApp } = require('../helpers/testApp');
const { technicianToken, customerToken, primeAuthCheck } = require('../helpers/jwt');

const bookings    = buildTestApp('/api/bookings', require('../../routes/bookings'));
const technicians = buildTestApp('/api/technicians', require('../../routes/technicians'));

const techToken = technicianToken({ id: 17 });
const custToken = customerToken({ id: 7001, clientId: 2001 });

let required;
beforeAll(() => { jest.spyOn(console, 'warn').mockImplementation(() => {}); });
beforeEach(() => {
  required = false;
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  settings.getBool.mockReset().mockImplementation((key, def) => (key === 'api_auth_required' ? required : def));
  settings.get.mockReset().mockImplementation((_key, def) => def);
});

const asUser = (req, token) => req.set('Authorization', `Bearer ${token}`);

describe('a call with no token', () => {
  test('still works before the switch is on, so the current app keeps running', async () => {
    db.execute.mockResolvedValueOnce([[{ booking_id: 900 }]]);
    const res = await request(bookings).get('/api/bookings/900');
    expect(res.status).toBe(200);
  });

  test('is refused once the switch is on', async () => {
    required = true;
    const res = await request(bookings).get('/api/bookings/900');
    expect(res.status).toBe(401);
    expect(db.execute).not.toHaveBeenCalled();
  });

  test('cannot wipe a technician\'s slots once the switch is on', async () => {
    required = true;
    const res = await request(technicians).put('/api/technicians/17/slots').send({ slots: [] });
    expect(res.status).toBe(401);
    expect(db.execute).not.toHaveBeenCalled();
  });
});

describe('a booking', () => {
  test('a customer reaches a booking on their account', async () => {
    primeAuthCheck(db, custToken);
    db.execute
      .mockResolvedValueOnce([[{ 1: 1 }]])              // access check
      .mockResolvedValueOnce([[{ booking_id: 900 }]]);  // getBooking
    const res = await asUser(request(bookings).get('/api/bookings/900'), custToken);
    expect(res.status).toBe(200);
    expect(db.execute.mock.calls[1][1]).toEqual(['900', 2001, 7001]);
  });

  test('a customer gets 404 for someone else\'s booking', async () => {
    primeAuthCheck(db, custToken);
    db.execute.mockResolvedValueOnce([[]]);
    const res = await asUser(request(bookings).get('/api/bookings/900'), custToken);
    expect(res.status).toBe(404);
  });

  test('a technician not linked to the booking gets 404', async () => {
    primeAuthCheck(db, techToken);
    db.execute.mockResolvedValueOnce([[]]);
    const res = await asUser(request(bookings).get('/api/bookings/900/items'), techToken);
    expect(res.status).toBe(404);
    expect(db.execute.mock.calls[1][1]).toEqual(['900', 17, 17, 17]);
  });

  test('a stale session token is refused, even before the switch is on', async () => {
    db.execute.mockResolvedValueOnce([[{ user_auth_token: 'a-newer-token' }]]);
    const res = await asUser(request(bookings).get('/api/bookings/900'), custToken);
    expect(res.status).toBe(401);
  });
});

describe('a patient\'s bookings', () => {
  test('a customer cannot read a patient on another account', async () => {
    primeAuthCheck(db, custToken);
    db.execute.mockResolvedValueOnce([[]]);
    const res = await asUser(request(bookings).get('/api/bookings/patient/999'), custToken);
    expect(res.status).toBe(404);
  });

  test('a technician cannot use this route', async () => {
    primeAuthCheck(db, techToken);
    const res = await asUser(request(bookings).get('/api/bookings/patient/999'), techToken);
    expect(res.status).toBe(403);
  });
});

describe('technician routes', () => {
  test('a customer token is refused, even when its id equals a technician id', async () => {
    const lookalike = customerToken({ id: 17 });
    primeAuthCheck(db, lookalike);
    const res = await asUser(request(technicians).post('/api/technicians/collect-payment'), lookalike)
      .send({ bookingId: 900, amount: 500, paymentMethod: 'CASH' });
    expect(res.status).toBe(403);
  });

  test('a technician cannot change another technician\'s slots', async () => {
    primeAuthCheck(db, techToken);
    const res = await asUser(request(technicians).put('/api/technicians/18/slots'), techToken)
      .send({ slots: [] });
    expect(res.status).toBe(403);
  });

  test('a customer cannot log a technician out', async () => {
    primeAuthCheck(db, custToken);
    const res = await asUser(request(technicians).post('/api/technicians/17/logout'), custToken);
    expect(res.status).toBe(403);
  });

  test('a customer cannot read live technician locations', async () => {
    primeAuthCheck(db, custToken);
    const res = await asUser(request(technicians).get('/api/technicians/live'), custToken);
    expect(res.status).toBe(403);
  });
});
