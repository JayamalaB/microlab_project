const db = require('../config/db');

exports.getPackages = async (req, res) => {
  try {
    const [rows] = await db.query(
      `SELECT
         product_id                                                         AS id,
         product_name                                                       AS name,
         product_type                                                       AS type,
         product_category                                                   AS category,
         product_description                                                AS description,
         offer,
         product_price                                                      AS original_price,
         COALESCE(discount_percent, 0)                                      AS discount_percent,
         ROUND(product_price * (1 - COALESCE(discount_percent, 0) / 100), 2) AS final_price,
         CASE WHEN document_required IN (1, '1', 'yes') THEN 1 ELSE 0 END   AS doc_req,
         pre_instructions                                                   AS pre_instrs,
         offer_start_date                                                   AS start_date,
         offer_end_date                                                     AS end_date,
         CONCAT(COALESCE(report_tat_hours, 24), ' hrs')                    AS report_sts
       FROM ip_products
       WHERE product_active = 1 AND deleted_at IS NULL
       ORDER BY product_category ASC, product_name ASC`
    );
    res.json({ success: true, data: rows });
  } catch (err) {
    console.error('getPackages error:', err);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};
