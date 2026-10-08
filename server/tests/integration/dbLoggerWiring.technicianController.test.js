// Confirms technicianController.js's tlog() calls dbLogger.logTechnicianEvent.
jest.mock('../../config/db');
jest.mock('../../socket/bookingSocket', () => ({
  forceTechnicianOffline: jest.fn(), unassignAndRedispatch: jest.fn(),
}));
jest.mock('../../services/clientSync', () => ({ syncVisitCompletionToClient: jest.fn() }));
jest.mock('../../utils/sms');
jest.mock('../../utils/dbLogger');
const db       = require('../../config/db');
const dbLogger = require('../../utils/dbLogger');
const technicianController = require('../../controllers/technicianController');

beforeEach(() => jest.clearAllMocks());

test('getHistory calls dbLogger.logTechnicianEvent', async () => {
  db.execute.mockReset().mockResolvedValue([[]]);
  const req = { params: { technicianId: '901' } };
  const res = { json: jest.fn(), status: jest.fn().mockReturnThis() };
  await technicianController.getHistory(req, res);

  expect(dbLogger.logTechnicianEvent).toHaveBeenCalled();
  const msg = dbLogger.logTechnicianEvent.mock.calls.map(c => c[0]).join(' | ');
  expect(msg).toContain('getHistory');
});
