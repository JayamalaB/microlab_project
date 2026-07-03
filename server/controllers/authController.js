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
  const t0 = Date.now();
  const elapsed = () => `${Date.now() - t0}ms`;
  let step = 'init';
  try {
    const { mobile, role = 'customer' } = req.body;

    if (!/^[6-9]\d{9}$/.test(mobile)) {
      return res.status(422).json({ success: false, message: 'Invalid mobile number' });
    }

    const clientType = role === 'technician' ? 'technician' : 'customer';
    const dbUserType = role === 'technician' ? 'technician' : 'patient_user';

    step = 'checkClientUser';
    writeLog(`[sendOtp] ${mobile} (${clientType})`);
    let clientRes = null;
    try {
      clientRes = await checkClientUser(mobile, clientType);
    } catch (clientErr) {
      writeLog(`[sendOtp] checkClientUser threw: ${clientErr.message}`);
    }
    writeLog(`[sendOtp] client server done — ${elapsed()} | result: ${clientRes ? clientRes.msg : 'null'}`);

    if (role === 'technician' && (!clientRes || clientRes.status !== 'success')) {
      return res.status(403).json({ success: false, message: 'Mobile not registered as technician' });
    }

    const otp = generateOtp();
    const expiresAt = new Date(Date.now() + 5 * 60 * 1000);

    step = 'select_user';
    writeLog(`[sendOtp] SELECT ip_users — ${elapsed()}`);
    const [existing] = await db.query(
      'SELECT user_id, client_id FROM ip_users WHERE user_mobile_no = ?',
      [mobile]
    );
    writeLog(`[sendOtp] select done — found=${existing.length} — ${elapsed()}`);

    if (existing.length === 0) {
      step = 'insert_user';
      writeLog(`[sendOtp] new user — inserting ip_users — ${elapsed()}`);
      const [insertResult] = await db.query(
        `INSERT INTO ip_users
           (user_name, user_email, user_mobile_no, user_otp, user_otp_expiry,
            user_microlab_type, access_type,
            user_date_created, user_date_modified, user_password, user_type, user_all_clients, role_id)
         VALUES (?, ?, ?, ?, ?, ?, 'mobile_app', NOW(), NOW(), '', 0, 0, 0)`,
        [`user_${mobile}`, null, mobile, otp, expiresAt, dbUserType]
      );
      const newUserId = insertResult.insertId;
      writeLog(`[sendOtp] ip_users inserted — user_id=${newUserId} — ${elapsed()}`);

      step = 'insert_client';
      const [clientResult] = await db.query(
        `INSERT INTO ip_clients
           (client_name, client_mobile_no, client_reg_source, client_date_created, client_date_modified)
         VALUES (?, ?, 'mobile_app', NOW(), NOW())`,
        [`user_${mobile}`, mobile]
      );
      const newClientId = clientResult.insertId;
      writeLog(`[sendOtp] ip_clients inserted — client_id=${newClientId} — ${elapsed()}`);

      step = 'link_client';
      await db.query(
        'UPDATE ip_users SET client_id = ? WHERE user_id = ?',
        [newClientId, newUserId]
      );
      writeLog(`[sendOtp] client_id linked — ${elapsed()}`);
    } else {
      step = 'update_otp';
      await db.query(
        `UPDATE ip_users
         SET user_otp = ?, user_otp_expiry = ?, user_microlab_type = ?, user_date_modified = NOW()
         WHERE user_mobile_no = ?`,
        [otp, expiresAt, dbUserType, mobile]
      );
      writeLog(`[sendOtp] otp updated — ${elapsed()}`);
    }

    step = 'sms';
    try {
      writeLog(`[sendOtp] calling SMS gateway — ${elapsed()}`);
      const smsResponse = await sendSms(mobile, otp);
      writeLog(`[sendOtp] SMS done — ${elapsed()} | response: ${smsResponse}`);
    } catch (smsErr) {
      writeLog(`[sendOtp] SMS failed (non-fatal) — ${elapsed()} | ${smsErr.message}`);
    }

    writeLog(`[sendOtp] done — total ${elapsed()}`);
    res.json({ success: true, message: `OTP sent to ${mobile}` });
  } catch (err) {
    const errDetail = `step=${step} | ${err.message} | code=${err.code} | sqlState=${err.sqlState} | sql=${err.sql}`;
    writeLog(`[sendOtp] ERROR — ${errDetail}`);
    console.error('sendOtp error:', err);
    res.status(500).json({ success: false, message: 'Server error', debug: errDetail });
  }
};

exports.verifyOtp = async (req, res) => {
  try {
    const { mobile, otp } = req.body;

    if (!mobile || !otp) {
      return res.status(422).json({ success: false, message: 'Mobile and OTP required' });
    }

    const [rows] = await db.query(
      `SELECT user_id, client_id, user_name, user_microlab_type, user_mobile_no
       FROM ip_users
       WHERE user_mobile_no = ? AND user_otp = ? AND user_otp_expiry > NOW() AND user_active = 1`,
      [mobile, otp]
    );

    if (rows.length === 0) {
      return res.status(401).json({ success: false, message: 'Invalid or expired OTP' });
    }

    const user = rows[0];
    const sessionId = crypto.randomBytes(32).toString('hex');
    const token = jwt.sign(
      { user_id: user.user_id, client_id: user.client_id, mobile, user_type: user.user_microlab_type },
      process.env.JWT_SECRET,
      { expiresIn: '30d' }
    );
    const tokenExpiry = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);

    await db.query(
      `UPDATE ip_users
       SET user_otp = NULL, user_otp_expiry = NULL,
           user_auth_token = ?, user_token_expiry = ?,
           session_id = ?, is_logged_in = 1, user_last_active_at = NOW(), user_date_modified = NOW()
       WHERE user_id = ?`,
      [token, tokenExpiry, sessionId, user.user_id]
    );

    res.json({
      success: true,
      message: 'Login successful',
      data: {
        token,
        user: {
          user_id:   user.user_id,
          client_id: user.client_id,
          mobile:    user.user_mobile_no,
          name:      user.user_name,
          user_type: user.user_microlab_type,
        },
      },
    });
  } catch (err) {
    const errDetail = `${err.message} | code=${err.code} | sql=${err.sql}`;
    writeLog(`[verifyOtp] ERROR — ${errDetail}`);
    console.error('verifyOtp error:', err);
    res.status(500).json({ success: false, message: 'Server error', debug: errDetail });
  }
};

exports.logout = async (req, res) => {
  try {
    const { user_id } = req.user;

    await db.query(
      `UPDATE ip_users
       SET user_auth_token = NULL, user_token_expiry = NULL,
           session_id = NULL, is_logged_in = 0, user_date_modified = NOW()
       WHERE user_id = ?`,
      [user_id]
    );

    res.json({ success: true, message: 'Logged out successfully' });
  } catch (err) {
    console.error('logout error:', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};
