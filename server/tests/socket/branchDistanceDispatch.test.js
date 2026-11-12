// Socket.IO tests for branch distance in dispatch (socket/bookingSocket.js +
// services/dispatchDistance.js): when nobody at the booking's branch can take
// the job, the next branch is the one nearest to the CUSTOMER (customer →
// branch distance), not the technician whose GPS is nearest; and the branch
// that served, its distance and the difference against the original branch
// are saved when the technician accepts.
//
// A real Socket.IO server running the real handler, with only the DB and
// Firebase mocked (same setup as multiBranchDispatch.test.js). Each test uses
// its own technician ids and map area, because technicians from earlier tests
// stay in the in-memory pool during the reconnect grace period.
jest.mock('../../config/db');
jest.mock('../../config/firebase', () => ({ messaging: null }));
const db = require('../../config/db');
const { startTestSocketServer, connectClient, waitForEvent } = require('../helpers/socketServer');

// 1 km of latitude on the haversine sphere (R = 6371 km).
const KM_LAT = 180 / (Math.PI * 6371);

// Each area: the customer, and branches at a set distance north of them.
function area(lat, lng) {
  const branch = (id, name, km, code) => ({
    branch_id: id, name, branch_code: code, latitude: lat + km * KM_LAT, longitude: lng,
  });
  return { lat, lng, branch };
}

let BRANCHES = [];     // every ip_branches row the mock knows
let TECHS = [];        // ip_technicians rows: technician_id → own branch
let BOOKING = {};      // booking_id → saved original_* (null = never dispatched)
let sessionSeq = 9500;

let server;
beforeAll(async () => { server = await startTestSocketServer(); });
afterAll(async () => { await server.close(); });

beforeEach(() => {
  db.query.mockReset().mockResolvedValue([[], {}]);
  db.execute.mockReset().mockImplementation(async (sql, params = []) => {
    // Branches: codes (technician matching), locations (fallback order, distances).
    if (/FROM ip_branches WHERE branch_id = \?/.test(sql)) {
      return [BRANCHES.filter(b => b.branch_id === Number(params[0]))];
    }
    if (/FROM ip_branches/.test(sql)) return [BRANCHES];
    // Technicians: no ASMX codes, so each works only at its own branch.
    if (sql.includes('SELECT branch_ids, default_branch_id FROM ip_technicians')) {
      return [[{ branch_ids: null, default_branch_id: null }]];
    }
    if (/FROM ip_technicians t\s+LEFT JOIN ip_users/.test(sql)) return [TECHS];
    // Every branch with a technician has bookable slots.
    if (/FROM ip_technician_slots ts\s+JOIN ip_slots/.test(sql)) return [[{ 1: 1 }]];
    // Bookings.
    if (/SELECT original_branch_id, original_distance_km FROM ip_bookings/.test(sql)) {
      const b = BOOKING[params[0]];
      return [[{ original_branch_id: b?.original_branch_id ?? null, original_distance_km: b?.original_distance_km ?? null }]];
    }
    if (/SELECT branch_id, collection_latitude/.test(sql)) {
      const b = BOOKING[params[0]];
      return [b ? [{ branch_id: b.branch_id, collection_latitude: b.lat, collection_longitude: b.lng,
        original_branch_id: b.original_branch_id ?? null, original_distance_km: b.original_distance_km ?? null }] : []];
    }
    if (sql.includes('SELECT status FROM ip_bookings')) return [[{ status: 'pending' }]];
    // Service charge: each booking is its own visit, pending until accept;
    // ip_products km ranges (up and down): 0–10 km ₹75, 10–20 km ₹150.
    if (/SELECT b\.booking_id, b\.status, b\.service_charge_status/.test(sql)) {
      return [[{ booking_id: params[0], status: 'assigned', service_charge_status: 'pending',
        home_collection_fare: null, total_amount: '500.00', amount_paid: '0.00', payment_status: 'unpaid' }]];
    }
    if (/FROM ip_products\s+WHERE from_km <= \?/.test(sql)) {
      const km = params[0];
      return [km <= 10 ? [{ product_id: 61, product_name: 'FEES (75)', test_code: '06020', product_price: '75.00' }]
        : km <= 20 ? [{ product_id: 62, product_name: 'FEES (150)', test_code: '06021', product_price: '150.00' }] : []];
    }
    if (sql.includes('INSERT INTO ip_technician_sessions')) return [{ insertId: ++sessionSeq }];
    if (sql.includes('SELECT booking_date FROM ip_bookings')) {
      return [[{ booking_date: new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }) }]];
    }
    if (sql.includes('document_required')) return [[{ doc_required: 0 }]];
    if (/^\s*(UPDATE|INSERT|DELETE)/.test(sql)) return [{ affectedRows: 1, insertId: 1 }];
    return [[], {}];
  });
});

async function goOnline(technicianId, branchId, lat, lng) {
  const sock = await connectClient(server.url);
  sock.emit('technician_online', { technicianId, technicianName: `Tech${technicianId}`, branchId, lat, lng });
  await waitForEvent(sock, 'session_started');
  await new Promise(r => setTimeout(r, 50)); // let the branch-list load land
  return sock;
}

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
    patientAddress: '12 MG Road', patientLat: lat, patientLng: lng, hospital: 'Microlab', branchId,
  });
  return patient;
}

// The UPDATE … served_branch_id … for this booking, once it has run.
async function servedUpdate(bookingId, timeoutMs = 2000) {
  const end = Date.now() + timeoutMs;
  for (;;) {
    const call = db.execute.mock.calls.find(c => /served_branch_id\s+= \?/.test(c[0]) && c[1][0] === bookingId);
    if (call) return call[1];
    if (Date.now() > end) throw new Error('serving branch was not saved');
    await new Promise(r => setTimeout(r, 25));
  }
}
// The UPDATE … service_charge_status = ? (calculated at accept) for this booking.
async function serviceChargeUpdate(bookingId, timeoutMs = 2000) {
  const end = Date.now() + timeoutMs;
  for (;;) {
    const call = db.execute.mock.calls.find(c => /service_charge_status = \?, updated_at/.test(c[0]) && c[1].at(-1) === bookingId);
    if (call) return call[1];
    if (Date.now() > end) throw new Error('service charge was not calculated');
    await new Promise(r => setTimeout(r, 25));
  }
}
const baselineUpdate = (bookingId) =>
  db.execute.mock.calls.find(c => /original_branch_id\s+= COALESCE/.test(c[0]) && !/served_branch_id/.test(c[0]) && c[1][0] === bookingId)?.[1];

describe('request-time branch fallback by customer → branch distance', () => {
  test('Peelamedu (2 km) has nobody: Coimbatore (6.1 km) is next — not the technician whose GPS is nearest', async () => {
    const A = area(31.0, 91.0);
    BRANCHES = [
      A.branch(2, 'PEELAMEDU', 2, '42'),
      A.branch(1, 'COIMBATORE', 6.1, '01'),
      A.branch(3, 'FAR BRANCH', 15, '03'),
    ];
    TECHS = [
      { technician_id: 701, branch_id: 1, branch_ids: null, default_branch_id: null, user_name: 'Dinesh' },
      { technician_id: 702, branch_id: 3, branch_ids: null, default_branch_id: null, user_name: 'Far' },
    ];
    BOOKING[90001] = { branch_id: 1, lat: A.lat, lng: A.lng, original_branch_id: 2, original_distance_km: '2.00' };

    // 701 works at Coimbatore but its phone is ~30 km away; 702 works at the
    // far branch but stands next to the customer. Old fallback: 702.
    const t701 = await goOnline(701, 1, A.lat + 0.3, A.lng + 0.3);
    const t702 = await goOnline(702, 3, A.lat + 0.0005, A.lng + 0.0005);
    let patient;
    try {
      const offer = firstOffer({ 701: t701, 702: t702 });
      patient = await requestBooking(90001, 2, A.lat, A.lng);
      expect(await offer).toBe(701);

      t701.emit('booking_accepted', { bookingId: 90001, technicianId: 701, technicianName: 'Dinesh' });
      // [bookingId, original branch, original km, served branch, served km, difference, extra]
      const [id, origId, origKm, servedId, servedKm, diff, extra] = await servedUpdate(90001);
      expect([id, origId, servedId]).toEqual([90001, 2, 1]);
      expect(origKm).toBeCloseTo(2, 2);
      expect(servedKm).toBeCloseTo(6.1, 2);
      expect(diff).toBeCloseTo(4.1, 2);
      expect(extra).toBeCloseTo(4.1, 2);

      // Service charge from Coimbatore: 6.10 km × 2 = 12.20 km → the ₹150
      // product, saved as 'calculated' — added to the bill on arrival.
      const sc = await serviceChargeUpdate(90001);
      expect(sc).toEqual([150, 62, 12.2, 6.1, 'calculated', 90001]);
    } finally {
      patient?.disconnect(); t701.disconnect(); t702.disconnect();
    }
  });

  test('a nearer branch serves: negative difference, extra 0', async () => {
    const A = area(33.0, 93.0);
    BRANCHES = [
      A.branch(4, 'BOOKED BRANCH', 9, '04'),
      A.branch(1, 'COIMBATORE', 6.1, '01'),
    ];
    TECHS = [{ technician_id: 711, branch_id: 1, branch_ids: null, default_branch_id: null, user_name: 'Dinesh' }];
    BOOKING[90002] = { branch_id: 1, lat: A.lat, lng: A.lng }; // never dispatched: no saved original

    const t711 = await goOnline(711, 1, A.lat + 0.01, A.lng);
    let patient;
    try {
      const offer = firstOffer({ 711: t711 });
      patient = await requestBooking(90002, 4, A.lat, A.lng);
      expect(await offer).toBe(711);

      // The first dispatch saved branch 4 (9 km) as the original.
      const base = baselineUpdate(90002);
      expect(base[1]).toBe(4);
      expect(base[2]).toBeCloseTo(9, 2);

      BOOKING[90002] = { ...BOOKING[90002], original_branch_id: 4, original_distance_km: '9.00' };
      t711.emit('booking_accepted', { bookingId: 90002, technicianId: 711, technicianName: 'Dinesh' });
      const [, origId, , servedId, servedKm, diff, extra] = await servedUpdate(90002);
      expect([origId, servedId]).toEqual([4, 1]);
      expect(servedKm).toBeCloseTo(6.1, 2);
      expect(diff).toBeCloseTo(-2.9, 2);
      expect(extra).toBe(0);
    } finally {
      patient?.disconnect(); t711.disconnect();
    }
  });

  test('a technician at the booking\'s own branch is still offered first (no fallback)', async () => {
    const A = area(35.0, 95.0);
    BRANCHES = [A.branch(2, 'PEELAMEDU', 2, '42'), A.branch(1, 'COIMBATORE', 6.1, '01')];
    TECHS = [
      { technician_id: 721, branch_id: 2, branch_ids: null, default_branch_id: null, user_name: 'Elumalai' },
      { technician_id: 722, branch_id: 1, branch_ids: null, default_branch_id: null, user_name: 'Dinesh' },
    ];
    BOOKING[90003] = { branch_id: 2, lat: A.lat, lng: A.lng };

    const t721 = await goOnline(721, 2, A.lat + 0.05, A.lng);   // farther GPS, but at the booking's branch
    const t722 = await goOnline(722, 1, A.lat + 0.0005, A.lng); // nearer GPS, other branch
    let patient;
    try {
      const offer = firstOffer({ 721: t721, 722: t722 });
      patient = await requestBooking(90003, 2, A.lat, A.lng);
      expect(await offer).toBe(721);

      BOOKING[90003] = { ...BOOKING[90003], original_branch_id: 2, original_distance_km: '2.00' };
      t721.emit('booking_accepted', { bookingId: 90003, technicianId: 721, technicianName: 'Elumalai' });
      const [, origId, , servedId, servedKm, diff, extra] = await servedUpdate(90003);
      expect([origId, servedId]).toEqual([2, 2]);
      expect(servedKm).toBeCloseTo(2, 2);
      expect(diff).toBe(0);
      expect(extra).toBe(0);
    } finally {
      patient?.disconnect(); t721.disconnect(); t722.disconnect();
    }
  });

  test('a redispatch starts again from the ORIGINAL branch, not the last serving branch', async () => {
    // After a reassignment the booking's branch_id is the branch that served
    // before (Coimbatore, 1), and the redispatch asks for branch 1. The saved
    // original is Peelamedu (2): its technician must be offered first, and the
    // distance is measured from it.
    const A = area(37.0, 97.0);
    BRANCHES = [A.branch(2, 'PEELAMEDU', 2, '42'), A.branch(1, 'COIMBATORE', 6.1, '01')];
    TECHS = [
      { technician_id: 731, branch_id: 1, branch_ids: null, default_branch_id: null, user_name: 'Dinesh' },
      { technician_id: 732, branch_id: 2, branch_ids: null, default_branch_id: null, user_name: 'Elumalai' },
    ];
    BOOKING[90004] = { branch_id: 1, lat: A.lat, lng: A.lng, original_branch_id: 2, original_distance_km: '2.00' };

    const t731 = await goOnline(731, 1, A.lat + 0.0005, A.lng); // nearer GPS, last serving branch
    const t732 = await goOnline(732, 2, A.lat + 0.02, A.lng);   // original branch
    let patient;
    try {
      const offer = firstOffer({ 731: t731, 732: t732 });
      patient = await requestBooking(90004, 1, A.lat, A.lng);
      expect(await offer).toBe(732);

      t732.emit('booking_accepted', { bookingId: 90004, technicianId: 732, technicianName: 'Elumalai' });
      const [, origId, origKm, servedId, servedKm, diff] = await servedUpdate(90004);
      expect([origId, servedId]).toEqual([2, 2]);
      expect(origKm).toBeCloseTo(2, 2);
      expect(servedKm).toBeCloseTo(2, 2);
      expect(diff).toBe(0);
    } finally {
      patient?.disconnect(); t731.disconnect(); t732.disconnect();
    }
  });

  test('a redispatch whose original branch has nobody falls back by customer distance again, measured from the original', async () => {
    const A = area(39.0, 99.0);
    BRANCHES = [A.branch(2, 'PEELAMEDU', 2, '42'), A.branch(1, 'COIMBATORE', 6.1, '01')];
    TECHS = [{ technician_id: 741, branch_id: 1, branch_ids: null, default_branch_id: null, user_name: 'Dinesh' }];
    BOOKING[90005] = { branch_id: 1, lat: A.lat, lng: A.lng, original_branch_id: 2, original_distance_km: '2.00' };

    const t741 = await goOnline(741, 1, A.lat + 0.01, A.lng);
    let patient;
    try {
      const offer = firstOffer({ 741: t741 });
      patient = await requestBooking(90005, 1, A.lat, A.lng);
      expect(await offer).toBe(741);

      t741.emit('booking_accepted', { bookingId: 90005, technicianId: 741, technicianName: 'Dinesh' });
      const [, origId, , servedId, , diff] = await servedUpdate(90005);
      expect([origId, servedId]).toEqual([2, 1]);
      expect(diff).toBeCloseTo(4.1, 2);
    } finally {
      patient?.disconnect(); t741.disconnect();
    }
  });
});
