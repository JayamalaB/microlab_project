// POST /api/bookings/:id/dispatch (admin portal) refuses a booking that
// already has a technician, even while its status still reads pending.
jest.mock('../../config/db');
jest.mock('../../services/clientSync', () => ({ syncBookingToClient: jest.fn().mockResolvedValue(undefined) }));
jest.mock('../../socket/bookingSocket', () => ({
  triggerScheduledDispatch: jest.fn(), freeTechnician: jest.fn(), unassignAndRedispatch: jest.fn(),
  stopDispatch: jest.fn(), redispatchBooking: jest.fn(),
}));
jest.mock('../../utils/dbLogger');

const db = require('../../config/db');
const { triggerScheduledDispatch } = require('../../socket/bookingSocket');
const bookingController = require('../../controllers/bookingController');

const mockRes = () => ({ json: jest.fn(), status: jest.fn().mockReturnThis() });
const row = (over) => ({
  booking_id: 600, patient_id: 2, branch_id: 3, booking_type: 'home_collection', status: 'pending',
  collection_address: 'x', patient_lat: 13, patient_lng: 80, patient_name: 'Anu', patient_mobile: '9',
  slot_id: 1, slot_time: '10:00:00', tech_rows: 0, ...over,
});

beforeAll(() => {
  jest.spyOn(console, 'log').mockImplementation(() => {});
  jest.spyOn(console, 'warn').mockImplementation(() => {});
});
beforeEach(() => { jest.clearAllMocks(); db.execute.mockReset(); });

test('a booking that already has a technician is not dispatched again', async () => {
  db.execute.mockResolvedValueOnce([[row({ tech_rows: 1 })]]);
  const res = mockRes();
  await bookingController.dispatchBooking({ params: { bookingId: '600' }, ip: '-' }, res);
  expect(res.status).toHaveBeenCalledWith(409);
  expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ code: 'ALREADY_ASSIGNED' }));
  expect(triggerScheduledDispatch).not.toHaveBeenCalled();
});

test('a pending booking with no technician is dispatched', async () => {
  db.execute.mockResolvedValueOnce([[row({})]]);
  const res = mockRes();
  await bookingController.dispatchBooking({ params: { bookingId: '600' }, ip: '-' }, res);
  expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ success: true }));
  expect(triggerScheduledDispatch).toHaveBeenCalled();
});
