// Once a booking is accepted it is never dispatched again — the reported
// bug: an admin-created booking kept re-offering itself (with the beep) to
// the technician who had already accepted it.
jest.mock('../../config/db');
jest.mock('../../config/firebase', () => ({ messaging: null }));
jest.mock('../../services/customerPush', () => ({ sendToBookingOwner: jest.fn() }));
jest.mock('../../services/clientSync', () => ({ syncVisitCompletionToClient: jest.fn(), syncBookingToClient: jest.fn() }));
jest.mock('../../utils/dbLogger');
jest.mock('../../services/technicianBranches', () => ({
  technicianIdsAtBranch: jest.fn(async () => [4101, 4102]),
  placeholders: (ids) => ids.map(() => '?').join(', '),
}));
const db = require('../../config/db');
const bookingSocket = require('../../socket/bookingSocket');

const TODAY = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
const flush = () => new Promise(resolve => setTimeout(resolve, 20));

let answers; // [regex, rows] checked before the defaults
let sent;    // [socketId, event] sent through io.to()
const brought = new Set();
const io = { to: (id) => ({ emit: (event) => sent.push([id, event]) }) };

function wireDb() {
  db.execute.mockReset().mockImplementation(async (sql) => {
    for (const [re, rows] of answers) if (re.test(sql)) return [rows];
    if (/SELECT booking_date FROM ip_bookings/.test(sql)) return [[{ booking_date: TODAY }]];
    if (/SELECT status FROM ip_bookings/.test(sql)) return [[{ status: 'pending' }]];
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

async function online(socketId, technicianId) {
  const tech = connect(socketId);
  tech.handlers.technician_online({ technicianId, technicianName: `Tech ${technicianId}`, lat: 13.05, lng: 80.25 });
  brought.add(technicianId);
  await flush();
  return tech;
}

const request = async (bookingId) => {
  const patient = connect(`p-${bookingId}-${Math.random()}`);
  patient.handlers.booking_request({
    bookingId, patientId: 501, patientName: 'Anu', patientLat: 13.05, patientLng: 80.25,
  });
  await flush();
};
const offersTo = (socketId) => sent.filter(([id, e]) => id === socketId && e === 'booking_request').length;

beforeAll(() => {
  jest.spyOn(console, 'log').mockImplementation(() => {});
  jest.spyOn(console, 'warn').mockImplementation(() => {});
  jest.spyOn(console, 'error').mockImplementation(() => {});
  jest.spyOn(process.stdout, 'write').mockImplementation(() => true);
});
beforeEach(() => { answers = []; sent = []; wireDb(); });
afterEach(() => {
  const { handlers } = connect('cleanup');
  for (const technicianId of brought) handlers.technician_offline({ technicianId });
  brought.clear();
});

describe('dispatch never starts for a booking that already has its technician', () => {
  test('a technician job row exists → no request sent', async () => {
    answers = [[/AS tech_rows/, [{ status: 'pending', tech_rows: 1 }]]];
    await online('s-a', 4101);
    await request(71001);
    expect(offersTo('s-a')).toBe(0);
  });

  test.each(['assigned', 'en_route', 'sample_collected', 'otp_verified', 'cancelled'])(
    'booking status %s → no request sent', async (status) => {
      answers = [[/AS tech_rows/, [{ status, tech_rows: 0 }]]];
      await online('s-b', 4101);
      await request(71100 + status.length);
      expect(offersTo('s-b')).toBe(0);
    });

  test('a pending booking with no technician is still dispatched', async () => {
    answers = [[/AS tech_rows/, [{ status: 'pending', tech_rows: 0 }]]];
    await online('s-c', 4101);
    await request(71002);
    expect(offersTo('s-c')).toBe(1);
  });
});

describe('after an accept, a second trigger does not re-offer the job', () => {
  test('accept, then another dispatch request → no new request, no beep', async () => {
    const tech = await online('s-d', 4101);
    await request(71003);
    expect(offersTo('s-d')).toBe(1);

    tech.handlers.booking_accepted({ bookingId: 71003, technicianId: 4101, technicianName: 'Tech 4101' });
    await flush();

    sent = [];
    await request(71003); // e.g. the admin panel calling dispatch again
    expect(offersTo('s-d')).toBe(0);
  });
});

describe('the technician who holds the job accepting again', () => {
  test('closes the repeated popup instead of being ignored', async () => {
    const tech = await online('s-e', 4101);
    await request(71004);
    tech.handlers.booking_accepted({ bookingId: 71004, technicianId: 4101, technicianName: 'Tech 4101' });
    await flush();

    answers = [[/SELECT technician_id FROM ip_technician_collection/, [{ technician_id: 4101 }]]];
    tech.emitted.length = 0;
    tech.handlers.booking_accepted({ bookingId: 71004, technicianId: 4101, technicianName: 'Tech 4101' });
    await flush();

    expect(tech.emitted).toContainEqual(['booking_cancelled', { bookingId: 71004 }]);
    const markAccepted = db.execute.mock.calls.find(([sql]) =>
      /UPDATE ip_booking_requests\s+SET request_status = 'accepted'/.test(sql));
    expect(markAccepted).toBeDefined();
  });

  test('another technician accepting a taken job is still just blocked', async () => {
    const tech = await online('s-f', 4101);
    const other = await online('s-g', 4102);
    await request(71005);
    tech.handlers.booking_accepted({ bookingId: 71005, technicianId: 4101, technicianName: 'Tech 4101' });
    await flush();

    answers = [[/SELECT technician_id FROM ip_technician_collection/, [{ technician_id: 4101 }]]];
    other.handlers.booking_accepted({ bookingId: 71005, technicianId: 4102, technicianName: 'Tech 4102' });
    await flush();
    expect(other.emitted.find(([e]) => e === 'booking_cancelled')).toBeUndefined();
  });
});
