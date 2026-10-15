// Confirms bookingSocket.js's dlog()/clog()/log() each call the correct
// dbLogger.* entry point on a real dispatch/collection event — the one
// added line per function from this change. dbLogger itself is mocked (not
// config/db) so this stays fast/deterministic — see tests/utils/dbLogger.test.js
// for dbLogger's own correctness, tested in isolation.
//
// This needs its own file (not reused from an existing dispatch/collection
// test file) per this codebase's own established convention: Jest's module
// registry isolation boundary is the test FILE, and jest.mock('../../utils/dbLogger')
// must apply before bookingSocket.js is first required by startRealServer.
jest.mock('../../config/db');
jest.mock('../../config/firebase', () => ({ messaging: null }));
jest.mock('../../services/clientSync');
jest.mock('../../utils/dbLogger');
const db       = require('../../config/db');
const dbLogger = require('../../utils/dbLogger');
const { startRealServer } = require('../helpers/realServer');
const { connectClient, waitForEvent } = require('../helpers/socketServer');

let server;
beforeAll(async () => { server = await startRealServer(); });
afterAll(async () => { await server.close(); });
beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
  jest.clearAllMocks();
});

test('dlog() — a real dispatch event (REQUEST) calls dbLogger.logDispatchEvent with the booking id and tag', async () => {
  db.execute.mockResolvedValueOnce([[{ booking_date: new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }) }]]);
  const patient = await connectClient(server.url);
  try {
    patient.emit('booking_request', {
      bookingId: 80101, patientId: 501, patientName: 'Ravi Kumar', hospital: 'Microlab Chennai',
    });
    await new Promise(r => setTimeout(r, 100));

    const requestCall = dbLogger.logDispatchEvent.mock.calls.find(c => c[1] === 'REQUEST');
    expect(requestCall).toBeDefined();
    expect(requestCall[0]).toBe(80101);
  } finally {
    patient.disconnect();
  }
});

test('log() — DUPLICATE_REQUEST (a log()-only event, not dlog()) also reaches dbLogger.logDispatchEvent', async () => {
  db.execute.mockResolvedValue([[], {}]);
  const patient = await connectClient(server.url);
  try {
    patient.emit('booking_request', { bookingId: 80102, patientId: 501, patientName: 'Ravi', hospital: 'X' });
    patient.emit('booking_request', { bookingId: 80102, patientId: 501, patientName: 'Ravi', hospital: 'X' });
    await new Promise(r => setTimeout(r, 150));

    const dupCall = dbLogger.logDispatchEvent.mock.calls.find(c => c[1] === 'DUPLICATE_REQUEST');
    expect(dupCall).toBeDefined();
    expect(dupCall[0]).toBe(80102);
  } finally {
    patient.disconnect();
  }
});

test('log() with bookingId="-" (a non-booking technician-connectivity event) does NOT reach dbLogger.logDispatchEvent', async () => {
  const tech = await connectClient(server.url);
  try {
    tech.emit('technician_online', { technicianId: 901, technicianName: 'Test', lat: 13.05, lng: 80.25 });
    await waitForEvent(tech, 'session_started');
    tech.emit('technician_offline', { technicianId: 901 }); // logs TECH_OFFLINE with bookingId='-'
    await new Promise(r => setTimeout(r, 50));

    const noBookingCall = dbLogger.logDispatchEvent.mock.calls.find(c => c[1] === 'TECH_OFFLINE');
    expect(noBookingCall).toBeUndefined();
  } finally {
    tech.disconnect();
  }
});

test('clog() — collection_started calls dbLogger.logCollectionEvent', async () => {
  const tech = await connectClient(server.url);
  try {
    tech.emit('collection_started', { bookingId: 80103, technicianId: 901 });
    await new Promise(r => setTimeout(r, 50));

    expect(dbLogger.logCollectionEvent).toHaveBeenCalled();
    const msg = dbLogger.logCollectionEvent.mock.calls.map(c => c[0]).join(' | ');
    expect(msg).toContain('collection_started');
    expect(msg).toContain('80103');
  } finally {
    tech.disconnect();
  }
});
