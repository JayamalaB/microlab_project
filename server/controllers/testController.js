const db = require('../config/db');

// GET /api/tests — list packages/tests from the packages table
exports.getCatalog = async (req, res) => {
  try {
    const { type, category, search } = req.query;

    let sql = `SELECT package_id AS id, name, type, category,
                      despt AS description, original_price, discount_percent,
                      final_price, doc_req, pre_instrs, report_sts
               FROM packages
               WHERE deleted_at IS NULL`;
    const params = [];

    if (type) {
      sql += ' AND type = ?';
      params.push(type);
    }
    if (category) {
      sql += ' AND category = ?';
      params.push(category);
    }
    if (search) {
      sql += ' AND (name LIKE ? OR despt LIKE ?)';
      params.push(`%${search}%`, `%${search}%`);
    }
    sql += ' ORDER BY category, name';

    const [rows] = await db.execute(sql, params);
    res.json({ success: true, packages: rows });
  } catch (err) {
    console.error('getCatalog:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// GET /api/tests/categories — distinct categories
exports.getCategories = async (req, res) => {
  try {
    const [rows] = await db.execute(
      `SELECT DISTINCT category
       FROM packages
       WHERE deleted_at IS NULL AND category IS NOT NULL
       ORDER BY category`
    );
    res.json({ success: true, categories: rows.map(r => r.category) });
  } catch (err) {
    console.error('getCategories:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// GET /api/tests/:id — single package/test
exports.getTest = async (req, res) => {
  try {
    const [rows] = await db.execute(
      `SELECT package_id AS id, name, type, category,
              despt AS description, original_price, discount_percent,
              final_price, doc_req, pre_instrs, report_sts
       FROM packages
       WHERE package_id = ? AND deleted_at IS NULL`,
      [req.params.id]
    );
    if (!rows.length)
      return res.status(404).json({ success: false, message: 'Package not found' });
    res.json({ success: true, package: rows[0] });
  } catch (err) {
    console.error('getTest:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};
