const mysql = require('mysql2');
const path  = require('path');
const fs    = require('fs');
require('dotenv').config({ path: path.join(__dirname, '..', '.env'), override: true });

const dbName  = process.env.DB_NAME || 'adminmicro';
const logFile = path.join(__dirname, '..', 'logs', 'otp.log');
const logDir  = path.dirname(logFile);
if (!fs.existsSync(logDir)) fs.mkdirSync(logDir, { recursive: true });
const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false }).replace(',', '') + ' IST';
fs.appendFileSync(logFile, `[${ist}] [db] connecting → host=${process.env.DB_HOST} db=${dbName} user=${process.env.DB_USER}\n`, 'utf8');
console.log(`[db] connecting → host=${process.env.DB_HOST} db=${dbName} user=${process.env.DB_USER}`);

const pool = mysql.createPool({
  host:             process.env.DB_HOST,
  port:             process.env.DB_PORT,
  user:             process.env.DB_USER,
  password:         process.env.DB_PASS,
  database:         dbName,
  waitForConnections: true,
  connectionLimit:  10,
  dateStrings:      true,
});

module.exports = pool.promise();
