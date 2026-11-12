// Tests scheduler/dispatchScheduler.js — a family visit moves together and
// dispatches once, and a Lab Visit moves to 'pending' without calling a
// technician.
jest.mock('../../config/db');
jest.mock('node-cron', () => ({ schedule: jest.fn() }));
jest.mock('../../socket/bookingSocket', () => ({
  triggerScheduledDispatch: jest.fn().mockResolvedValue(),
  redispatchBooking:        jest.fn().mockResolvedValue(),
}));
const db   = require('../../config/db');
const cron = require('node-cron');
const { triggerScheduledDispatch, redispatchBooking } = require('../../socket/bookingSocket');
const initDispatchScheduler = require('../../scheduler/dispatchScheduler');

const row = (over) => ({
  booking_id: 900, patient_id: 501, branch_id: 4, booking_type: 'home_collection', visit_group_id: null,
  collection_address: '12 MG Road', patient_lat: '11.3', patient_lng: '77.7', available_slot_id: 5,
  patient_name: 'Asha', patient_mobile: '9000000000', slot_id: 2, slot_time: '10:00:00',
  ...over,
});

// Mirrors the real claim: the first UPDATE takes the whole visit, so later
// rows of that visit find nothing left to claim.
function wireDb(rows, notStarted = []) {
  const claimed = new Set();
  db.execute.mockReset().mockImplementation(async (sql, params = []) => {
    if (/ip_booking_requests/.test(sql)) return [notStarted];
    if (/^\s*SELECT/.test(sql)) return [rows];
    const [bookingId, groupId] = params;
    const taken = rows.filter(r => (r.booking_id === bookingId || (groupId != null && r.visit_group_id === groupId))
      && !claimed.has(r.booking_id));
    taken.forEach(r => claimed.add(r.booking_id));
    return [{ affectedRows: taken.length }];
  });
}

let tick;
beforeAll(() => {
  jest.spyOn(console, 'log').mockImplementation(() => {});
  initDispatchScheduler({});
  tick = cron.schedule.mock.calls[0][1];
});
beforeEach(() => { triggerScheduledDispatch.mockReset().mockResolvedValue(); redispatchBooking.mockClear(); });

test('a single booking dispatches', async () => {
  wireDb([row()]);
  await tick();
  expect(triggerScheduledDispatch).toHaveBeenCalledTimes(1);
  expect(triggerScheduledDispatch.mock.calls[0][0]).toMatchObject({ bookingId: 900, bookingType: 'lab', appointmentTime: '10:00' });
});

test('a family visit dispatches once, on its first member', async () => {
  wireDb([
    row({ visit_group_id: 'VG-000900' }),
    row({ booking_id: 901, patient_id: 502, visit_group_id: 'VG-000900' }),
    row({ booking_id: 902, patient_id: 503, visit_group_id: 'VG-000900' }),
  ]);
  await tick();
  expect(triggerScheduledDispatch).toHaveBeenCalledTimes(1);
  expect(triggerScheduledDispatch.mock.calls[0][0].bookingId).toBe(900);
});

test('the first member cancelled: the next active member dispatches', async () => {
  // A cancelled member is not 'scheduled', so the query never returns it.
  wireDb([row({ booking_id: 901, patient_id: 502, visit_group_id: 'VG-000900' })]);
  await tick();
  expect(triggerScheduledDispatch.mock.calls[0][0].bookingId).toBe(901);
});

test('a Lab Visit moves to pending and calls no technician', async () => {
  wireDb([row({ booking_type: 'lab_visit' })]);
  await tick();
  expect(triggerScheduledDispatch).not.toHaveBeenCalled();
  const claim = db.execute.mock.calls.find(c => /SET status = 'pending'/.test(c[0]));
  expect(claim[1]).toEqual([900, null]);
});

test('a booking another tick already claimed is not dispatched', async () => {
  wireDb([row()]);
  await tick();
  await tick();
  expect(triggerScheduledDispatch).toHaveBeenCalledTimes(1);
});

test('a failed dispatch is handed back for the next tick, and the rest still go out', async () => {
  const errors = jest.spyOn(console, 'error').mockImplementation(() => {});
  wireDb([row(), row({ booking_id: 901, patient_id: 502 })]);
  triggerScheduledDispatch.mockRejectedValueOnce(new Error('db down'));

  await tick();

  expect(triggerScheduledDispatch).toHaveBeenCalledTimes(2);
  const handedBack = db.execute.mock.calls.find(c => /SET status = 'scheduled'/.test(c[0]));
  expect(handedBack[1]).toEqual([900, null]);
  errors.mockRestore();
});

test('a same-day booking the app never dispatched is picked up, once', async () => {
  wireDb([], [{ booking_id: 950 }]);
  await tick();
  await tick();
  expect(redispatchBooking).toHaveBeenCalledTimes(1);
  expect(redispatchBooking).toHaveBeenCalledWith(950, { reason: 'app_did_not_start_dispatch' });
});
