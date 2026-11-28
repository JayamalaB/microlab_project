// ip_bookings.status follows every technician step:
//   assigned → en_route → arrived → collection_started → sample_collected →
//   otp_verified → handed_to_lab_pending → handed_to_lab
// and the customer can't cancel once the technician is on the way.
jest.mock('../../config/db');
jest.mock('../../services/clientSync', () => ({
  syncBookingToClient: jest.fn().mockResolvedValue(undefined),
  syncVisitCompletionToClient: jest.fn(),
}));
jest.mock('../../socket/bookingSocket', () => ({
  triggerScheduledDispatch: jest.fn(), freeTechnician: jest.fn(), unassignAndRedispatch: jest.fn(),
  stopDispatch: jest.fn(), redispatchBooking: jest.fn(), forceTechnicianOffline: jest.fn(),
}));
jest.mock('../../utils/sms');
jest.mock('../../utils/dbLogger');

const db = require('../../config/db');
const bookingController  = require('../../controllers/bookingController');
const feedbackController = require('../../controllers/feedbackController');

const mockRes = () => ({ json: jest.fn(), status: jest.fn().mockReturnThis() });

beforeEach(() => {
  jest.clearAllMocks();
  db.execute.mockReset().mockResolvedValue([[], {}]);
});

const cancelReq = () => ({
  params: { bookingId: '500' }, body: { reason: 'Changed plans' },
  user: { client_id: 1, id: 2, mobile: '9000000001', user_type: 'patient_user' },
});
const booking = (status) => ({
  booking_id: 500, booking_ref: 'BK500', status, booking_type: 'home_collection',
  total_amount: 480, available_slot_id: 40, booking_date: new Date('2026-11-30'),
  patient_id: 2, visit_group_id: null, amount_paid: 0, items_total: 330,
});

describe('customer cancel — not allowed once the technician is on the way', () => {
  test.each(['en_route', 'arrived', 'collection_started', 'sample_collected', 'collected', 'otp_verified'])(
    'booking status %s is refused', async (status) => {
      db.execute.mockResolvedValueOnce([[booking(status)]]);
      const res = mockRes();
      await bookingController.cancelBooking(cancelReq(), res);
      expect(res.status).toHaveBeenCalledWith(400);
      expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ code: 'TECHNICIAN_ON_THE_WAY' }));
    });

  test('also refused when only the technician step says en_route (status still assigned)', async () => {
    db.execute
      .mockResolvedValueOnce([[booking('assigned')]])
      .mockResolvedValueOnce([[{ collection_status: 'en_route', arrived_at: null, technician_id: 7 }]]);
    const res = mockRes();
    await bookingController.cancelBooking(cancelReq(), res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ code: 'TECHNICIAN_ON_THE_WAY' }));
  });
});

describe('admin status update uses the same values as the technician app', () => {
  const adminReq = (status) => ({ params: { bookingId: '500' }, body: { status } });
  const bookingStatusWrite = () =>
    db.execute.mock.calls.find(([sql]) => /UPDATE ip_bookings SET status = \?/.test(sql));
  const collectionWrite = () =>
    db.execute.mock.calls.find(([sql]) => /UPDATE ip_technician_collection\s+SET collection_status = \?/.test(sql));

  test.each([
    ['en_route',              'en_route',              'en_route'],
    ['arrived',               'arrived',               'arrived'],
    ['collection_started',    'collection_started',    'collection_started'],
    ['sample_collected',      'sample_collected',      'sample_collected'],
    ['otp_verified',          'otp_verified',          'otp_verified'],
    ['handed_to_lab_pending', 'handed_to_lab_pending', 'handed_to_lab_pending'],
    ['submitted_to_lab',      'handed_to_lab',         'handed_to_lab'],
  ])('%s → ip_bookings %s, collection %s', async (status, bookingStatus, collectionStatus) => {
    db.execute.mockImplementation(async (sql) =>
      /SELECT tc.technician_id FROM ip_technician_collection/.test(sql) ? [[{ technician_id: 7 }]] : [[], {}]);
    const res = mockRes();
    await bookingController.updateAdminStatus(adminReq(status), res);
    expect(res.json).toHaveBeenCalledWith({ success: true, status });
    expect(bookingStatusWrite()[1]).toEqual([bookingStatus, '500']);
    expect(collectionWrite()[1]).toEqual([collectionStatus, '500']);
  });

  test('processing keeps the technician part finished (not back to an active job)', async () => {
    db.execute.mockImplementation(async (sql) =>
      /SELECT tc.technician_id FROM ip_technician_collection/.test(sql) ? [[{ technician_id: 7 }]] : [[], {}]);
    await bookingController.updateAdminStatus(adminReq('processing'), mockRes());
    expect(collectionWrite()[1]).toEqual(['handed_to_lab', '500']);
  });
});

describe('feedback opens from sample collected onward', () => {
  test.each(['sample_collected', 'otp_verified', 'handed_to_lab'])('allowed at %s', async (status) => {
    db.execute.mockResolvedValueOnce([[{ booking_id: 500, status }]]);
    const res = mockRes();
    await feedbackController.submitFeedback?.({
      params: { bookingId: '500' }, body: { rating: 5 },
      user: { client_id: 1, id: 2, mobile: '9000000001' },
    }, res);
    // Whatever happens next, it must not be the "only after collection" refusal.
    const refused = res.json.mock.calls.some(([b]) => /only be submitted once/.test(b?.message ?? ''));
    expect(refused).toBe(false);
  });
});
