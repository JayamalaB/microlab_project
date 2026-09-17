// Standalone (non-Jest) real backend, for Flutter's web integration_test
// suite to point at. Run directly with `node`:
//
//   node tests/e2e-web/bootstrapTestServer.js [port]
//
// Wires up the exact same real Express + Socket.IO server as
// tests/helpers/realServer.js (see that file's header for the full
// rationale — every route/controller/socket handler here is the real,
// unmodified production code), but as a plain long-running Node process
// instead of something started from inside a Jest test, since Flutter
// integration_test needs a server already listening on a known port
// *before* `flutter test` launches the app pointed at it via
// --dart-define=MICROLAB_SERVER_URL=http://localhost:<port>.
//
// Jest's jest.mock() isn't available outside Jest, so config/db,
// utils/sms, and config/firebase are swapped for plain, hand-rolled
// stand-ins (mockDb.js, mockSms.js) via a Module._load override — the same
// end result as jest.mock(), implemented manually. This still never opens
// a real database connection, sends a real SMS, or initializes a real
// Firebase Admin SDK.
'use strict';
const path = require('path');
const Module = require('module');

const REDIRECTS = {
  [path.join(__dirname, '..', '..', 'config', 'db.js')]:       path.join(__dirname, 'mockDb.js'),
  [path.join(__dirname, '..', '..', 'utils', 'sms.js')]:       path.join(__dirname, 'mockSms.js'),
  [path.join(__dirname, '..', '..', 'config', 'firebase.js')]: path.join(__dirname, 'mockFirebase.js'),
};

const originalResolve = Module._resolveFilename;
Module._resolveFilename = function (request, parent, ...rest) {
  const resolved = originalResolve.call(this, request, parent, ...rest);
  return REDIRECTS[resolved] ?? resolved;
};

// Deliberately NOT setting CLIENT_PATIENT_URL/JAYAMALA_URL — the customer
// verifyOtp path's registry lookup then throws immediately (invalid URL,
// never reaches the network) and is swallowed non-fatally, exactly as
// proven safe in tests/e2e/customer.auth.e2e.test.js.
process.env.JWT_SECRET = 'e2e-web-test-secret-not-real';
process.env.OTP_MAX_ATTEMPTS = '3';
process.env.OTP_EXPIRY_MINUTES = '10';

const express = require('express');
const cors    = require('cors');
const http    = require('http');
const { Server } = require('socket.io');
const bookingSocket     = require('../../socket/bookingSocket');
const bookingController = require('../../controllers/bookingController');

const app = express();
app.use(cors());
app.use(express.json());

const httpServer = http.createServer(app);
const io = new Server(httpServer, { cors: { origin: '*' } });
bookingController.setIo(io);
io.on('connection', (socket) => bookingSocket(io, socket));

app.use('/api/auth',         require('../../routes/auth'));
app.use('/api/bookings',     require('../../routes/bookings'));
app.use('/api/technicians',  require('../../routes/technicians'));
app.use('/api/branches',     require('../../routes/branches'));
app.use('/api/packages',     require('../../routes/packages'));
app.use('/api/patients',     require('../../routes/patients'));
app.use('/api/slots',        require('../../routes/slots'));
app.use('/api/prescriptions',require('../../routes/prescriptions'));

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

const port = Number(process.argv[2]) || 4001;
httpServer.listen(port, () => {
  console.log(`[e2e-web test server] listening on http://localhost:${port}`);
});
