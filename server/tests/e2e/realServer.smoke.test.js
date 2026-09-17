// Smoke test for tests/helpers/realServer.js — confirms the real Express +
// Socket.IO server actually boots, serves real HTTP over the real network
// (not Supertest's in-memory request()), and accepts a real WebSocket
// connection on the same port, before any IT-* scenario is built on top of it.
jest.mock('../../config/db');
jest.mock('../../config/firebase', () => ({ messaging: null }));
jest.mock('../../utils/sms'); // MANDATORY whenever this real server can reach send-otp/booking-otp — see realServer.js header
const db  = require('../../config/db');
const sms = require('../../utils/sms');
const { startRealServer } = require('../helpers/realServer');
const { io: ioClient } = require('socket.io-client');

let server;
beforeAll(async () => { server = await startRealServer(); });
afterAll(async () => { await server.close(); });

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
  sms.sendLoginOtp.mockClear();
});

test('the real server answers a genuine HTTP request over the network', async () => {
  const res = await fetch(`${server.url}/health`);
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ status: 'ok' });
});

test('a real REST call reaches the real authController over the wire', async () => {
  db.query.mockResolvedValueOnce([[]]).mockResolvedValueOnce([{ insertId: 1 }])
    .mockResolvedValueOnce([{ insertId: 1 }]).mockResolvedValueOnce([{}]);
  const res = await fetch(`${server.url}/api/auth/send-otp`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ mobile: '9876543210', role: 'customer' }),
  });
  expect(res.status).toBe(200);
  const body = await res.json();
  expect(body.success).toBe(true);
  // Proves the mock — not a real gateway — actually handled this request.
  expect(sms.sendLoginOtp).toHaveBeenCalledWith('9876543210', expect.any(String));
});

test('a real Socket.IO client can connect on the same real server', async () => {
  const socket = ioClient(server.url, { transports: ['websocket'], forceNew: true });
  await new Promise((resolve, reject) => {
    socket.once('connect', resolve);
    socket.once('connect_error', reject);
  });
  expect(socket.connected).toBe(true);
  socket.disconnect();
});
