// socket/bookingSocket.js — what happens around a running search: late accepts
// and declines, a stopped search, a dropped connection mid-job, the slot
// fallback, and restart recovery.
jest.mock('../../config/db');
jest.mock('../../config/firebase', () => ({ messaging: null }));
jest.mock('../../services/customerPush', () => ({ sendToBookingOwner: jest.fn() }));
jest.mock('../../services/clientSync', () => ({ syncVisitCompletionToClient: jest.fn() }));
jest.mock('../../utils/dbLogger');
// Who works at a branch is tested in tests/services/technicianBranches.test.js;
// here every branch has technicians, so the slot queries run.
jest.mock('../../services/technicianBranches', () => ({
  technicianIdsAtBranch: jest.fn(async () => [3501, 3502]),
  placeholders: (ids) => ids.map(() => '?').join(', '),
}));
const db = require('../../config/db');
const bookingSocket = require('../../socket/bookingSocket');

const TODAY = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
const flush = () => new Promise(resolve => setTimeout(resolve, 20));
const calls = (re) => db.execute.mock.calls.filter(c => re.test(c[0]));

let answers; // SQL pattern → rows, checked before the defaults
let sent;    // [socketId, event] of everything sent through io.to()
const brought = new Set(); // technicians brought online, taken offline after each test

const io = { to: (id) => ({ emit: (event) => sent.push([id, event]) }) };

function wireDb() {
  db.execute.mockReset().mockImplementation(async (sql) => {
    for (const [re, rows] of answers) if (re.test(sql)) return [rows];
    if (/SELECT booking_date FROM ip_bookings/.test(sql)) return [[{ booking_date: TODAY }]];
    if (/^\s*(UPDATE|INSERT|DELETE)/.test(sql)) return [{ affectedRows: 1, insertId: 1 }];
    return [[]];
  });
}

function connect(id) {
  const handlers = {};
  const emitted  = [];
  const socket = {
    id, on: (e, h) => { handlers[e] = h; }, once: () => {},
    emit: (event, payload) => emitted.push([event, payload]),
  };
  bookingSocket(io, socket);
  return { handlers, emitted, socket };
}

async function online(socketId, technicianId, lat = 13.05, branchId = undefined) {
  const tech = connect(socketId);
  tech.handlers.technician_online({ technicianId, technicianName: `Tech ${technicianId}`, lat, lng: 80.25, ...(branchId != null && { branchId }) });
  brought.add(technicianId);
  await flush();
  return tech;
}

const requestDispatch = async (patient, bookingId, over = {}) => {
  patient.handlers.booking_request({
    bookingId, patientId: 501, patientName: 'Asha', patientLat: 13.05, patientLng: 80.25, ...over,
  });
  await flush();
};
const offersTo = (socketId) => sent.filter(([id, e]) => id === socketId && e === 'booking_request').length;

beforeAll(() => {
  jest.spyOn(console, 'log').mockImplementation(() => {});
  jest.spyOn(console, 'warn').mockImplementation(() => {});
  jest.spyOn(process.stdout, 'write').mockImplementation(() => true);
});
beforeEach(() => { answers = []; sent = []; wireDb(); });
afterEach(() => {
  const { handlers } = connect('cleanup');
  for (const technicianId of brought) handlers.technician_offline({ technicianId });
  brought.clear();
});

describe('a late accept', () => {
  test.each([['cancelled'], ['completed'], ['assigned']])('on a %s booking changes nothing', async (status) => {
    answers = [[/SELECT status FROM ip_bookings/, [{ status }]]];
    const tech = await online('s-late', 3101);
    db.execute.mockClear();

    await tech.handlers.booking_accepted({ bookingId: 7001, technicianId: 3101, technicianName: 'T' });

    expect(calls(/SET status = 'assigned'/)).toHaveLength(0);
    expect(calls(/INSERT INTO ip_technician_collection/)).toHaveLength(0);
    expect(tech.emitted).toContainEqual(['booking_cancelled', { bookingId: 7001 }]);
  });

  test('on a pending booking goes through, even after the search ended', async () => {
    answers = [[/SELECT status FROM ip_bookings/, [{ status: 'pending' }]]];
    const tech = await online('s-ok', 3102);

    await tech.handlers.booking_accepted({ bookingId: 7002, technicianId: 3102, technicianName: 'T' });
    await flush();

    expect(calls(/SET status = 'assigned'/).length).toBeGreaterThan(0);
  });
});

describe('a running search', () => {
  test('a Decline from someone not holding the offer moves nothing', async () => {
    const near = await online('s-near', 3201, 13.05);
    const far  = await online('s-far', 3202, 13.2);
    await requestDispatch(connect('p1'), 7101);
    expect(offersTo('s-near')).toBe(1);

    far.handlers.booking_rejected({ bookingId: 7101, technicianId: 3202 });
    await flush();

    expect(offersTo('s-far')).toBe(0);
    expect(bookingSocket.stopDispatch(7101)).toBe(true);
  });

  test('a Decline from the technician holding the offer moves to the next', async () => {
    const near = await online('s-near2', 3203, 13.05);
    const far  = await online('s-far2', 3204, 13.2);
    await requestDispatch(connect('p2'), 7102);

    near.handlers.booking_rejected({ bookingId: 7102, technicianId: 3203 });
    await flush();

    expect(offersTo('s-far2')).toBe(1);
    bookingSocket.stopDispatch(7102);
  });

  test('stopping it dismisses the offer, and no further offers go out', async () => {
    const tech = await online('s-stop', 3205);
    await requestDispatch(connect('p3'), 7103);

    expect(bookingSocket.stopDispatch(7103)).toBe(true);

    expect(sent).toContainEqual(['s-stop', 'booking_cancelled']);
    expect(bookingSocket.stopDispatch(7103)).toBe(false); // nothing left running
  });

  test('a technician coming online mid-check does not crash the server', async () => {
    // Holds the first check open, which is when a booking is only "claimed".
    let release;
    const gate = new Promise((resolve) => { release = resolve; });
    db.execute.mockImplementation(async (sql) => {
      if (/document_required/.test(sql)) await gate;
      return /SELECT booking_date/.test(sql) ? [[{ booking_date: TODAY }]] : [[]];
    });
    const patient = connect('p4');
    patient.handlers.booking_request({ bookingId: 7104, patientId: 501, patientName: 'Asha' });
    await flush();

    const tech = connect('s-mid');
    brought.add(3206);
    expect(() => tech.handlers.technician_online({ technicianId: 3206, technicianName: 'T' })).not.toThrow();

    release();
    await flush();
    bookingSocket.stopDispatch(7104);
  });

  test('a database failure during a request does not stop the server or block a retry', async () => {
    const failing = jest.spyOn(console, 'error').mockImplementation(() => {});
    db.execute.mockImplementation(async (sql) => {
      if (/document_required/.test(sql)) throw new Error('db down');
      return /SELECT booking_date/.test(sql) ? [[{ booking_date: TODAY }]] : [[]];
    });
    const patient = connect('p5');
    await requestDispatch(patient, 7105);
    expect(failing).toHaveBeenCalled();
    failing.mockRestore();

    wireDb();
    const tech = await online('s-retry', 3207);
    await requestDispatch(patient, 7105);
    expect(offersTo('s-retry')).toBe(1); // the failed attempt left no claim behind
    bookingSocket.stopDispatch(7105);
  });

  test('bad location data from a client does not crash the server', async () => {
    const tech = connect('s-bad');
    brought.add(3208);
    expect(() => tech.handlers.technician_online({ technicianId: 3208, technicianName: 'T', lat: 'x', lng: null })).not.toThrow();
    await flush();
  });
});

describe('a dropped connection mid-job', () => {
  async function onJob(socketId, technicianId, bookingId) {
    answers = [[/SELECT status FROM ip_bookings/, [{ status: 'pending' }]]];
    const tech = await online(socketId, technicianId);
    await tech.handlers.booking_accepted({ bookingId, technicianId, technicianName: 'T' });
    await flush();
    return tech;
  }

  test('keeps the job: reconnecting does not mark the technician idle', async () => {
    const tech = await onJob('s-drop', 3301, 7201);
    answers.push([/SELECT collection_status FROM ip_technician_collection/, [{ collection_status: 'en_route' }]]);
    tech.handlers.disconnect();
    db.execute.mockClear();

    await online('s-back', 3301);

    expect(calls(/task_status\s+= 'idle'|task_status = 'idle'/)).toHaveLength(0);
    expect(sent).not.toContainEqual([expect.anything(), 'booking_cancelled']);
    bookingSocket.freeTechnician(3301, 7201);
  });

  test.each([['completed'], ['cancelled'], ['handed_to_lab']])(
    'a job that became %s while away no longer keeps them busy', async (status) => {
      const tech = await onJob(`s-gone-${status}`, 3302, 7202);
      answers.push([/SELECT collection_status FROM ip_technician_collection/, [{ collection_status: status }]]);
      tech.handlers.disconnect();

      await online(`s-back-${status}`, 3302);

      expect(calls(/task_status\s+= 'idle'/).length).toBeGreaterThan(0);
    });

  test('a late disconnect from an old socket leaves the new connection alone', async () => {
    const oldSocket = await online('s-old', 3303);
    const newSocket = await online('s-new', 3303);

    oldSocket.handlers.disconnect();
    await requestDispatch(connect('p6'), 7203);

    expect(offersTo('s-new')).toBe(1);
    bookingSocket.stopDispatch(7203);
  });
});

describe('the time on accept', () => {
  test('moves to the accepting technician, and the old time is released', async () => {
    answers = [[/SELECT status FROM ip_bookings/, [{ status: 'pending' }]]];
    const tech = await online('s-sql', 3401);
    const patient = connect('p7');
    answers.push([/FROM ip_technician_slots\s+WHERE slot_id/, [{ technician_id: 3401 }]]);
    answers.push([/SELECT DISTINCT ts\.technician_id/, [{ technician_id: 3401 }]]);
    answers.push([/SELECT ias\.available_slot_id, ias\.technician_slot_id\s+FROM/, [{ available_slot_id: 66, technician_slot_id: 8 }]]);
    answers.push([/SELECT available_slot_id, visit_group_id/, [{ available_slot_id: 55, visit_group_id: null }]]);
    await requestDispatch(patient, 7301, { slotId: 2, appointmentTime: '10:00' });

    await tech.handlers.booking_accepted({ bookingId: 7301, technicianId: 3401, technicianName: 'T' });
    await flush();

    const [claim] = calls(/UPDATE ip_available_slots SET is_available = 0/);
    expect(claim[1]).toEqual([66]);
    expect(calls(/UPDATE ip_bookings SET available_slot_id/)[0][1]).toEqual([66, 7301, null]);
    expect(calls(/SET is_available = 1/)[0][1]).toEqual([55]);
    bookingSocket.freeTechnician(3401, 7301);
  });
});

describe('a slot picked again after no technician was found', () => {
  test('is saved on the booking before the search restarts', async () => {
    const tech = await online('s-pick', 3451, 13.05, 4); // works at the booking's branch
    answers = [
      [/FROM ip_available_slots ias[\s\S]*ip_technician_slot_branches/, [{ available_slot_id: 77, technician_slot_id: 9, slot_time: '11:30:00' }]],
      [/SELECT available_slot_id, visit_group_id/, [{ available_slot_id: 55, visit_group_id: 'VG-1' }]],
    ];
    await requestDispatch(connect('p10'), 7351, { branchId: 4, slotId: 3, slotChanged: true });

    expect(calls(/UPDATE ip_bookings SET available_slot_id/)[0][1]).toEqual([77, 7351, 'VG-1']);
    expect(offersTo('s-pick')).toBe(1);
    bookingSocket.stopDispatch(7351);
  });

  test('a normal request leaves the booking\'s time alone', async () => {
    const tech = await online('s-same', 3452);
    await requestDispatch(connect('p11'), 7352, { branchId: 4, slotId: 3 });
    expect(calls(/UPDATE ip_bookings SET available_slot_id/)).toHaveLength(0);
    bookingSocket.stopDispatch(7352);
  });
});

describe('a technician who missed heartbeats', () => {
  test('stays reachable by push, and comes back when heartbeats resume', async () => {
    const tech = await online('s-sleep', 3471);
    bookingSocket.markTechnicianOfflineStale(3471);
    await requestDispatch(connect('p12'), 7371);
    expect(offersTo('s-sleep')).toBe(0); // no live socket, so no socket offer
    bookingSocket.stopDispatch(7371);

    tech.handlers.technician_heartbeat({ technicianId: 3471 });
    await flush();
    await requestDispatch(connect('p13'), 7372);

    expect(offersTo('s-sleep')).toBe(1);
    expect(calls(/online_status = COALESCE/).some(c => c[1][0] === 'online')).toBe(true);
    bookingSocket.stopDispatch(7372);
  });
});

describe('the slot fallback', () => {
  const slotRows = [
    { technician_id: 3501, user_name: 'First' },
    { technician_id: 3502, user_name: 'Second' },
  ];

  test('moves past a technician with no push token to one who has it', async () => {
    answers = [
      [/FROM ip_technician_slots ts\s+JOIN ip_technicians t/, slotRows],
      [/SELECT fcm_token/, []],
    ];
    db.execute.mockImplementation(async (sql, params = []) => {
      if (/SELECT fcm_token/.test(sql)) return [params[0] === 3502 ? [{ fcm_token: 'tok' }] : []];
      for (const [re, rows] of answers) if (re.test(sql)) return [rows];
      return /SELECT booking_date/.test(sql) ? [[{ booking_date: TODAY }]] : [[]];
    });

    await requestDispatch(connect('p8'), 7401, { branchId: 4 });

    brought.add(3502); // left online by the offer, as a push-only entry
    expect(calls(/SELECT fcm_token/).map(c => c[1][0])).toEqual([3501, 3502]);
    expect(bookingSocket.stopDispatch(7401)).toBe(true);
  });

  test('never offers the job back to the technician who gave it up', async () => {
    answers = [
      [/FROM ip_technician_slots ts\s+JOIN ip_technicians t/, [slotRows[0]]],
      [/SELECT fcm_token/, [{ fcm_token: 'tok' }]],
    ];
    await requestDispatch(connect('p9'), 7402, { branchId: 4, excludeTechnicianId: 3501 });

    expect(calls(/SELECT fcm_token/)).toHaveLength(0);
    expect(bookingSocket.stopDispatch(7402)).toBe(false);
  });
});

describe('recoverPendingDispatches', () => {
  test('restarts the search for bookings due today with no technician', async () => {
    const tech = await online('s-rec', 3601);
    answers = [
      [/SELECT b\.booking_id\s+FROM ip_bookings b\s+WHERE b\.status IN/, [{ booking_id: 7501 }]],
      [/FROM ip_bookings b\s+JOIN ip_patients p/, [{
        booking_id: 7501, patient_id: 501, branch_id: null, booking_type: 'home_collection',
        patient_name: 'Asha', patient_lat: 13.05, patient_lng: 80.25,
      }]],
    ];

    await bookingSocket.recoverPendingDispatches();
    await flush();

    const [[sql, params]] = calls(/AND NOT EXISTS \(SELECT 1 FROM ip_technician_collection/);
    expect(sql).toMatch(/b\.booking_type = 'home_collection'/);
    expect(sql).toMatch(/SELECT MIN\(b2\.booking_id\)/);
    expect(params).toEqual([TODAY]);
    expect(offersTo('s-rec')).toBe(1);
    bookingSocket.stopDispatch(7501);
  });
});
