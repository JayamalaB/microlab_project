// Tests server/utils/dbLogger.js — the additive DB-copy layer behind the 7
// existing .log file loggers (see migrations/create_log_tables.sql for the
// table shapes this mirrors).
//
// dbLogger defaults to disabled under NODE_ENV=test (Jest sets this
// automatically) specifically so its own fire-and-forget db.execute() calls
// never consume slots from the mockResolvedValueOnce() queues that dozens of
// *other*, unrelated existing tests set up for their own business-logic
// assertions — see the long comment on dbLoggingEnabled in dbLogger.js for
// the regression this prevents. Every test below explicitly re-enables it.
jest.mock('../../config/db');
const db       = require('../../config/db');
const dbLogger = require('../../utils/dbLogger');

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([{ affectedRows: 1 }, undefined]);
  dbLogger._setEnabledForTesting(true);
  // Drain any rows a previous test left buffered (dbLogger's buffers are
  // module-level, so they persist across tests in this file) before each
  // test starts, so assertions below only ever see what that test itself
  // buffered.
  dbLogger.flushTable('ip_dispatch_logs');
  dbLogger.flushTable('ip_collection_logs');
  db.execute.mockClear();
});
afterEach(() => {
  dbLogger._setEnabledForTesting(false); // restore the real default for any other file
});

describe('disabled-by-default guard', () => {
  test('a fresh require would be disabled under NODE_ENV=test (the real production default)', () => {
    // Simulates what every OTHER test file in this suite relies on: without
    // explicitly calling _setEnabledForTesting(true), nothing reaches db.execute.
    dbLogger._setEnabledForTesting(false);
    dbLogger.logDispatchEvent(123, 'REQUEST', 'patient=1');
    dbLogger.flushTable('ip_dispatch_logs');
    expect(db.execute).not.toHaveBeenCalled();
  });
});

describe('extraction / masking helpers', () => {
  test('maskMobile keeps only the last 4 digits', () => {
    expect(dbLogger.maskMobile('9876543210')).toBe('******3210');
  });
  test('maskMobile handles short/missing input safely', () => {
    expect(dbLogger.maskMobile(null)).toBeNull();
    expect(dbLogger.maskMobile('123')).toBe('****');
  });
  test('maskMobilesInText redacts every 10-digit Indian mobile found in free text', () => {
    const out = dbLogger.maskMobilesInText('mobile=9876543210 creator_mobile=9123456780 ok');
    expect(out).not.toContain('9876543210');
    expect(out).not.toContain('9123456780');
    expect(out).toContain('******3210');
    expect(out).toContain('******6780');
  });
  test('extractBookingId matches booking_id=, bookingId=, and booking= forms', () => {
    expect(dbLogger.extractBookingId('booking_id=70102 foo')).toBe(70102);
    expect(dbLogger.extractBookingId('parsed bookingId=70103 ok')).toBe(70103);
    expect(dbLogger.extractBookingId('visit_group=VG1 booking=70104')).toBe(70104);
    expect(dbLogger.extractBookingId('no id here')).toBeNull();
  });
  test('extractTechnicianId matches technician_id=, technicianId=, and tech_id= forms', () => {
    expect(dbLogger.extractTechnicianId('technician_id=501')).toBe(501);
    expect(dbLogger.extractTechnicianId('tech_id=502')).toBe(502);
    expect(dbLogger.extractTechnicianId('no id here')).toBeNull();
  });
});

describe('ip_dispatch_logs — buffered writer (dlog()/log() call this)', () => {
  test('logDispatchEvent buffers rather than inserting immediately', () => {
    dbLogger.logDispatchEvent(70102, 'REQUEST', 'patient=501 branch=3');
    expect(db.execute).not.toHaveBeenCalled(); // still buffered, not yet flushed
  });

  test('flushTable sends one batched multi-row INSERT with the buffered rows', () => {
    dbLogger.logDispatchEvent(70102, 'REQUEST', 'patient=501 branch=3');
    dbLogger.logDispatchEvent(70102, 'DATE_OK', 'proceeding with live dispatch');
    dbLogger.flushTable('ip_dispatch_logs');

    expect(db.execute).toHaveBeenCalledTimes(1);
    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toContain('INSERT INTO ip_dispatch_logs');
    expect(sql).toContain('booking_id,tag,details');
    // 2 rows x 3 columns = 6 flattened params
    expect(params).toEqual([
      70102, 'REQUEST', 'patient=501 branch=3',
      70102, 'DATE_OK', 'proceeding with live dispatch',
    ]);
  });

  test('flushing an empty buffer is a safe no-op', () => {
    dbLogger.flushTable('ip_dispatch_logs');
    expect(db.execute).not.toHaveBeenCalled();
  });

  test('mobile numbers embedded in dispatch details are masked before buffering', () => {
    dbLogger.logDispatchEvent(70102, 'REQUEST', 'patient=501 mobile=9876543210');
    dbLogger.flushTable('ip_dispatch_logs');
    const [, params] = db.execute.mock.calls[0];
    expect(params[2]).not.toContain('9876543210');
    expect(params[2]).toContain('******3210');
  });
});

describe('ip_collection_logs — buffered writer, fields parsed from clog() messages', () => {
  test('booking_id/technician_id/event/level are correctly extracted from a real-shaped message', () => {
    dbLogger.logCollectionEvent('[collection_started] running UPDATE for booking_id=70102');
    dbLogger.flushTable('ip_collection_logs');

    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toContain('INSERT INTO ip_collection_logs');
    expect(sql).toContain('booking_id,technician_id,event,level,message');
    const [bookingId, technicianId, event, level, message] = params;
    expect(bookingId).toBe(70102);
    expect(technicianId).toBeNull(); // not present in this particular message
    expect(event).toBe('collection_started');
    expect(level).toBe('info');
    expect(message).toContain('booking_id=70102');
  });

  test('error-shaped messages are classified level=error', () => {
    dbLogger.logCollectionEvent('[sample_collected] DB ERROR — booking_id=70102 error="x"');
    dbLogger.flushTable('ip_collection_logs');
    const [, params] = db.execute.mock.calls[0];
    expect(params[3]).toBe('error');
  });

  test('warning-shaped messages are classified level=warn', () => {
    dbLogger.logCollectionEvent('[sample_collected] WARNING: 0 rows affected — no row with booking_id=70102');
    dbLogger.flushTable('ip_collection_logs');
    const [, params] = db.execute.mock.calls[0];
    expect(params[3]).toBe('warn');
  });

  test('both booking_id and technician_id populate when both are present', () => {
    dbLogger.logCollectionEvent('[collection_started] parsed bookingId=70102 technicianId=501');
    dbLogger.flushTable('ip_collection_logs');
    const [, params] = db.execute.mock.calls[0];
    expect(params[0]).toBe(70102);
    expect(params[1]).toBe(501);
  });
});

describe('direct-insert tables (otpinfo/technician/otp/client_sync/customer_push)', () => {
  test('logOtpInfoEvent inserts into ip_otpinfo_logs with extracted IDs', () => {
    dbLogger.logOtpInfoEvent('[GENERATE] DB lookup OK — booking_id=900 tech_id=17 mobile=9876543210');
    expect(db.execute).toHaveBeenCalledTimes(1);
    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toContain('INSERT INTO ip_otpinfo_logs');
    expect(params[0]).toBe(900);  // booking_id
    expect(params[1]).toBe(17);   // technician_id
    expect(params[2]).toBe('GENERATE'); // event
  });

  test('logTechnicianEvent inserts into ip_technician_logs', () => {
    dbLogger.logTechnicianEvent('[cancelAssignedBooking] technician_id=17 booking_id=900 reason=vehicle_issue');
    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toContain('INSERT INTO ip_technician_logs');
    expect(params[0]).toBe(17);  // technician_id
    expect(params[1]).toBe(900); // booking_id
    expect(params[2]).toBe('cancelAssignedBooking');
  });

  test('logOtpEvent inserts into ip_login_otp_logs and never receives a plaintext OTP (source already masks it)', () => {
    dbLogger.logOtpEvent('[sendOtp] OTP stored — value=**** expires=2026-01-01 10:00:00 IST');
    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toContain('INSERT INTO ip_login_otp_logs');
    expect(params.join(' ')).not.toMatch(/value=\d{4}\b/);
  });

  test('logClientSyncEvent extracts booking_id, technician_id, initiator_type, and action', () => {
    dbLogger.logClientSyncEvent('[clientSync] sending — action=collection_photo_added technician_id=17 booking_id=900 type=technician');
    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toContain('INSERT INTO ip_client_sync_logs');
    expect(params[0]).toBe(900);               // booking_id
    expect(params[1]).toBe(17);                // technician_id
    expect(params[2]).toBe('technician');       // initiator_type
    expect(params[3]).toBe('collection_photo_added'); // action
  });

  test('logCustomerPushEvent extracts booking_id, title, and status', () => {
    dbLogger.logCustomerPushEvent('[customerPush] ✅ sent — booking_id=900 mobile=9876543210');
    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toContain('INSERT INTO ip_customer_push_logs');
    expect(params[0]).toBe(900); // booking_id
    expect(params[3]).toBe('sent'); // status
  });

  test('logCustomerPushEvent captures the title field from the call() line', () => {
    dbLogger.logCustomerPushEvent('[customerPush] called — booking_id=900 title="Technician Assigned 🧑‍⚕️"');
    const [, params] = db.execute.mock.calls[0];
    expect(params[2]).toContain('Technician Assigned');
  });
});

describe('error resilience — a DB failure must never break the caller', () => {
  test('insertLog swallows a rejected db.execute without throwing', () => {
    db.execute.mockReset().mockRejectedValue(new Error('pool exhausted'));
    expect(() => dbLogger.logOtpInfoEvent('[GENERATE] anything')).not.toThrow();
  });

  test('a synchronous db.execute throw inside insertLog is caught, not propagated', () => {
    db.execute.mockReset().mockImplementation(() => { throw new Error('boom'); });
    expect(() => dbLogger.logTechnicianEvent('[getHistory] START technician_id=17')).not.toThrow();
  });

  test('flushTable swallows a rejected batched insert without throwing', () => {
    db.execute.mockReset().mockRejectedValue(new Error('pool exhausted'));
    dbLogger.logDispatchEvent(1, 'REQUEST', 'x');
    expect(() => dbLogger.flushTable('ip_dispatch_logs')).not.toThrow();
  });
});
