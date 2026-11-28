// Technician History "Rescheduled" tab:
//   • bookingController.rescheduleBooking records each reschedule in
//     ip_booking_reschedules (best effort — never fails the reschedule).
//   • technicianController.getHistory returns those rows as 'rescheduled',
//     and falls back to the old query when the table doesn't exist yet.
jest.mock('../../config/db');
jest.mock('../../services/clientSync', () => ({
  syncBookingToClient: jest.fn().mockResolvedValue(undefined),
  syncVisitCompletionToClient: jest.fn(),
}));
jest.mock('../../socket/bookingSocket', () => ({
  triggerScheduledDispatch: jest.fn(),
  freeTechnician: jest.fn(),
  unassignAndRedispatch: jest.fn().mockResolvedValue(undefined),
  stopDispatch: jest.fn(),
  redispatchBooking: jest.fn(),
  forceTechnicianOffline: jest.fn(),
}));
jest.mock('../../utils/sms');
jest.mock('../../utils/dbLogger');

const db = require('../../config/db');
const { unassignAndRedispatch } = require('../../socket/bookingSocket');
const { createMockConnection } = require('../helpers/mockConnection');
const bookingController    = require('../../controllers/bookingController');
const technicianController = require('../../controllers/technicianController');

const mockRes = () => ({ json: jest.fn(), status: jest.fn().mockReturnThis() });

beforeEach(() => {
  jest.clearAllMocks();
  db.execute.mockReset().mockResolvedValue([[], {}]);
  db.getConnection.mockReset().mockResolvedValue(createMockConnection());
});

// The db.execute calls rescheduleBooking makes before the INSERT, in order.
function primeReschedule({ technicianId = 7 } = {}) {
  db.execute
    .mockResolvedValueOnce([[{                       // load booking
      booking_id: 500, booking_ref: 'BK500', status: 'confirmed',
      booking_type: 'home_collection', old_slot_id: 40,
      old_date: new Date('2026-11-16'), reschedule_count: 0, visit_group_id: null,
    }]])
    .mockResolvedValueOnce([technicianId            // technician assignment
      ? [{ collection_status: 'assigned', technician_id: technicianId }]
      : []])
    .mockResolvedValueOnce([[{                       // new slot
      available_slot_id: 55, technician_slot_id: null, lab_slot_id: null, slot_label: '10:00 AM',
    }]])
    .mockResolvedValueOnce([[{ old_date: '2026-11-16', slot_label: '06:30 PM' }]]); // old date/time
}

const rescheduleReq = () => ({
  params: { bookingId: '500' },
  body: { collectionDate: '2026-11-18', availableSlotId: 55 },
  user: { client_id: 1, id: 2, mobile: '9000000001', user_type: 'patient_user' },
});

describe('rescheduleBooking records the reschedule', () => {
  test('saves old and new date/time with the assigned technician', async () => {
    primeReschedule();
    const res = mockRes();
    await bookingController.rescheduleBooking(rescheduleReq(), res);

    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ success: true }));
    const insert = db.execute.mock.calls.find(([sql]) => /INSERT INTO ip_booking_reschedules/.test(sql));
    expect(insert).toBeDefined();
    expect(insert[1]).toEqual([500, 7, '2026-11-16', '06:30 PM', '2026-11-18', '10:00 AM']);
    expect(unassignAndRedispatch).toHaveBeenCalled();
  });

  test('a booking nobody had accepted is recorded with no technician', async () => {
    primeReschedule({ technicianId: null });
    const res = mockRes();
    await bookingController.rescheduleBooking(rescheduleReq(), res);

    const insert = db.execute.mock.calls.find(([sql]) => /INSERT INTO ip_booking_reschedules/.test(sql));
    expect(insert[1][1]).toBeNull();
    expect(unassignAndRedispatch).not.toHaveBeenCalled();
  });

  test('still succeeds when the table has not been created yet', async () => {
    primeReschedule();
    const missing = Object.assign(new Error("Table 'ip_booking_reschedules' doesn't exist"),
      { code: 'ER_NO_SUCH_TABLE' });
    db.execute.mockImplementation(async (sql) => {
      if (/INSERT INTO ip_booking_reschedules/.test(sql)) throw missing;
      return [[], {}];
    });
    const res = mockRes();
    await bookingController.rescheduleBooking(rescheduleReq(), res);

    expect(res.status).not.toHaveBeenCalled();
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ success: true }));
    expect(unassignAndRedispatch).toHaveBeenCalled();
  });
});

describe('getHistory includes rescheduled jobs', () => {
  test('queries the reschedule table for this technician', async () => {
    db.execute.mockResolvedValueOnce([[
      { booking_id: 500, collection_status: 'rescheduled', new_date: '2026-11-18', new_slot_label: '10:00 AM' },
    ]]);
    const res = mockRes();
    await technicianController.getHistory({ params: { technicianId: '7' } }, res);

    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toContain('ip_booking_reschedules');
    expect(sql).toContain("'rescheduled' AS collection_status");
    expect(params).toEqual(['7', '7', '7', '7']);
    expect(res.json).toHaveBeenCalledWith({
      success: true,
      data: [expect.objectContaining({ collection_status: 'rescheduled', new_date: '2026-11-18' })],
    });
  });

  test('without the table, returns completed/cancelled history as before', async () => {
    const missing = Object.assign(new Error('no table'), { code: 'ER_NO_SUCH_TABLE' });
    db.execute
      .mockRejectedValueOnce(missing)
      .mockResolvedValueOnce([[{ booking_id: 1, collection_status: 'completed' }]]);
    const res = mockRes();
    await technicianController.getHistory({ params: { technicianId: '7' } }, res);

    const [fallbackSql, fallbackParams] = db.execute.mock.calls[1];
    expect(fallbackSql).not.toContain('ip_booking_reschedules');
    expect(fallbackParams).toEqual(['7', '7', '7']);
    expect(res.status).not.toHaveBeenCalled();
    expect(res.json).toHaveBeenCalledWith({
      success: true,
      data: [expect.objectContaining({ collection_status: 'completed' })],
    });
  });

  test('Completed in History means handed to lab or later — in-progress jobs are not history', async () => {
    db.execute.mockResolvedValueOnce([[]]);
    await technicianController.getHistory({ params: { technicianId: '7' } }, mockRes());
    const [sql] = db.execute.mock.calls[0];
    expect(sql).toContain("'handed_to_lab_pending'");
    expect(sql).not.toContain("'sample_collected'");
    expect(sql).not.toContain("'collection_started'");
    expect(sql).not.toContain("'collected'"); // still on the Dashboard
  });

  test('other database errors are still reported', async () => {
    db.execute.mockRejectedValueOnce(Object.assign(new Error('boom'), { code: 'ER_PARSE_ERROR' }));
    const res = mockRes();
    await technicianController.getHistory({ params: { technicianId: '7' } }, res);
    expect(res.status).toHaveBeenCalledWith(500);
  });
});
