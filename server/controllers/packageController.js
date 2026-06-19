const db = require('../config/db');

exports.getPackages = async (req, res) => {
  try {
    const [rows] = await db.query(
      `SELECT package_id AS id, name, type, category,
              despt AS description, offer,
              original_price, discount_percent, final_price,
              doc_req, pre_instrs, start_date, end_date, report_sts
       FROM packages
       WHERE deleted_at IS NULL
       ORDER BY category ASC, name ASC`
    );
    res.json({ success: true, data: rows });
  } catch (err) {
    console.error('getPackages error:', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};
