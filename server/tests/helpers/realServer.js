// Builds the REAL Microlab backend for integration testing — every real
// route, every real middleware, every real controller, and a real
// Socket.IO server wired exactly like server.js — bound to an OS-assigned
// free port (or, when a Flutter test needs to know the URL ahead of time,
// a fixed one — see startRealServer's `port` option) so genuine HTTP and
// WebSocket clients can talk to it over the network, not through
// Supertest's in-memory request().
//
// This is deliberately NOT server.js's mocked-away twin: every controller,
// route, and socket handler that runs here is the exact same code that
// runs in production, unmodified. It intentionally skips exactly two
// things:
//   1. server.js's own startup bootstrapping — settings.init(),
//      initKnowledge(), and bookingSocket.initDispatchState() only rebuild
//      in-memory caches from the database (irrelevant with the DB mocked)
//      and start real cron timers (dispatchScheduler,
//      technicianOfflineSweep) that would otherwise fire throughout every
//      test file using this harness.
//   2. The chatbot/voice routes (routes/chat, routes/voice) — unrelated to
//      the customer/technician booking flows this task covers, and they
//      construct real OpenAI/Sarvam clients at require time.
//
// ⚠️ MANDATORY — every test file that calls startRealServer() MUST put ALL
// THREE of these at its own top, before requiring this helper (exactly like
// every other helper in this suite; jest.mock calls are hoisted per-file,
// so a shared helper cannot do this for you):
//   jest.mock('../../config/db');
//   jest.mock('../../config/firebase', () => ({ messaging: null }));
//   jest.mock('../../utils/sms');
// Skipping the 3rd one is not hypothetical: the very first time this
// harness was smoke-tested, a real SMS was sent to a real gateway (the
// 238ms round trip and "raw=101 ✅ delivered" log gave it away) because
// only the first two mocks were in place — every route mounted below can
// reach sendOtp/generateBookingOtp/resendBookingOtp, all of which call
// utils/sms.js for real unless it's mocked.
const http = require('http');
const express = require('express');
const cors = require('cors');
const { Server } = require('socket.io');
const bookingSocket = require('../../socket/bookingSocket');
const bookingController = require('../../controllers/bookingController');

function startRealServer({ port = 0 } = {}) {
  const app = express();
  app.use(cors());
  app.use(express.json());

  const httpServer = http.createServer(app);
  const io = new Server(httpServer, { cors: { origin: '*' } });

  // Exactly mirrors server.js:20 — lets REST controllers push socket
  // updates (e.g. a technician accepting via socket notifies the customer;
  // an admin/REST status change can push to sockets too).
  bookingController.setIo(io);
  io.on('connection', (socket) => bookingSocket(io, socket));

  app.use('/api/auth',                  require('../../routes/auth'));
  app.use('/api/bookings',              require('../../routes/bookings'));
  app.use('/api/technicians',           require('../../routes/technicians'));
  app.use('/api/branches',              require('../../routes/branches'));
  app.use('/api/packages',              require('../../routes/packages'));
  app.use('/api/patients',              require('../../routes/patients'));
  app.use('/api/slots',                 require('../../routes/slots'));
  app.use('/api/upload',                require('../../routes/upload'));
  app.use('/api/prescriptions',         require('../../routes/prescriptions'));
  app.use('/api/feedback',              require('../../routes/feedback'));
  app.use('/api/prescription-requests', require('../../routes/prescriptionRequests'));

  app.get('/health', (_req, res) => res.json({ status: 'ok' }));

  return new Promise((resolve) => {
    httpServer.listen(port, () => {
      const boundPort = httpServer.address().port;
      resolve({
        app, io, httpServer, port: boundPort,
        url: `http://localhost:${boundPort}`,
        close: () => new Promise((res) => {
          io.close();
          httpServer.close(() => res());
        }),
      });
    });
  });
}

module.exports = { startRealServer };
