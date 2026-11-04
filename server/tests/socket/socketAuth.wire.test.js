// socket/socketAuth.js wired the way server.js wires it, over a real Socket.IO
// connection: the token the app sends reaches the check, a refused connection
// really is refused, and a dropped event never reaches its handler.
jest.mock('../../config/db');
jest.mock('../../config/settings');
const http = require('http');
const { Server } = require('socket.io');
const { io: connectClient } = require('socket.io-client');
const db       = require('../../config/db');
const settings = require('../../config/settings');
const { technicianToken } = require('../helpers/jwt');
const { socketAuth, guardEvents } = require('../../socket/socketAuth');

const token = technicianToken({ id: 17, userId: 501 });

let required, server, port, received, clients;

beforeAll((done) => {
  jest.spyOn(console, 'warn').mockImplementation(() => {});
  const httpServer = http.createServer();
  server = new Server(httpServer);
  server.use(socketAuth);
  server.on('connection', (socket) => {
    guardEvents(socket);
    socket.on('booking_accepted', (data) => received.push(data));
  });
  httpServer.listen(0, () => { port = httpServer.address().port; done(); });
});
afterAll((done) => { server.close(done); });

beforeEach(() => {
  required = false;
  received = [];
  clients  = [];
  settings.getBool.mockReset().mockImplementation(() => required);
  db.execute.mockReset().mockResolvedValue([[{ user_auth_token: token }]]);
});
afterEach(() => clients.forEach(c => c.close()));

// Resolves 'connected', or the refusal message.
function open(auth) {
  const client = connectClient(`http://localhost:${port}`, { auth, transports: ['websocket'], reconnection: false });
  clients.push(client);
  return new Promise((resolve) => {
    client.on('connect', () => resolve({ client, result: 'connected' }));
    client.on('connect_error', (err) => resolve({ client, result: err.message }));
  });
}
const settle = () => new Promise(resolve => setTimeout(resolve, 50));

test('an app with a valid token connects, and its own accept goes through', async () => {
  required = true;
  const { client, result } = await open({ token });
  expect(result).toBe('connected');

  client.emit('booking_accepted', { bookingId: 900, technicianId: 17 });
  await settle();
  expect(received).toEqual([{ bookingId: 900, technicianId: 17 }]);
});

test('accepting as another technician never reaches the handler', async () => {
  const { client } = await open({ token });
  client.emit('booking_accepted', { bookingId: 900, technicianId: 18 });
  await settle();
  expect(received).toEqual([]);
});

test('an old app with no token still works before the switch is on', async () => {
  const { client, result } = await open({});
  expect(result).toBe('connected');

  client.emit('booking_accepted', { bookingId: 900, technicianId: 17 });
  await settle();
  expect(received).toHaveLength(1);
});

test('no token is refused at connection once the switch is on', async () => {
  required = true;
  const { result } = await open({});
  expect(result).toBe('unauthorized');
});
