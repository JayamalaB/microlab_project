// Tests socket/socketAuth.js — the connection login check and the per-event
// rules, before and after 'api_auth_required' is turned on.
jest.mock('../../config/db');
jest.mock('../../config/settings');
const db       = require('../../config/db');
const settings = require('../../config/settings');
const { technicianToken, customerToken } = require('../helpers/jwt');
const { socketAuth, guardEvents } = require('../../socket/socketAuth');

const techToken = technicianToken({ id: 17, userId: 501 });
const custToken = customerToken({ id: 7001, userId: 4001, clientId: 2001 });

let required;
beforeAll(() => {
  jest.spyOn(console, 'warn').mockImplementation(() => {});
});
beforeEach(() => {
  required = false;
  db.execute.mockReset().mockResolvedValue([[]]);
  settings.getBool.mockReset().mockImplementation(() => required);
});

const fakeSocket = (token) => ({ handshake: { auth: { token }, address: '1.2.3.4' }, data: {} });

async function connect(token, currentToken = token) {
  const socket = fakeSocket(token);
  db.execute.mockResolvedValueOnce([[{ user_auth_token: currentToken }]]);
  const next = jest.fn();
  await socketAuth(socket, next);
  return { socket, next };
}

// Runs one event through the guard. True when it reached the handlers.
async function allowed(user, event, data) {
  let middleware;
  guardEvents({ data: { user }, use: (fn) => { middleware = fn; } });
  const next = jest.fn();
  await middleware([event, data], next);
  return next.mock.calls.length === 1;
}

const decode = (token) => JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString());
const tech = decode(techToken);
const cust = decode(custToken);

describe('connecting', () => {
  test('a valid token identifies the user', async () => {
    const { socket, next } = await connect(techToken);
    expect(next).toHaveBeenCalledWith();
    expect(socket.data.user.id).toBe(17);
  });

  test('no token connects before the switch is on, so the current app keeps running', async () => {
    const socket = fakeSocket(undefined);
    const next = jest.fn();
    await socketAuth(socket, next);
    expect(next).toHaveBeenCalledWith();
    expect(socket.data.user).toBeUndefined();
  });

  test('no token is refused once the switch is on', async () => {
    required = true;
    const next = jest.fn();
    await socketAuth(fakeSocket(undefined), next);
    expect(next.mock.calls[0][0]).toBeInstanceOf(Error);
  });

  test('a token replaced by a newer login is refused once the switch is on', async () => {
    required = true;
    const { next } = await connect(techToken, 'a-newer-token');
    expect(next.mock.calls[0][0]).toBeInstanceOf(Error);
  });

  test('a forged token is refused once the switch is on', async () => {
    required = true;
    const next = jest.fn();
    await socketAuth(fakeSocket('not.a.token'), next);
    expect(next.mock.calls[0][0]).toBeInstanceOf(Error);
  });
});

describe('events from a socket with no login', () => {
  test('pass before the switch is on', async () => {
    expect(await allowed(undefined, 'booking_accepted', { bookingId: 900 })).toBe(true);
  });

  test('are dropped once the switch is on', async () => {
    required = true;
    expect(await allowed(undefined, 'booking_accepted', { bookingId: 900 })).toBe(false);
  });
});

describe('a technician', () => {
  test('can act as themselves', async () => {
    expect(await allowed(tech, 'booking_accepted', { bookingId: 900, technicianId: 17 })).toBe(true);
    expect(await allowed(tech, 'technician_online', { technicianId: '17' })).toBe(true);
  });

  test('cannot act as another technician', async () => {
    expect(await allowed(tech, 'booking_accepted', { bookingId: 900, technicianId: 18 })).toBe(false);
    expect(await allowed(tech, 'technician_offline', { technicianId: 18 })).toBe(false);
  });
});

describe('a customer', () => {
  test.each([['booking_accepted'], ['booking_rejected'], ['sample_collected'], ['handed_to_lab'], ['technician_offline']])(
    'cannot send %s', async (event) => {
      expect(await allowed(cust, event, { bookingId: 900, technicianId: 17 })).toBe(false);
    });

  test('can request dispatch for their own booking', async () => {
    db.execute.mockResolvedValueOnce([[{ 1: 1 }]]);
    expect(await allowed(cust, 'booking_request', { bookingId: 900 })).toBe(true);
    expect(db.execute.mock.calls[0][1]).toEqual([900, 2001]);
  });

  test('cannot request dispatch or cancel a search on someone else\'s booking', async () => {
    expect(await allowed(cust, 'booking_request', { bookingId: 900 })).toBe(false);
    expect(await allowed(cust, 'patient_cancel_search', { bookingId: 900 })).toBe(false);
  });

  test('can register their own user id, not another', async () => {
    expect(await allowed(cust, 'register_user_socket', { userId: 4001 })).toBe(true);
    expect(await allowed(cust, 'register_user_socket', { userId: 4002 })).toBe(false);
  });

  test('other events are unaffected', async () => {
    expect(await allowed(cust, 'join_tracking', { trackingId: '900' })).toBe(true);
  });
});

test('a failed booking lookup drops the event instead of crashing', async () => {
  jest.spyOn(console, 'error').mockImplementation(() => {});
  db.execute.mockRejectedValueOnce(new Error('db down'));
  expect(await allowed(cust, 'booking_request', { bookingId: 900 })).toBe(false);
});
