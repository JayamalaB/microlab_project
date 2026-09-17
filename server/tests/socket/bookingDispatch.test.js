// Socket.IO tests for socket/bookingSocket.js — technician online/offline,
// location tracking, and the booking_accepted race-condition guard.
//
// Unlike the REST controller tests, this file connects REAL socket.io-client
// sockets to a real (locally-bound, ephemeral-port) Socket.IO server running
// the actual bookingSocket.js handler — because its dispatch state
// (onlineTechnicians, dispatchQueues, acceptedBookings) lives in module-
// private closures that are never exported, so there's no way to unit-test
// them directly; running the real thing end-to-end is the only faithful way.
//
// Only the two true I/O boundaries are mocked: the DB (config/db) and
// Firebase (config/firebase, forced to messaging:null so no code path can
// ever attempt a real push — belt-and-suspenders on top of the DB mock
// already returning no FCM token by default).
//
// NOTE on process exit: any socket that ever calls technician_online sets
// socket.technicianId, and the real disconnect handler unconditionally
// starts a genuine 45-second (GRACE_MS) setTimeout on disconnect — that's
// hardcoded production reconnect-grace behavior this task isn't allowed to
// change just to make tests exit faster. Jest will otherwise sit for up to
// a minute waiting for those timers to drain after the assertions have
// already finished. Run this file (and `npm test`, which includes it) with
// --forceExit, already wired into package.json's "test" script — it only
// makes the process exit promptly once Jest has reported results; it does
// not skip, hide, or weaken any assertion.
jest.mock('../../config/db');
jest.mock('../../config/firebase', () => ({ messaging: null }));
const db = require('../../config/db');
const { startTestSocketServer, connectClient, waitForEvent } = require('../helpers/socketServer');

let server;

beforeAll(async () => {
  server = await startTestSocketServer();
});

afterAll(async () => {
  await server.close();
});

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.query.mockReset().mockResolvedValue([[], {}]);
});

describe('technician_online', () => {
  // TC-SOCK-01 — going online completes the ip_technician_sessions INSERT
  // round trip and echoes session_started back to that same technician.
  test('a technician going online receives session_started', async () => {
    // The generic default mock ([[], {}]) is shaped for a SELECT (empty rows
    // array); this handler's session insert destructures the resolved value
    // as ([result]) => result.insertId, which needs an INSERT-shaped
    // response — [{insertId, ...}, fields] — or sessionId silently comes
    // back as undefined (and JSON-less-over-the-wire, socket.io drops the
    // key entirely rather than sending sessionId:null). Two calls happen
    // before the response we care about: the live-location upsert (dbRun,
    // return value unused) first, then the session INSERT.
    db.execute
      .mockResolvedValueOnce([{}, undefined])
      .mockResolvedValueOnce([{ insertId: 777 }, undefined]);

    const tech = await connectClient(server.url);
    try {
      const sessionPromise = waitForEvent(tech, 'session_started');
      tech.emit('technician_online', {
        technicianId: 501, technicianName: 'Suresh', lat: 13.05, lng: 80.25,
      });
      const payload = await sessionPromise;
      expect(payload.sessionId).toBe(777);
      // Confirms the online-status write actually reached the DB layer (mocked).
      expect(db.execute).toHaveBeenCalledWith(
        expect.stringContaining('ip_technician_sessions'),
        expect.arrayContaining([501])
      );
    } finally {
      tech.disconnect();
    }
  });
});

describe('update_technician_location', () => {
  // TC-SOCK-02 — the location/tracking flow: a GPS ping from the technician
  // app is written straight through to ip_technician_live_location.
  test('a location update is persisted with the reported coordinates', async () => {
    const tech = await connectClient(server.url);
    try {
      tech.emit('technician_online', { technicianId: 501, technicianName: 'Suresh' });
      await waitForEvent(tech, 'session_started');
      db.execute.mockClear();

      tech.emit('update_technician_location', {
        technicianId: 501, lat: 13.06, lng: 80.26, accuracy: 12, speed: 4, bearing: 90,
      });

      // Fire-and-forget write — briefly yield so the async db.execute call lands.
      await new Promise(r => setTimeout(r, 50));

      expect(db.execute).toHaveBeenCalledWith(
        expect.stringContaining('ip_technician_live_location'),
        [13.06, 80.26, 12, 4, 90, null, null, 501]
      );
    } finally {
      tech.disconnect();
    }
  });

  // Negative case: a location update missing lat/lng is silently ignored —
  // no partial/garbage write should ever reach the DB.
  test('an incomplete location update (no lat/lng) is ignored', async () => {
    const tech = await connectClient(server.url);
    try {
      tech.emit('technician_online', { technicianId: 501, technicianName: 'Suresh' });
      await waitForEvent(tech, 'session_started');
      db.execute.mockClear();

      tech.emit('update_technician_location', { technicianId: 501 }); // no lat/lng
      await new Promise(r => setTimeout(r, 50));

      expect(db.execute).not.toHaveBeenCalledWith(
        expect.stringContaining('ip_technician_live_location'),
        expect.anything()
      );
    } finally {
      tech.disconnect();
    }
  });
});

describe('booking_accepted — duplicate/concurrent acceptance race guard', () => {
  // TC-SOCK-03 — the highest-value concurrency scenario in the task brief:
  // two technicians both try to accept the same booking. Node's single-
  // threaded event loop processes socket events one at a time regardless of
  // network timing, so emitting sequentially here exercises the exact same
  // acceptedBookings-Set guard a true simultaneous race would hit on the
  // real server — there is no server-side parallelism to race against.
  test('only the first technician to accept wins; the second is silently blocked', async () => {
    const bookingId = 70001;
    const patient = await connectClient(server.url);
    const techA    = await connectClient(server.url);
    const techB    = await connectClient(server.url);
    try {
      // Patient subscribes to this booking's room — _notifyPatient broadcasts
      // booking_accepted to io.to(String(bookingId)) regardless of any other
      // patient-socket bookkeeping, so joining the room is sufficient.
      patient.emit('join_tracking', { trackingId: bookingId });
      await new Promise(r => setTimeout(r, 30)); // let the join land server-side

      const firstAccept = waitForEvent(patient, 'booking_accepted');
      techA.emit('booking_accepted', { bookingId, technicianId: 501, technicianName: 'Suresh' });
      const winnerPayload = await firstAccept;
      expect(winnerPayload.technicianId).toBe(501);

      // Second technician's accept for the SAME booking must be dropped —
      // assert by proving no second booking_accepted event ever reaches the
      // patient, within a bounded wait.
      let secondEventArrived = false;
      patient.once('booking_accepted', () => { secondEventArrived = true; });
      techB.emit('booking_accepted', { bookingId, technicianId: 502, technicianName: 'Meena' });
      await new Promise(r => setTimeout(r, 200));

      expect(secondEventArrived).toBe(false);
    } finally {
      patient.disconnect();
      techA.disconnect();
      techB.disconnect();
    }
  });

  // Negative case: booking_accepted with no bookingId at all must be a no-op
  // — never crash the server, never notify anyone.
  test('an accept event missing bookingId is ignored', async () => {
    const patient = await connectClient(server.url);
    const tech    = await connectClient(server.url);
    try {
      patient.emit('join_tracking', { trackingId: 70002 });
      await new Promise(r => setTimeout(r, 30));

      let received = false;
      patient.once('booking_accepted', () => { received = true; });
      tech.emit('booking_accepted', { technicianId: 501 }); // no bookingId
      await new Promise(r => setTimeout(r, 100));

      expect(received).toBe(false);
      // The server is still alive and responsive to a well-formed event
      // afterward — proves the malformed payload didn't crash the handler.
      const ok = waitForEvent(patient, 'booking_accepted');
      tech.emit('booking_accepted', { bookingId: 70002, technicianId: 501, technicianName: 'Suresh' });
      await expect(ok).resolves.toBeDefined();
    } finally {
      patient.disconnect();
      tech.disconnect();
    }
  });

  // FINDING, not a correctness assertion of intended behavior: bookingSocket.js
  // registers no io.use() handshake authentication anywhere (confirmed by
  // reading server.js and bookingSocket.js in full — no JWT verification
  // exists at the Socket.IO layer, only on REST routes via middleware/auth.js).
  // Any socket can claim to be any technicianId and have a booking_accepted
  // processed for it — there is no server-side check that this technicianId
  // ever called technician_online, is currently online, or was even part of
  // this booking's dispatch queue. This test documents that real, current
  // behavior (not a bug this task is allowed to fix) — see the final test
  // report for this as a reported finding.
  test('FINDING: a socket that never went online can still successfully accept a booking', async () => {
    const bookingId = 70003;
    const patient = await connectClient(server.url);
    const strangerTech = await connectClient(server.url); // never emitted technician_online
    try {
      patient.emit('join_tracking', { trackingId: bookingId });
      await new Promise(r => setTimeout(r, 30));

      const accepted = waitForEvent(patient, 'booking_accepted');
      strangerTech.emit('booking_accepted', { bookingId, technicianId: 999999, technicianName: 'Unregistered' });

      const payload = await accepted;
      expect(payload.technicianId).toBe(999999);
    } finally {
      patient.disconnect();
      strangerTech.disconnect();
    }
  });
});
