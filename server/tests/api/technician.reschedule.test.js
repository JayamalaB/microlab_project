// Technician-initiated reschedule (technicianController.rescheduleAssignedBooking
// and getRescheduleSlots): the technician moves an accepted job to one of their
// own free times and KEEPS it — booking status is not changed, nothing is
// re-dispatched, and the move is recorded as rescheduled_by = 'technician'.
jest.mock('../../config/db');
jest.mock('../../socket/bookingSocket', () => ({
  forceTechnicianOffline: jest.fn(),
  unassignAndRedispatch: jest.fn(),
  moveTechnicianWindow: jest.fn(),
}));
jest.mock('../../services/clientSync', () => ({
  syncBookingToClient: jest.fn().mockResolvedValue(undefined),
  syncVisitCompletionToClient: jest.fn(),
}));
jest.mock('../../services/customerPush', () => ({
  sendToBookingOwner: jest.fn().mockResolvedValue(undefined),
}));
jest.mock('../../utils/sms');
jest.mock('../../utils/dbLogger');

const db = require('../../config/db');
const { moveTechnicianWindow, unassignAndRedispatch } = require('../../socket/bookingSocket');
const { syncBookingToClient } = require('../../services/clientSync');
const { sendToBookingOwner } = require('../../services/customerPush');
const { createMockConnection } = require('../helpers/mockConnection');
const technicianController = require('../../controllers/technicianController');

const mockRes = () => ({ json: jest.fn(), status: jest.fn().mockReturnThis() });
const req = (body = { bookingId: 500, availableSlotId: 77 }) =>
  ({ body, user: { id: 7, mobile: '9000000002', role: 'technician' } });

let conn;
beforeEach(() => {
  jest.clearAllMocks();
  db.execute.mockReset().mockResolvedValue([[], {}]);
  conn = createMockConnection();
  // claim of the new time succeeds by default
  conn.execute.mockImplementation(async (sql) =>
    /SET is_available = 0/.test(sql) ? [{ affectedRows: 1 }] : [[], {}]);
  db.getConnection.mockReset().mockResolvedValue(conn);
});

const job = (over = {}) => ({
  collection_status: 'assigned', booking_ref: 'BK500', reference_no: '180851',
  booking_type: 'home_collection', visit_group_id: null, reschedule_count: 0,
  old_slot_id: 40, old_date: '2026-11-16', old_slot_label: '06:30 PM', ...over,
});
const freeSlot = {
  available_slot_id: 77, technician_slot_id: 12, slot_id: 3, duration_minutes: 30,
  slot_date: '2026-11-18', slot_time: '10:00', slot_label: '10:00 AM',
};

describe('rescheduleAssignedBooking', () => {
  test('moves the job, keeps the technician, and records it', async () => {
    db.execute
      .mockResolvedValueOnce([[job()]])      // the job
      .mockResolvedValueOnce([[freeSlot]]);  // the new time
    const res = mockRes();
    await technicianController.rescheduleAssignedBooking(req(), res);

    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      success: true, new_date: '2026-11-18', new_slot: '10:00 AM',
    }));
    const sqls = conn.execute.mock.calls.map(c => c[0]);
    // booking moved, status NOT touched
    const bookingUpdate = sqls.find(s => /UPDATE ip_bookings/.test(s));
    expect(bookingUpdate).toMatch(/booking_date = \?/);
    expect(bookingUpdate).not.toMatch(/status/);
    // technician keeps the job on the new date
    expect(sqls.some(s => /UPDATE ip_technician_collection SET collection_date/.test(s))).toBe(true);
    expect(conn.commit).toHaveBeenCalled();
    // not re-dispatched
    expect(unassignAndRedispatch).not.toHaveBeenCalled();

    const insert = db.execute.mock.calls.find(([s]) => /INSERT INTO ip_booking_reschedules/.test(s));
    expect(insert[0]).toContain("'technician'");
    expect(insert[1]).toEqual([500, 7, '2026-11-16', '06:30 PM', '2026-11-18', '10:00 AM']);
    expect(moveTechnicianWindow).toHaveBeenCalledWith(expect.objectContaining({
      technicianId: 7, bookingId: 500, slotDate: '2026-11-18', slotTime: '10:00', durationMinutes: 30,
    }));
    expect(sendToBookingOwner).toHaveBeenCalledWith(500, 'Booking rescheduled', expect.stringContaining('10:00 AM'), expect.any(Object));
    expect(syncBookingToClient).toHaveBeenCalledWith(500, expect.objectContaining({ action: 'reschedule', type: 'technician' }));
  });

  test('a family visit moves every member', async () => {
    db.execute
      .mockResolvedValueOnce([[job({ visit_group_id: 'VG1' })]])
      .mockResolvedValueOnce([[freeSlot]])
      .mockResolvedValueOnce([[{ booking_id: 500 }, { booking_id: 501 }]]);
    const res = mockRes();
    await technicianController.rescheduleAssignedBooking(req(), res);

    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ success: true, members_updated: 2 }));
    const update = conn.execute.mock.calls.find(([s]) => /UPDATE ip_bookings/.test(s));
    expect(update[1]).toEqual(['2026-11-18', 77, 500, 501]);
  });

  test('not allowed once the journey has started', async () => {
    db.execute.mockResolvedValueOnce([[job({ collection_status: 'en_route' })]]);
    const res = mockRes();
    await technicianController.rescheduleAssignedBooking(req(), res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('not allowed on someone else\'s job', async () => {
    db.execute.mockResolvedValueOnce([[]]);
    const res = mockRes();
    await technicianController.rescheduleAssignedBooking(req(), res);
    expect(res.status).toHaveBeenCalledWith(404);
  });

  test('stops at the reschedule limit', async () => {
    db.execute.mockResolvedValueOnce([[job({ reschedule_count: 2 })]]);
    const res = mockRes();
    await technicianController.rescheduleAssignedBooking(req(), res);
    expect(res.status).toHaveBeenCalledWith(400);
  });

  test('a time that is not this technician\'s free time is refused', async () => {
    db.execute
      .mockResolvedValueOnce([[job()]])
      .mockResolvedValueOnce([[]]); // slot lookup finds nothing
    const res = mockRes();
    await technicianController.rescheduleAssignedBooking(req(), res);
    expect(res.status).toHaveBeenCalledWith(409);
    expect(db.getConnection).not.toHaveBeenCalled();
  });

  test('a time taken a moment ago rolls back and changes nothing', async () => {
    db.execute
      .mockResolvedValueOnce([[job()]])
      .mockResolvedValueOnce([[freeSlot]]);
    conn.execute.mockImplementation(async (sql) =>
      /SET is_available = 0/.test(sql) ? [{ affectedRows: 0 }] : [[], {}]);
    const res = mockRes();
    await technicianController.rescheduleAssignedBooking(req(), res);

    expect(res.status).toHaveBeenCalledWith(409);
    expect(conn.rollback).toHaveBeenCalled();
    expect(conn.commit).not.toHaveBeenCalled();
    expect(conn.execute.mock.calls.some(([s]) => /UPDATE ip_bookings/.test(s))).toBe(false);
  });

  test('still succeeds when the history table is missing', async () => {
    db.execute.mockImplementation(async (sql) => {
      if (/INSERT INTO ip_booking_reschedules/.test(sql)) {
        throw Object.assign(new Error('no table'), { code: 'ER_NO_SUCH_TABLE' });
      }
      if (/FROM ip_technician_collection tc/.test(sql)) return [[job()]];
      if (/FROM ip_available_slots av/.test(sql)) return [[freeSlot]];
      return [[], {}];
    });
    const res = mockRes();
    await technicianController.rescheduleAssignedBooking(req(), res);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ success: true }));
  });

  test('bookingId and availableSlotId are required', async () => {
    const res = mockRes();
    await technicianController.rescheduleAssignedBooking(req({ bookingId: 500 }), res);
    expect(res.status).toHaveBeenCalledWith(400);
  });
});

describe('getRescheduleSlots', () => {
  test('returns only this technician\'s free times, grouped by date', async () => {
    db.execute.mockResolvedValueOnce([[
      { available_slot_id: 77, slot_date: '2026-11-18', time: '10:00', label: '10:00 AM' },
      { available_slot_id: 78, slot_date: '2026-11-18', time: '10:30', label: '10:30 AM' },
      { available_slot_id: 90, slot_date: '2026-11-19', time: '09:00', label: '09:00 AM' },
    ]]);
    const res = mockRes();
    await technicianController.getRescheduleSlots({ user: { id: 7 } }, res);

    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toContain('ts.technician_id = ?');
    expect(sql).toContain('av.is_available  = 1');
    expect(params[0]).toBe(7);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      success: true,
      data: [
        { date: '2026-11-18', slots: [
          { available_slot_id: 77, time: '10:00', label: '10:00 AM' },
          { available_slot_id: 78, time: '10:30', label: '10:30 AM' },
        ] },
        { date: '2026-11-19', slots: [{ available_slot_id: 90, time: '09:00', label: '09:00 AM' }] },
      ],
    }));
  });
});
