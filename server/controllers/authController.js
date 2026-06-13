const db = require('../config/db');
const jwt = require('jsonwebtoken');

exports.sendOtp = async (req, res) => {
  const { mobile, role = 'customer' } = req.body;

  if (!/^[6-9]\d{9}$/.test(mobile)) {
    return res.status(422).json({ success: false, message: 'Invalid mobile number' });
  }

  const otp = Math.floor(1000 + Math.random() * 9000).toString();
  const expiresAt = new Date(Date.now() + 5 * 60 * 1000);

  await db.query('DELETE FROM otp_logs WHERE mobile = ?', [mobile]);
  await db.query(
    'INSERT INTO otp_logs (mobile, otp, role, expires_at) VALUES (?, ?, ?, ?)',
    [mobile, otp, role, expiresAt]
  );

  // TODO: integrate SMS gateway for production
  res.json({ success: true, message: 'OTP sent', data: { otp } });
};

exports.verifyOtp = async (req, res) => {
  const { mobile, otp, role = 'customer' } = req.body;

  const [rows] = await db.query(
    'SELECT * FROM otp_logs WHERE mobile = ? AND otp = ? AND role = ? AND expires_at > NOW()',
    [mobile, otp, role]
  );

  if (rows.length === 0) {
    return res.status(401).json({ success: false, message: 'Invalid or expired OTP' });
  }

  await db.query('DELETE FROM otp_logs WHERE mobile = ?', [mobile]);

  const table = role === 'technician' ? 'technicians' : 'customers';
  let [users] = await db.query(`SELECT * FROM ${table} WHERE mobile = ?`, [mobile]);

  let user;
  if (users.length === 0) {
    const [result] = await db.query(`INSERT INTO ${table} (mobile) VALUES (?)`, [mobile]);
    user = { id: result.insertId, mobile };
  } else {
    user = users[0];
  }

  const token = jwt.sign({ id: user.id, mobile, role }, process.env.JWT_SECRET, { expiresIn: '30d' });

  res.json({ success: true, message: 'Login successful', data: { token, user } });
};
