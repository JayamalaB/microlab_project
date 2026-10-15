'use strict';
// logRetentionSweep.js
//
// Daily purge of rows older than LOG_RETENTION_DAYS (default 90) from the 7
// database log tables added alongside the existing .log files (see
// server/utils/dbLogger.js and migrations/create_log_tables.sql). The .log
// files themselves are untouched by this — file rotation/retention, if any,
// is a separate, pre-existing concern.
//
// Runs once daily at 03:00 IST (off-peak), same node-cron pattern as
// technicianOfflineSweep.js. Deletes in small batches (not one unbounded
// DELETE) so a large backlog never holds a long-running lock/transaction
// against the same pool (config/db.js: connectionLimit 10) real traffic
// depends on — each batch is its own short statement, with a brief pause
// between batches.
const cron = require('node-cron');
const db   = require('../config/db');

const LOG_TABLES = [
  'ip_dispatch_logs', 'ip_collection_logs', 'ip_otpinfo_logs',
  'ip_technician_logs', 'ip_login_otp_logs', 'ip_client_sync_logs',
  'ip_customer_push_logs',
];

const BATCH_SIZE = 5000;
const BATCH_PAUSE_MS = 50;

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function purgeTableBatched(table, retentionDays) {
  let totalDeleted = 0;
  while (true) {
    const [result] = await db.execute(
      `DELETE FROM ${table} WHERE created_at < (NOW() - INTERVAL ? DAY) LIMIT ?`,
      [retentionDays, BATCH_SIZE]
    );
    totalDeleted += result.affectedRows;
    if (result.affectedRows < BATCH_SIZE) break;
    await sleep(BATCH_PAUSE_MS);
  }
  return totalDeleted;
}

async function runRetentionSweep() {
  const retentionDays = parseInt(process.env.LOG_RETENTION_DAYS, 10) || 90;
  for (const table of LOG_TABLES) {
    try {
      const deleted = await purgeTableBatched(table, retentionDays);
      if (deleted > 0) {
        console.log(`[logRetentionSweep] ${table}: purged ${deleted} row(s) older than ${retentionDays}d`);
      }
    } catch (e) {
      console.error(`[logRetentionSweep] ${table} purge failed: ${e.message}`);
    }
  }
}

module.exports = function initLogRetentionSweep() {
  cron.schedule('0 3 * * *', runRetentionSweep, { timezone: 'Asia/Kolkata' });
  console.log('[logRetentionSweep] started — daily at 03:00 IST');
};

// Exposed for tests — runs the same batched purge logic without the cron wrapper.
module.exports.runRetentionSweep = runRetentionSweep;
module.exports.purgeTableBatched = purgeTableBatched;
module.exports.LOG_TABLES = LOG_TABLES;
