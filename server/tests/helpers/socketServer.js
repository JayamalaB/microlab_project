// Spins up a REAL Socket.IO server (bound to an OS-assigned free port, not a
// fixed one — avoids clashing with a real dev server or another test file
// running in parallel) wired up exactly like server.js does:
//   const io = new Server(httpServer, { cors: { origin: '*' } });
//   io.on('connection', socket => bookingSocket(io, socket));
//
// This is deliberately NOT mocking Socket.IO itself — bookingSocket.js's
// in-memory dispatch state (onlineTechnicians, dispatchQueues,
// acceptedBookings) lives in closures private to that module and is never
// exported, so the only faithful way to exercise the real race-condition
// guard, room broadcasts, etc. is to run a real server and connect real
// socket.io-client sockets to it, the same way the Flutter apps do.
const http = require('http');
const { Server } = require('socket.io');
const { io: ioClient } = require('socket.io-client');
const bookingSocket = require('../../socket/bookingSocket');

function startTestSocketServer() {
  const httpServer = http.createServer();
  const io = new Server(httpServer, { cors: { origin: '*' } });
  io.on('connection', (socket) => bookingSocket(io, socket));

  return new Promise((resolve) => {
    httpServer.listen(0, () => {
      const port = httpServer.address().port;
      resolve({
        io,
        httpServer,
        url: `http://localhost:${port}`,
        close: () => new Promise((res) => {
          io.close();
          httpServer.close(() => res());
        }),
      });
    });
  });
}

// Connects one socket.io-client and resolves once it's actually connected —
// tests should always await this rather than racing the 'connect' event
// themselves, since a client that emits before connecting silently drops
// the event.
function connectClient(url) {
  return new Promise((resolve, reject) => {
    const socket = ioClient(url, { transports: ['websocket'], forceNew: true });
    socket.once('connect', () => resolve(socket));
    socket.once('connect_error', reject);
  });
}

// Waits for one named event on a client socket, with a safety timeout so a
// test fails fast with a clear message instead of hanging for the full
// Jest testTimeout when an expected event never arrives.
function waitForEvent(socket, event, timeoutMs = 2000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`Timed out waiting for '${event}' event`)),
      timeoutMs
    );
    socket.once(event, (payload) => {
      clearTimeout(timer);
      resolve(payload);
    });
  });
}

module.exports = { startTestSocketServer, connectClient, waitForEvent };
