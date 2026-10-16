// Socket.IO tests for multi-branch dispatch (socket/bookingSocket.js):
// a technician's branches are ip_technicians.default_branch_id + branch_ids
// (ASMX codes), each matched with ip_branches.branch_code — never
// ip_technicians.branch_id. A technician is eligible for a booking's branch
// when it is one of those matched branches (or the branch the app sent at
// go-online). Everyone eligible is ranked together by distance.
//
// Same setup as bookingDispatch.test.js: a real Socket.IO server running the
// real handler, with only the DB and Firebase mocked. Each scenario uses its
// own technician IDs and its own map area, because technicians from earlier
// tests stay in the in-memory pool during the 45 s reconnect grace period.
// Run with --forceExit (as `npm test` does) — see bookingDispatch.test.js.
jest.mock('../../config/db');
jest.mock('../../config/firebase', () => ({ messaging: null }));
const db = require('../../config/db');
const { startTestSocketServer, connectClient, waitForEvent } = require('../helpers/socketServer');

// technician_id → ip_technicians row: default_branch_id + branch_ids are ASMX
// codes. branch_id is set to a different value on purpose — dispatch must
// ignore it.
const TECH_ROWS = {
  611: { branch_id: 1,  default_branch_id: '07', branch_ids: '["03","04","07"]' }, // 7, also 3 and 4
  612: { branch_id: 1,  default_branch_id: null, branch_ids: null },               // no codes (app sends 9)
  621: { branch_id: 1,  default_branch_id: '07', branch_ids: '["03","04","07"]' },
  622: { branch_id: 1,  default_branch_id: '04', branch_ids: '["04"]' },
  631: { branch_id: 1,  default_branch_id: '07', branch_ids: '["XX","99","07"]' }, // invalid / unknown codes
  632: { branch_id: 1,  default_branch_id: '05', branch_ids: null },
  641: { branch_id: 1,  default_branch_id: '07', branch_ids: '["11"]' },           // code 11 = our branch 12
  642: { branch_id: 1,  default_branch_id: '13', branch_ids: null },
  651: { branch_id: 7,  default_branch_id: '11', branch_ids: null },               // default code 11 → branch 12
  652: { branch_id: 1,  default_branch_id: '13', branch_ids: null },
  661: { branch_id: 5,  default_branch_id: null, branch_ids: null },               // nothing to match
  662: { branch_id: 1,  default_branch_id: '05', branch_ids: null },
};
// Active ip_branches rows: branch_id → branch_code (the ASMX code). Codes are
// matched by branch_code, never by assuming code == branch_id: branch 12's
// code is "11" on purpose, and branch 9 has no code at all.
const ACTIVE_BRANCHES = [
  { branch_id: 3,  branch_code: '03' },
  { branch_id: 4,  branch_code: '04' },
  { branch_id: 5,  branch_code: '05' },
  { branch_id: 7,  branch_code: '07' },
  { branch_id: 9,  branch_code: null },
  { branch_id: 12, branch_code: '11' },
  { branch_id: 13, branch_code: '13' },
];
let sessionSeq = 9000;

let server;
beforeAll(async () => { server = await startTestSocketServer(); });
afterAll(async () => { await server.close(); });

beforeEach(() => {
  db.query.mockReset().mockResolvedValue([[], {}]);
  db.execute.mockReset().mockImplementation((sql, params = []) => {
    if (sql.includes('SELECT branch_ids, default_branch_id FROM ip_technicians')) {
      const row = TECH_ROWS[params[0]];
      return Promise.resolve([row ? [row] : []]);
    }
    if (sql.includes('FROM ip_branches')) {
      return Promise.resolve([ACTIVE_BRANCHES]);
    }
    if (sql.includes('INSERT INTO ip_technician_sessions')) {
      return Promise.resolve([{ insertId: ++sessionSeq }]);
    }
    if (sql.includes('SELECT booking_date FROM ip_bookings')) {
      return Promise.resolve([[{ booking_date: new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }) }]]);
    }
    if (sql.includes('ip_patient_tracking_metadata')) return Promise.resolve([{}]);
    if (sql.includes('document_required')) return Promise.resolve([[{ doc_required: 0 }]]);
    return Promise.resolve([[], {}]);
  });
});

async function goOnline(technicianId, branchId, lat, lng) {
  const sock = await connectClient(server.url);
  sock.emit('technician_online', { technicianId, technicianName: `Tech${technicianId}`, branchId, lat, lng });
  await waitForEvent(sock, 'session_started');
  await new Promise(r => setTimeout(r, 50)); // let the branch-list load land
  return sock;
}

// Resolves with the id of the first technician socket that gets booking_request.
function firstOffer(socketsById, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('no booking_request received')), timeoutMs);
    for (const [id, sock] of Object.entries(socketsById)) {
      sock.once('booking_request', () => { clearTimeout(timer); resolve(Number(id)); });
    }
  });
}

async function requestBooking(bookingId, branchId, lat, lng) {
  const patient = await connectClient(server.url);
  patient.emit('booking_request', {
    bookingId, patientId: 501, patientName: 'Ravi Kumar', patientMobile: '9876543210',
    patientAddress: '12 MG Road', patientLat: lat, patientLng: lng,
    hospital: 'Microlab', branchId,
  });
  return patient;
}

describe('multi-branch dispatch (default branch + assigned branches, nearest first)', () => {
  test('a branch-4 booking reaches a technician whose default is 7 but who is assigned to 04 — not the nearer branch-9 technician', async () => {
    // Before this change: nobody counted as branch 4, so the any-branch
    // fallback would have offered it to the NEAREST technician (612).
    const t611 = await goOnline(611, 7, 13.10, 80.30); // ~6 km away, allowed at 4
    const t612 = await goOnline(612, 9, 13.051, 80.251); // ~0.1 km away, branch 9 only
    let patient;
    try {
      const offer = firstOffer({ 611: t611, 612: t612 });
      patient = await requestBooking(80001, 4, 13.05, 80.25);
      expect(await offer).toBe(611);
    } finally {
      patient?.disconnect(); t611.disconnect(); t612.disconnect();
    }
  });

  test('nearest first: an assigned-branch technician nearby is offered before a default-branch technician far away', async () => {
    const t621 = await goOnline(621, 7, 15.051, 82.251); // ~0.1 km, branch 4 via list
    const t622 = await goOnline(622, 4, 15.20, 82.40);   // ~22 km, default branch 4
    let patient;
    try {
      const offer = firstOffer({ 621: t621, 622: t622 });
      patient = await requestBooking(80002, 4, 15.05, 82.25);
      expect(await offer).toBe(621);
    } finally {
      patient?.disconnect(); t621.disconnect(); t622.disconnect();
    }
  });

  test('invalid or unknown branch codes are ignored — the technician is not treated as assigned to them', async () => {
    // 631 lists "XX" and "99" (99 is not in ip_branches): a branch-99 booking
    // must not count them as branch 99, so the any-branch fallback picks the
    // nearest technician (632) instead.
    const t631 = await goOnline(631, 7, 17.10, 84.30);   // ~6 km
    const t632 = await goOnline(632, 5, 17.051, 84.251); // ~0.1 km
    let patient;
    try {
      const offer = firstOffer({ 631: t631, 632: t632 });
      patient = await requestBooking(80003, 99, 17.05, 84.25);
      expect(await offer).toBe(632);
    } finally {
      patient?.disconnect(); t631.disconnect(); t632.disconnect();
    }
  });

  test('codes are matched through ip_branches.branch_code, not by number: code "11" means branch 12', async () => {
    // 641's list has code "11", which ip_branches maps to branch_id 12. A
    // branch-12 booking must reach 641 even though the nearer 642 is closer.
    // (Reading "11" as branch 11 would leave nobody allowed at 12 and the
    // any-branch fallback would pick 642.)
    const t641 = await goOnline(641, 7, 19.10, 86.30);   // ~6 km, allowed at 12 via code "11"
    const t642 = await goOnline(642, 13, 19.051, 86.251); // ~0.1 km, branch 13 only
    let patient;
    try {
      const offer = firstOffer({ 641: t641, 642: t642 });
      patient = await requestBooking(80004, 12, 19.05, 86.25);
      expect(await offer).toBe(641);
    } finally {
      patient?.disconnect(); t641.disconnect(); t642.disconnect();
    }
  });

  test('default_branch_id is matched through branch_code: default code "11" makes the technician eligible for branch 12', async () => {
    // 651 has no branch_ids and the app sends branch 7 — only its
    // default_branch_id "11" (→ branch 12 via branch_code) can make it
    // eligible for a branch-12 booking over the nearer branch-13 technician.
    const t651 = await goOnline(651, 7, 21.10, 88.30);    // ~6 km
    const t652 = await goOnline(652, 13, 21.051, 88.251); // ~0.1 km, branch 13 only
    let patient;
    try {
      const offer = firstOffer({ 651: t651, 652: t652 });
      patient = await requestBooking(80005, 12, 21.05, 88.25);
      expect(await offer).toBe(651);
    } finally {
      patient?.disconnect(); t651.disconnect(); t652.disconnect();
    }
  });

  test('ip_technicians.branch_id is not used: a technician with no matching codes is excluded from branch-specific offers', async () => {
    // 661: branch_id 5 in the table, but no default_branch_id / branch_ids and
    // no branch from the app → no matched branch → excluded. The branch-5
    // booking goes to 662 (default code "05") even though 661 is nearer.
    const t661 = await goOnline(661, null, 23.051, 90.251); // ~0.1 km
    const t662 = await goOnline(662, null, 23.10, 90.30);   // ~6 km, matched branch 5
    let patient;
    try {
      const offer = firstOffer({ 661: t661, 662: t662 });
      patient = await requestBooking(80006, 5, 23.05, 90.25);
      expect(await offer).toBe(662);
    } finally {
      patient?.disconnect(); t661.disconnect(); t662.disconnect();
    }
  });
});
