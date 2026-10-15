// Confirms customerPush.js's writeLog() calls dbLogger.logCustomerPushEvent,
// even on the function's early-exit path (Firebase not initialised).
jest.mock('../../config/db');
jest.mock('../../config/firebase', () => ({ messaging: null }));
jest.mock('../../utils/dbLogger');
const dbLogger      = require('../../utils/dbLogger');
const customerPush  = require('../../services/customerPush');

beforeEach(() => jest.clearAllMocks());

test('sendToBookingOwner calls dbLogger.logCustomerPushEvent even when Firebase is not initialised', async () => {
  await customerPush.sendToBookingOwner(900, 'Title', 'Body', {});
  expect(dbLogger.logCustomerPushEvent).toHaveBeenCalled();
  const msg = dbLogger.logCustomerPushEvent.mock.calls.map(c => c[0]).join(' | ');
  expect(msg).toContain('900');
});
