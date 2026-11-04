// Tests server/services/partialPaymentReason.js — stored on the booking, or on
// every booking of a family visit; a blank reason (a full payment) changes
// nothing.
jest.mock('../../config/db');
const db = require('../../config/db');
const { savePartialReason } = require('../../services/partialPaymentReason');

beforeEach(() => db.execute.mockReset().mockResolvedValue([{ affectedRows: 1 }]));

describe('savePartialReason', () => {
  test('saves the trimmed reason, covering the booking and its whole visit', async () => {
    await savePartialReason(900, '  Short of cash today  ');
    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toMatch(/b\.visit_group_id = primary_b\.visit_group_id/);
    expect(params).toEqual([900, 'Short of cash today', 900]);
  });

  test('a booking with no visit group only updates itself', async () => {
    await savePartialReason(900, 'Short of cash');
    expect(db.execute.mock.calls[0][0]).toMatch(/primary_b\.visit_group_id IS NOT NULL/);
  });

  test.each([[undefined], [null], [''], ['   ']])('blank reason (%p) does nothing', async (reason) => {
    await savePartialReason(900, reason);
    expect(db.execute).not.toHaveBeenCalled();
  });

  test('reason is cut to 255 characters', async () => {
    await savePartialReason(900, 'x'.repeat(300));
    expect(db.execute.mock.calls[0][1][1]).toHaveLength(255);
  });
});
