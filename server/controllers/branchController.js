const db = require('../config/db');

exports.getBranches = async (req, res) => {
  try {
    const { pincode, city } = req.query;

    let query = `SELECT branch_id AS id, name, address, location, pincode
                 FROM branches WHERE deleted_at IS NULL`;
    const params = [];

    if (pincode && pincode.trim()) {
      query += ' AND pincode = ?';
      params.push(pincode.trim());
    } else if (city && city.trim()) {
      query += ' AND location LIKE ?';
      params.push(`%${city.trim()}%`);
    }

    query += ' ORDER BY name ASC';

    const [rows] = await db.query(query, params);
    res.json({ success: true, data: rows });
  } catch (err) {
    console.error('getBranches error:', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};
