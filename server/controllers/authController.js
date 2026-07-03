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

// ── HMAC helper — matches verifySecureId() in the PHP scripts ─────────────────
function buildSecureId(mobileNo, userType, timestamp) {
  const message = `${mobileNo}|${userType}|${timestamp}`;
  return crypto
    .createHmac('sha256', process.env.CLIENT_SERVER_SECRET)
    .update(message)
    .digest('hex');
}

// ── HTTP POST to jayamala.neuralarc.com PHP registry ─────────────────────────
async function fetchFromRegistry(url, mobileNo, userType) {
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const secure_id = buildSecureId(mobileNo, userType, timestamp);
  const res = await fetch(url, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ mobile_no: mobileNo, user_type: userType, timestamp, secure_id }),
  });
  const body = await res.json();
  return { httpStatus: res.status, body };
}

exports.verifyOtp = async (req, res) => {
  try {
    const { mobile, otp, role = 'customer' } = req.body;

    if (!mobile || !otp) {
      return res.status(422).json({ success: false, message: 'Mobile and OTP required' });
    }

    // DB-based OTP verification
    const [rows] = await db.query(
      `SELECT user_id, client_id, user_name, user_microlab_type, user_mobile_no
       FROM ip_users
       WHERE user_mobile_no = ? AND user_otp = ? AND user_otp_expiry > NOW() AND user_active = 1`,
      [mobile, otp]
    );

    if (rows.length === 0) {
      return res.status(401).json({ success: false, message: 'Invalid or expired OTP' });
    }

    const dbUser = rows[0];
    const tokenExpiry = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);

    // Clear OTP after use
    await db.query(
      `UPDATE ip_users SET user_otp = NULL, user_otp_expiry = NULL,
       is_logged_in = 1, user_last_active_at = NOW(), user_date_modified = NOW()
       WHERE user_id = ?`,
      [dbUser.user_id]
    );

    // ── Technician path ───────────────────────────────────────────────────────
    if (role === 'technician') {
      // Look up PHP registry for canonical technician data
      let phpResult;
      try {
        phpResult = await fetchFromRegistry(process.env.JAYAMALA_URL, mobile, 'technician');
      } catch (err) {
        return res.status(502).json({ success: false, message: 'User registry unreachable. Try again.' });
      }
      if (phpResult.body.status !== 'success') {
        return res.status(404).json({ success: false, message: phpResult.body.msg ?? 'Technician not registered.' });
      }
      const t = phpResult.body.technician;

      // Find or auto-create ip_technicians row
      const [existingRows] = await db.query(
        `SELECT u.user_id, tech.technician_id, tech.branch_id
         FROM ip_users u
         JOIN ip_technicians tech ON tech.user_id = u.user_id
         WHERE u.user_mobile_no = ? AND u.user_microlab_type = 'technician'
         ORDER BY tech.technician_id ASC LIMIT 1`,
        [mobile]
      );

      let dbTechnicianId, dbBranchId;
      if (existingRows.length > 0) {
        dbTechnicianId = existingRows[0].technician_id;
        dbBranchId     = existingRows[0].branch_id;
      } else {
        const [techResult] = await db.query(
          `INSERT INTO ip_technicians
             (user_id, branch_id, technician_code, specialization,
              tech_photo, tech_city, is_available, max_daily_bookings, technician_active)
           VALUES (?, ?, ?, ?, ?, ?, 1, ?, 1)`,
          [dbUser.user_id, t.branch_id, t.technician_code, t.specialization,
           t.tech_photo, t.tech_city, t.max_daily_bookings]
        );
        dbTechnicianId = techResult.insertId;
        dbBranchId     = t.branch_id;
      }

      // Re-read branch_id from DB (admin may have changed it)
      const [[dbTech]] = await db.query(
        `SELECT t.branch_id, t.technician_code, t.specialization,
                u.user_name, u.user_email
         FROM ip_technicians t JOIN ip_users u ON u.user_id = t.user_id
         WHERE t.technician_id = ?`,
        [dbTechnicianId]
      );
      dbBranchId = dbTech?.branch_id ?? dbBranchId;

      const token = jwt.sign(
        { id: dbTechnicianId, userId: dbUser.user_id, mobile, role, branchId: dbBranchId },
        process.env.JWT_SECRET,
        { expiresIn: '30d' }
      );

      await db.query(
        `UPDATE ip_users SET user_auth_token = ?, user_token_expiry = ? WHERE user_id = ?`,
        [token, tokenExpiry, dbUser.user_id]
      );

      // Create session + live_location rows
      let sessionId = null;
      try {
        const [sr] = await db.query(
          `INSERT INTO ip_technician_sessions
             (technician_id, branch_id, session_date, duty_start_at, session_status, availability_status)
           VALUES (?, ?, CURDATE(), NOW(), 'active', 'offline')`,
          [dbTechnicianId, dbBranchId]
        );
        sessionId = sr.insertId;
      } catch (_) {}

      try {
        await db.query(
          `INSERT INTO ip_technician_live_location
             (technician_id, session_id, online_status, task_status, last_ping_at)
           VALUES (?, ?, 'offline', 'idle', NOW())
           ON DUPLICATE KEY UPDATE
             session_id = VALUES(session_id), online_status = 'offline',
             task_status = 'idle', socket_id = NULL, booking_id = NULL, last_ping_at = NOW()`,
          [dbTechnicianId, sessionId]
        );
      } catch (_) {}

      return res.json({
        success: true,
        message: 'Login successful',
        data: {
          token,
          user: {
            technician_id: dbTechnicianId,
            user_id:       dbUser.user_id,
            user_name:     dbTech?.user_name ?? t.name,
            user_email:    dbTech?.user_email ?? t.email,
            user_mobile_no: mobile,
            branch_id:     dbBranchId,
          },
          sessionId,
        },
      });
    }

    // ── Customer / patient path ───────────────────────────────────────────────
    let patients = [];
    try {
      [patients] = await db.query('SELECT * FROM ip_patients WHERE patient_mobile = ?', [mobile]);
    } catch (_) {
      try {
        [patients] = await db.query('SELECT * FROM ip_patients WHERE patient_phone = ?', [mobile]);
      } catch (_2) {}
    }

    let patient;
    if (patients.length === 0) {
      try {
        const [result] = await db.query(
          'INSERT INTO ip_patients (patient_mobile) VALUES (?)', [mobile]
        );
        patient = { patient_id: result.insertId, patient_mobile: mobile };
      } catch (_) {
        patient = { patient_id: dbUser.user_id, patient_mobile: mobile };
      }
    } else {
      patient = patients[0];
    }

    const token = jwt.sign(
      { id: patient.patient_id, userId: dbUser.user_id, mobile, role },
      process.env.JWT_SECRET,
      { expiresIn: '30d' }
    );

    await db.query(
      `UPDATE ip_users SET user_auth_token = ?, user_token_expiry = ? WHERE user_id = ?`,
      [token, tokenExpiry, dbUser.user_id]
    );

    return res.json({
      success: true,
      message: 'Login successful',
      data: { token, user: patient },
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
