// Tests server/scheduler/logRetentionSweep.js — the daily batched-delete
// purge of the 7 database log tables (server/utils/dbLogger.js).
jest.mock('../../config/db');
const db = require('../../config/db');
const {
  runRetentionSweep, purgeTableBatched, LOG_TABLES,
} = require('../../scheduler/logRetentionSweep');

beforeEach(() => {
  db.execute.mockReset();
  delete process.env.LOG_RETENTION_DAYS;
});

describe('purgeTableBatched', () => {
  test('deletes in batches of 5000, looping until a partial batch signals completion', async () => {
    db.execute
      .mockResolvedValueOnce([{ affectedRows: 5000 }])
      .mockResolvedValueOnce([{ affectedRows: 5000 }])
      .mockResolvedValueOnce([{ affectedRows: 1234 }]); // partial batch -> stop

    const total = await purgeTableBatched('ip_dispatch_logs', 90);

    expect(total).toBe(5000 + 5000 + 1234);
    expect(db.execute).toHaveBeenCalledTimes(3);
    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toContain('DELETE FROM ip_dispatch_logs');
    expect(sql).toContain('WHERE created_at < (NOW() - INTERVAL ? DAY)');
    expect(sql).toContain('LIMIT ?');
    expect(params).toEqual([90, 5000]);
  });

  test('a table with nothing to purge makes exactly one DELETE call and stops', async () => {
    db.execute.mockResolvedValueOnce([{ affectedRows: 0 }]);
    const total = await purgeTableBatched('ip_login_otp_logs', 90);
    expect(total).toBe(0);
    expect(db.execute).toHaveBeenCalledTimes(1);
  });
});

describe('runRetentionSweep', () => {
  test('purges all 7 log tables', async () => {
    db.execute.mockResolvedValue([{ affectedRows: 0 }]);
    await runRetentionSweep();

    expect(LOG_TABLES).toEqual([
      'ip_dispatch_logs', 'ip_collection_logs', 'ip_otpinfo_logs',
      'ip_technician_logs', 'ip_login_otp_logs', 'ip_client_sync_logs',
      'ip_customer_push_logs',
    ]);
    const tablesTouched = db.execute.mock.calls.map(c => c[0].match(/DELETE FROM (\w+)/)[1]);
    expect(new Set(tablesTouched)).toEqual(new Set(LOG_TABLES));
  });

  test('defaults to 90-day retention when LOG_RETENTION_DAYS is not set', async () => {
    db.execute.mockResolvedValue([{ affectedRows: 0 }]);
    await runRetentionSweep();
    expect(db.execute.mock.calls[0][1][0]).toBe(90);
  });

  test('LOG_RETENTION_DAYS env var overrides the default', async () => {
    process.env.LOG_RETENTION_DAYS = '30';
    db.execute.mockResolvedValue([{ affectedRows: 0 }]);
    await runRetentionSweep();
    expect(db.execute.mock.calls[0][1][0]).toBe(30);
  });

  test('one table failing does not stop the others from being purged', async () => {
    let call = 0;
    db.execute.mockImplementation(() => {
      call++;
      if (call === 1) return Promise.reject(new Error('table locked'));
      return Promise.resolve([{ affectedRows: 0 }]);
    });

    await expect(runRetentionSweep()).resolves.toBeUndefined();
    // All 7 tables still attempted despite the first one rejecting.
    expect(db.execute).toHaveBeenCalledTimes(7);
  });
});
