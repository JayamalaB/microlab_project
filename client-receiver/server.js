const express = require('express');
const crypto  = require('crypto');
const fs      = require('fs');
const path    = require('path');
require('dotenv').config();

const app = express();
app.use(express.json());

// ── File logger ───────────────────────────────────────────────────────────────

const LOG_DIR  = path.join(__dirname, 'logs');
const LOG_FILE = path.join(LOG_DIR, 'receiver.log');

if (!fs.existsSync(LOG_DIR)) fs.mkdirSync(LOG_DIR);

function writeLog(lines) {
  const dateStr = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false })
                    .replace(',', '') + ' IST';
  const divider = '─'.repeat(50);
  const entry   = [`\n${divider}`, `[${dateStr}]`, ...lines, divider].join('\n') + '\n';
  fs.appendFileSync(LOG_FILE, entry, 'utf8');
  process.stdout.write(entry);
}

// ── Verify HMAC secure ID ─────────────────────────────────────────────────────

function verifySecureId(mobile_no, user_type, timestamp, receivedSecureId) {
  const message  = `${mobile_no}|${user_type}|${timestamp}`;
  const expected = crypto
    .createHmac('sha256', process.env.CLIENT_SERVER_SECRET)
    .update(message)
    .digest('hex');
  return crypto.timingSafeEqual(
    Buffer.from(expected,         'hex'),
    Buffer.from(receivedSecureId, 'hex')
  );
}

// ── Receive login check from MicroLab ────────────────────────────────────────

app.post('/api/receive-login', (req, res) => {
  const { mobile_no, user_type, timestamp, secure_id } = req.body;

  const logLines = [
    'REQUEST',
    `  mobile_no  : ${mobile_no}`,
    `  user_type  : ${user_type}`,
    `  timestamp  : ${timestamp}`,
    `  secure_id  : ${secure_id}`,
  ];

  // 1. Check required fields
  if (!mobile_no || !user_type || !timestamp || !secure_id) {
    const response = { status: 'failure', msg: 'Missing required fields' };
    logLines.push('RESPONSE', `  status : 400`, `  body   : ${JSON.stringify(response)}`);
    writeLog(logLines);
    return res.status(400).json(response);
  }

  // 2. Check timestamp freshness (within 5 minutes)
  const ageSecs = Math.floor(Date.now() / 1000) - Number(timestamp);
  if (ageSecs < 0 || ageSecs > 300) {
    const response = { status: 'failure', msg: `Request expired (age: ${ageSecs}s)` };
    logLines.push('RESPONSE', `  status : 401`, `  body   : ${JSON.stringify(response)}`);
    writeLog(logLines);
    return res.status(401).json(response);
  }

  // 3. Verify HMAC secure ID
  let valid = false;
  try {
    valid = verifySecureId(mobile_no, user_type, timestamp, secure_id);
  } catch {
    const response = { status: 'failure', msg: 'Invalid secure_id' };
    logLines.push('RESPONSE', `  status : 401`, `  body   : ${JSON.stringify(response)}`);
    writeLog(logLines);
    return res.status(401).json(response);
  }

  if (!valid) {
    const response = { status: 'failure', msg: 'Invalid secure_id' };
    logLines.push('RESPONSE', `  status : 401`, `  body   : ${JSON.stringify(response)}`);
    writeLog(logLines);
    return res.status(401).json(response);
  }

  // 3. Look up mobile_no
  // Customers can always self-register — always found.
  // Technicians must be pre-registered; only numbers in this list are valid.
  const REGISTERED_TECHNICIANS = [
    '7339535472'
    // add real technician mobile numbers here
  ];
  const found = user_type === 'technician'
    ? REGISTERED_TECHNICIANS.includes(mobile_no)
    : true;

  if (!found) {
    const response = { status: 'failure', msg: 'Mobile Not Available' };
    logLines.push('RESPONSE', `  status : 200`, `  body   : ${JSON.stringify(response)}`);
    writeLog(logLines);
    return res.json(response);
  }

  const response = { status: 'success', msg: 'Mobile No Available' };
  logLines.push('RESPONSE', `  status : 200`, `  body   : ${JSON.stringify(response)}`);
  writeLog(logLines);
  res.json(response);
});

// ── Health check ──────────────────────────────────────────────────────────────

app.get('/', (req, res) =>
  res.json({ success: true, message: 'MicroLab receiver running' })
);

const PORT = process.env.PORT || 4000;
app.listen(PORT, () =>
  console.log(`Receiver running on http://localhost:${PORT}  |  log → ${LOG_FILE}`)
);
