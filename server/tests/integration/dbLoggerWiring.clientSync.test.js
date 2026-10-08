// Confirms clientSync.js's writeLog() calls dbLogger.logClientSyncEvent,
// even on the function's early-exit path (no CLIENT_BOOKING_URL configured).
jest.mock('../../config/db');
jest.mock('../../config/settings');
jest.mock('../../config/firebase', () => ({ messaging: null }));
jest.mock('../../utils/dbLogger');
const settings   = require('../../config/settings');
const dbLogger   = require('../../utils/dbLogger');
const clientSync = require('../../services/clientSync');

beforeEach(() => jest.clearAllMocks());

test('syncBookingToClient calls dbLogger.logClientSyncEvent even on its early-exit path', async () => {
  settings.getBool = jest.fn().mockReturnValue(true);
  delete process.env.CLIENT_BOOKING_URL; // forces the early "URL not set" exit, right after one writeLog() call

  await clientSync.syncBookingToClient(900, { mobile: '9876543210', type: 'technician', technicianId: 17 });

  expect(dbLogger.logClientSyncEvent).toHaveBeenCalled();
});
