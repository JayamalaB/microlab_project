const db = require('../config/db');

// GET /api/tests — list products/tests from ip_products
exports.getCatalog = async (req, res) => {
  try {
    const { type, search } = req.query;

    let sql = `SELECT product_id AS id, product_name AS name, product_type AS type,
                      product_description AS description, product_price AS original_price,
                      offer_price AS final_price, document_required AS doc_req,
                      pre_instructions AS pre_instrs, report_tat_hours AS report_sts,
                      available_for_home, available_for_lab, package_type
               FROM ip_products
               WHERE product_active = 1`;
    const params = [];

    if (type) {
      sql += ' AND product_type = ?';
      params.push(type);
    }
    if (search) {
      sql += ' AND (product_name LIKE ? OR product_description LIKE ?)';
      params.push(`%${search}%`, `%${search}%`);
    }
    sql += ' ORDER BY product_name';

    const [rows] = await db.execute(sql, params);
    res.json({ success: true, packages: rows });
  } catch (err) {
    console.error('getCatalog:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// GET /api/tests/:id — single product/test
exports.getTest = async (req, res) => {
  try {
    const [rows] = await db.execute(
      `SELECT product_id AS id, product_name AS name, product_type AS type,
              product_description AS description, product_price AS original_price,
              offer_price AS final_price, document_required AS doc_req,
              pre_instructions AS pre_instrs, report_tat_hours AS report_sts,
              available_for_home, available_for_lab, package_type
       FROM ip_products
       WHERE product_id = ? AND product_active = 1`,
      [req.params.id]
    );
    if (!rows.length)
      return res.status(404).json({ success: false, message: 'Product not found' });
    res.json({ success: true, package: rows[0] });
  } catch (err) {
    console.error('getTest:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};
