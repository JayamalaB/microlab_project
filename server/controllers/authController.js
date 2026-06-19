const db = require('../config/db');
const jwt = require('jsonwebtoken');
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { checkClientUser } = require('../utils/secureId');

const LOG_DIR  = path.join(__dirname, '..', 'logs');
const LOG_FILE = path.join(LOG_DIR, 'otp.log');
if (!fs.existsSync(LOG_DIR)) fs.mkdirSync(LOG_DIR);

function writeLog(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false })
                .replace(',', '') + ' IST';
  const line = `[${ist}] ${msg}\n`;
  process.stdout.write(line);
  fs.appendFileSync(LOG_FILE, line, 'utf8');
}

const generateOtp = () => Math.floor(1000 + Math.random() * 9000).toString();

function sendSms(mobile, otp) {
  const message = encodeURIComponent(
    `Alert Detected in MicroLab : Temp is ${otp}°C. Location : Login -MICROLABS`
  );
  const url =
    `http://site.ping4sms.com/api/smsapi` +
    `?key=b12545cc4804680c6878ec8de0420d28` +
    `&route=2` +
    `&sender=MICROB` +
    `&number=91${mobile}` +
    `&sms=${message}` +
    `&templateid=1707170202637594495`;

  return new Promise((resolve, reject) => {
    http.get(url, (res) => {
      let data = '';
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => resolve(data));
    }).on('error', reject);
  });
}

exports.testSms = async (req, res) => {
  const { mobile } = req.query;
  if (!mobile) return res.json({ error: 'Pass ?mobile=10digitnumber' });
  try {
    const response = await sendSms(mobile, '25.5');
    res.json({ success: true, sms_response: response });
  } catch (err) {
    res.json({ success: false, error: err.message });
  }
};

exports.sendOtp = async (req, res) => {
  try {
    const { mobile, role = 'customer' } = req.body;

    if (!/^[6-9]\d{9}$/.test(mobile)) {
      return res.status(422).json({ success: false, message: 'Invalid mobile number' });
    }

    const clientType = role === 'technician' ? 'technician' : 'customer';
    const dbUserType = role === 'technician' ? 'Technician' : 'Patients';
    const t0 = Date.now();
    const elapsed = () => `${Date.now() - t0}ms`;

    // Check client server FIRST — blocks OTP for unregistered technicians
    writeLog(`[sendOtp] ${mobile} (${clientType}) — calling client server`);
    const clientRes = await checkClientUser(mobile, clientType);
    writeLog(`[sendOtp] client server done — ${elapsed()} | result: ${clientRes ? clientRes.msg : 'null (timeout/error)'}`);

    if (role === 'technician' && (!clientRes || clientRes.status !== 'success')) {
      return res.status(403).json({
        success: false,
        message: 'Mobile not registered as technician',
      });
    }

    const otp = generateOtp();
    const expiresAt = new Date(Date.now() + 5 * 60 * 1000);

    writeLog(`[sendOtp] querying DB — ${elapsed()}`);
    const [existing] = await db.query(
      'SELECT user_id FROM users WHERE mobile_no = ?',
      [mobile]
    );
    writeLog(`[sendOtp] DB select done — ${elapsed()}`);

    if (existing.length === 0) {
      await db.query(
        `INSERT INTO users (username, email, mobile_no, last_otp, otp_expiry, user_type, access_type)
         VALUES (?, ?, ?, ?, ?, ?, 'mobile_app')`,
        [`user_${mobile}`, `${mobile}@microlab.app`, mobile, otp, expiresAt, dbUserType]
      );
      writeLog(`[sendOtp] DB insert done — ${elapsed()}`);
    } else {
      await db.query(
        'UPDATE users SET last_otp = ?, otp_expiry = ?, user_type = ? WHERE mobile_no = ?',
        [otp, expiresAt, dbUserType, mobile]
      );
      writeLog(`[sendOtp] DB update done — ${elapsed()}`);
    }

    try {
      writeLog(`[sendOtp] calling SMS gateway — ${elapsed()}`);
      const smsResponse = await sendSms(mobile, otp);
      writeLog(`[sendOtp] SMS done — ${elapsed()} | response: ${smsResponse}`);
    } catch (smsErr) {
      writeLog(`[sendOtp] SMS failed — ${elapsed()} | ${smsErr.message}`);
    }

    writeLog(`[sendOtp] total — ${elapsed()}`);
    res.json({ success: true, message: `OTP sent to ${mobile}` });
  } catch (err) {
    console.error('sendOtp error:', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

exports.verifyOtp = async (req, res) => {
  try {
    const { mobile, otp } = req.body;

    if (!mobile || !otp) {
      return res.status(422).json({ success: false, message: 'Mobile and OTP required' });
    }

    const [rows] = await db.query(
      `SELECT * FROM users
       WHERE mobile_no = ? AND last_otp = ? AND otp_expiry > NOW() AND is_active = 1`,
      [mobile, otp]
    );

    if (rows.length === 0) {
      return res.status(401).json({ success: false, message: 'Invalid or expired OTP' });
    }

    const user = rows[0];
    const sessionId = crypto.randomBytes(32).toString('hex');
    const token = jwt.sign(
      { user_id: user.user_id, mobile, user_type: user.user_type },
      process.env.JWT_SECRET,
      { expiresIn: '30d' }
    );
    const tokenExpiry = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);

    await db.query(
      `UPDATE users
       SET last_otp = NULL, otp_expiry = NULL,
           auth_token = ?, token_expiry = ?,
           session_id = ?, is_logged_in = 1, last_active_at = NOW()
       WHERE user_id = ?`,
      [token, tokenExpiry, sessionId, user.user_id]
    );

    await db.query(
      `INSERT INTO user_sessions (user_id, session_id, auth_token, token_expiry, access_type, is_logged_in, last_active_at)
       VALUES (?, ?, ?, ?, 'mobile_app', 1, NOW())`,
      [user.user_id, sessionId, token, tokenExpiry]
    );

    res.json({
      success: true,
      message: 'Login successful',
      data: {
        token,
        user: {
          user_id: user.user_id,
          mobile: user.mobile_no,
          name: user.username,
          user_type: user.user_type,
        },
      },
    });
  } catch (err) {
    console.error('verifyOtp error:', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

exports.logout = async (req, res) => {
  try {
    const { user_id } = req.user;

    await db.query(
      `UPDATE users
       SET auth_token = NULL, token_expiry = NULL,
           session_id = NULL, is_logged_in = 0
       WHERE user_id = ?`,
      [user_id]
    );

    await db.query(
      `UPDATE user_sessions
       SET is_logged_in = 0, logged_out_at = NOW()
       WHERE user_id = ? AND is_logged_in = 1`,
      [user_id]
    );

    res.json({ success: true, message: 'Logged out successfully' });
  } catch (err) {
    console.error('logout error:', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};
