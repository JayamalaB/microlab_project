const crypto = require('crypto');
const db  = require('../config/db');
const jwt = require('jsonwebtoken');

// In-memory OTP store — keyed by mobile number
// Avoids a dependency on ip_otp_logs DB table that may not exist on all deployments.
// OTPs expire after 5 minutes; a periodic sweep keeps memory clean.
const _otpStore = new Map(); // mobile → { otp, role, expiresAt }
setInterval(() => {
  const now = Date.now();
  for (const [mobile, entry] of _otpStore) {
    if (entry.expiresAt < now) _otpStore.delete(mobile);
  }
}, 60_000);

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

  console.log(`   📡 [REGISTRY] POST ${url}`);
  console.log(`   📡 mobile_no=${mobileNo} user_type=${userType} timestamp=${timestamp}`);

  const res = await fetch(url, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ mobile_no: mobileNo, user_type: userType, timestamp, secure_id }),
  });

  const body = await res.json();
  console.log(`   📡 [REGISTRY] status=${res.status} body=${JSON.stringify(body)}`);
  return { httpStatus: res.status, body };
}

// ── POST /api/auth/send-otp ───────────────────────────────────────────────────
exports.sendOtp = async (req, res) => {
  const { mobile, role = 'customer' } = req.body;

  if (!/^[6-9]\d{9}$/.test(mobile)) {
    return res.status(422).json({ success: false, message: 'Invalid mobile number' });
  }

  // Customer: hardcoded OTP — no DB needed
  if (role !== 'technician') {
    return res.json({ success: true, message: 'OTP sent', data: { otp: '1234' } });
  }

  // Technician: generate OTP and hold it in memory for 5 minutes
  const otp = Math.floor(1000 + Math.random() * 9000).toString();
  _otpStore.set(mobile, { otp, role, expiresAt: Date.now() + 5 * 60 * 1000 });
  console.log(`   📲 [OTP] technician ${mobile} → ${otp}`);

  res.json({ success: true, message: 'OTP sent', data: { otp } });
};

// ── POST /api/auth/verify-otp ─────────────────────────────────────────────────
exports.verifyOtp = async (req, res) => {
  const { mobile, otp, role = 'customer' } = req.body;
  console.log(`\n🔐 [VERIFY OTP] mobile=${mobile} role=${role}`);

  // ── Customer: hardcoded OTP — no DB touched at all ───────────────────────
  if (role !== 'technician') {
    if (otp !== '1234') {
      console.log('❌ Customer OTP wrong');
      return res.status(401).json({ success: false, message: 'Invalid OTP' });
    }
    console.log('✅ Customer OTP accepted');
    const token = jwt.sign({ mobile, role }, process.env.JWT_SECRET, { expiresIn: '30d' });
    return res.json({
      success: true,
      message: 'Login successful',
      data: { token, user: { patient_id: 0, patient_mobile: mobile, patient_name: '' } },
    });
  }

  // ── Technician: verify OTP from in-memory store ──────────────────────────
  const otpEntry = _otpStore.get(mobile);
  if (!otpEntry || otpEntry.otp !== otp || otpEntry.role !== role || otpEntry.expiresAt < Date.now()) {
    console.log('❌ OTP invalid or expired');
    return res.status(401).json({ success: false, message: 'Invalid or expired OTP' });
  }
  _otpStore.delete(mobile);
  console.log('✅ OTP verified — cleared from store');

  // ── Technician: fetch profile from jayamala.neuralarc.com ────────────────
  if (role === 'technician') {
    let phpResult;
    try {
      phpResult = await fetchFromRegistry(process.env.JAYAMALA_URL, mobile, 'technician');
    } catch (err) {
      console.error('❌ [REGISTRY] fetch failed:', err.message);
      return res.status(502).json({ success: false, message: 'User registry unreachable. Try again.' });
    }

    if (phpResult.body.status !== 'success') {
      console.log('❌ Technician not found in registry:', phpResult.body.msg);
      return res.status(404).json({
        success: false,
        message: phpResult.body.msg ?? 'Technician not registered. Contact admin.',
      });
    }

    const t = phpResult.body.technician;
    console.log(`✅ Technician confirmed in registry — name=${t.name} branch_id=${t.branch_id}`);

    // ── Step 3: look up technician in DB by mobile number ─────────────────
    // PHP registry IDs (t.user_id / t.technician_id) are mock — always use real DB IDs
    let dbUserId, dbTechnicianId;

    const [existingRows] = await db.query(
      `SELECT u.user_id, tech.technician_id, tech.branch_id
       FROM ip_users u
       JOIN ip_technicians tech ON tech.user_id = u.user_id
       WHERE u.user_mobile_no = ? AND u.user_microlab_type = 'technician'
       ORDER BY tech.technician_id ASC
       LIMIT 1`,
      [mobile]
    );

    if (existingRows.length > 0) {
      // Returning technician — use existing DB IDs
      dbUserId       = existingRows[0].user_id;
      dbTechnicianId = existingRows[0].technician_id;
      console.log(`✅ Existing technician in DB — user_id=${dbUserId} technician_id=${dbTechnicianId}`);
    } else {
      // First login — auto-create in ip_users + ip_technicians
      console.log(`🆕 First login for ${mobile} — creating records in DB`);

      const [userResult] = await db.query(
        `INSERT INTO ip_users
           (user_type, user_active, user_date_created, user_date_modified,
            user_name, user_mobile, user_mobile_no, user_email,
            user_microlab_type, user_branch_id, user_all_clients, user_password, role_id)
         VALUES (1, 1, NOW(), NOW(), ?, ?, ?, ?, 'technician', ?, 0, '', 3)`,
        [t.name, mobile, mobile, t.email, t.branch_id]
      );
      dbUserId = userResult.insertId;
      console.log(`✅ ip_users created — user_id=${dbUserId}`);

      const [techResult] = await db.query(
        `INSERT INTO ip_technicians
           (user_id, branch_id, technician_code, specialization,
            tech_photo, tech_city, is_available, max_daily_bookings, technician_active)
         VALUES (?, ?, ?, ?, ?, ?, 1, ?, 1)`,
        [dbUserId, t.branch_id, t.technician_code, t.specialization,
         t.tech_photo, t.tech_city, t.max_daily_bookings]
      );
      dbTechnicianId = techResult.insertId;
      console.log(`✅ ip_technicians created — technician_id=${dbTechnicianId}`);
    }

    // Re-read from DB — admin may have changed branch_id or other fields after first login
    const [[dbTech]] = await db.query(
      `SELECT t.branch_id, t.technician_code, t.specialization,
              t.tech_photo, t.tech_city, t.is_available, t.max_daily_bookings,
              u.user_name, u.user_email
       FROM ip_technicians t
       JOIN ip_users u ON u.user_id = t.user_id
       WHERE t.technician_id = ?`,
      [dbTechnicianId]
    );

    // Build user object — DB values take precedence over PHP registry
    const user = {
      technician_id:      dbTechnicianId,
      user_id:            dbUserId,
      user_name:          dbTech?.user_name          ?? t.name,
      user_email:         dbTech?.user_email         ?? t.email,
      user_mobile_no:     mobile,
      branch_id:          dbTech?.branch_id          ?? t.branch_id,
      technician_code:    dbTech?.technician_code    ?? t.technician_code,
      specialization:     dbTech?.specialization     ?? t.specialization,
      tech_photo:         dbTech?.tech_photo         ?? t.tech_photo,
      tech_city:          dbTech?.tech_city          ?? t.tech_city,
      is_available:       dbTech?.is_available       ?? t.is_available,
      max_daily_bookings: dbTech?.max_daily_bookings ?? t.max_daily_bookings,
    };
    console.log(`✅ DB branch_id=${user.branch_id} (PHP had ${t.branch_id})`);

    // ── Step 4: generate JWT with real DB IDs ────────────────────────────
    const tokenExpiry = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);
    const token = jwt.sign(
      { id: user.technician_id, userId: user.user_id, mobile, role, branchId: user.branch_id },
      process.env.JWT_SECRET,
      { expiresIn: '30d' }
    );

    // ── Step 5: UPDATE ip_users — store token + mark last active ─────────
    try {
      await db.query(
        `UPDATE ip_users
         SET user_auth_token     = ?,
             user_token_expiry   = ?,
             user_last_active_at = NOW(),
             user_date_modified  = NOW()
         WHERE user_id = ?`,
        [token, tokenExpiry, dbUserId]
      );
      console.log(`✅ ip_users token updated — user_id=${dbUserId}`);
    } catch (err) {
      console.error('⚠️  ip_users update failed (non-fatal):', err.message);
    }

    // ── Step 6: INSERT ip_technician_sessions — new session per login ────
    let sessionId = null;
    try {
      const [sessionResult] = await db.query(
        `INSERT INTO ip_technician_sessions
           (technician_id, branch_id, session_date, duty_start_at, session_status, availability_status)
         VALUES (?, ?, CURDATE(), NOW(), 'active', 'offline')`,
        [dbTechnicianId, user.branch_id]
      );
      sessionId = sessionResult.insertId;
      console.log(`✅ ip_technician_sessions inserted — session_id=${sessionId}`);
    } catch (err) {
      console.error('⚠️  ip_technician_sessions insert failed (non-fatal):', err.message);
    }

    // ── Step 7: UPSERT ip_technician_live_location — one row per tech ────
    try {
      await db.query(
        `INSERT INTO ip_technician_live_location
           (technician_id, session_id, online_status, task_status, last_ping_at)
         VALUES (?, ?, 'offline', 'idle', NOW())
         ON DUPLICATE KEY UPDATE
           session_id    = VALUES(session_id),
           online_status = 'offline',
           task_status   = 'idle',
           socket_id     = NULL,
           booking_id    = NULL,
           last_ping_at  = NOW()`,
        [dbTechnicianId, sessionId]
      );
      console.log(`✅ ip_technician_live_location upserted — technician_id=${dbTechnicianId} session_id=${sessionId}`);
    } catch (err) {
      console.error('⚠️  ip_technician_live_location upsert failed (non-fatal):', err.message);
    }

    return res.json({ success: true, message: 'Login successful', data: { token, user, sessionId } });
  }

  // ── Step 2 (Customer/Patient): check ip_patients ──────────────────────────
  try {
    // Try common column name variations for mobile number
    let patients = [];
    let mobileCol = 'patient_mobile';

    try {
      [patients] = await db.query(
        'SELECT * FROM ip_patients WHERE patient_mobile = ?', [mobile]
      );
    } catch (colErr) {
      // patient_mobile column might not exist — try patient_phone
      console.warn('[verifyOtp] patient_mobile column missing, trying patient_phone');
      try {
        mobileCol = 'patient_phone';
        [patients] = await db.query(
          'SELECT * FROM ip_patients WHERE patient_phone = ?', [mobile]
        );
      } catch (colErr2) {
        console.error('[verifyOtp] Cannot find patients by mobile. Table columns may differ:', colErr2.message);
        throw new Error(`ip_patients query failed. Check column names. Details: ${colErr.message}`);
      }
    }

    let patient;
    if (patients.length === 0) {
      console.log(`🆕 New customer — creating ip_patients row for ${mobile}`);
      try {
        const [result] = await db.query(
          `INSERT INTO ip_patients (${mobileCol}) VALUES (?)`, [mobile]
        );
        patient = { patient_id: result.insertId, [mobileCol]: mobile };
        console.log(`✅ New patient created — patient_id=${patient.patient_id}`);
      } catch (insertErr) {
        console.error('[verifyOtp] INSERT ip_patients failed:', insertErr.message);
        throw new Error(`Cannot create patient: ${insertErr.message}`);
      }
    } else {
      patient = patients[0];
      console.log(`✅ Patient found — patient_id=${patient.patient_id}`);
    }

    const token = jwt.sign(
      { id: patient.patient_id, mobile, role },
      process.env.JWT_SECRET,
      { expiresIn: '30d' }
    );

    return res.json({ success: true, message: 'Login successful', data: { token, user: patient } });
  } catch (e) {
    console.error('[verifyOtp customer]', e.message);
    return res.status(500).json({ success: false, message: e.message });
  }
};
