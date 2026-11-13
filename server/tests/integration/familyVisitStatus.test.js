// socket/bookingSocket.js — when a technician accepts, every active member of
// the visit becomes 'assigned'; a released booking returns to the status the
// scheduler or live dispatch can pick up; and restart recovery counts a family
// visit as one job.
jest.mock('../../config/db');
jest.mock('../../config/firebase', () => ({ messaging: null }));
jest.mock('../../services/customerPush', () => ({ sendToBookingOwner: jest.fn() }));
jest.mock('../../services/clientSync', () => ({ syncVisitCompletionToClient: jest.fn() }));
jest.mock('../../utils/dbLogger');
const db = require('../../config/db');
const bookingSocket = require('../../socket/bookingSocket');

const flush = () => new Promise(resolve => setTimeout(resolve, 20));
const callsMatching = (re) => db.execute.mock.calls.filter(c => re.test(c[0]));
const SIBLING_ASSIGN = /SET status = 'assigned', technician_id = \?, technician_name = \?,\s+branch_id = COALESCE\(\?, branch_id\), updated_at = NOW\(\)\s+WHERE visit_group_id = \?/;

beforeAll(() => { jest.spyOn(console, 'log').mockImplementation(() => {}); });
beforeEach(() => {
  db.execute.mockReset().mockImplementation(async (sql) => {
    if (/SELECT visit_group_id FROM ip_bookings/.test(sql)) return [[{ visit_group_id: 'VG-000900' }]];
    if (/INSERT INTO ip_technician_collection/.test(sql)) return [{ affectedRows: 1 }];
    return [[]];
  });
});

function connectFakeSocket() {
  const handlers = {};
  const socket = { id: 'sock1', on: (e, h) => { handlers[e] = h; }, once: () => {}, emit: () => {} };
  const room = { emit: () => {} };
  bookingSocket({ to: () => room }, socket);
  return handlers;
}

describe('technician accepts a family visit', () => {
  test('the other members become assigned, leaving out a cancelled member', async () => {
    connectFakeSocket().booking_accepted({ bookingId: 900, technicianId: 17, technicianName: 'Suresh' });
    await flush();

    const [[assign, params]] = callsMatching(SIBLING_ASSIGN);
    // Branch: the main booking's serving branch (none here — no dispatch state,
    // so COALESCE keeps each member's own).
    expect(params).toEqual([17, 'Suresh', null, 'VG-000900', 900]);
    expect(assign).toMatch(/branch_id = COALESCE\(\?, branch_id\)/);
    expect(assign).toMatch(/status != 'cancelled'/);

    const [, [job]]   = callsMatching(/INSERT INTO ip_technician_collection/);
    const [[patient]] = callsMatching(/JOIN ip_bookings b ON b\.booking_id = pb\.booking_id/);
    expect(job).toMatch(/b\.status != 'cancelled'/);
    expect(patient).toMatch(/b\.status != 'cancelled'/);
  });
});

describe('unassignAndRedispatch', () => {
  const TODAY = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });

  test('a future booking returns to scheduled, and a cancelled member stays cancelled', async () => {
    await bookingSocket.unassignAndRedispatch({
      bookingId: 900, allIds: [900, 901], technicianId: 17,
      notifyTitle: 't', notifyBody: 'b', notifyType: 'booking_unassigned',
    });

    const [[sql, params]] = callsMatching(/IF\(booking_date > \?, 'scheduled', 'pending'\)/);
    expect(params).toEqual([TODAY, 900, 901]);
    expect(sql).toMatch(/status != 'cancelled'/);
  });
});

describe('initDispatchState', () => {
  test('counts a family visit once', async () => {
    await bookingSocket.initDispatchState();

    const [[sql]] = callsMatching(/FROM\s+ip_bookings b\s+LEFT JOIN ip_available_slots/);
    expect(sql).toMatch(/SELECT MIN\(b2\.booking_id\)/);
  });
});
