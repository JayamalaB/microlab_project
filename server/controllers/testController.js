const db = require('../config/db');

// Maps ip_products row → shape TestModel.fromJson() expects
function mapProduct(r) {
  const original    = parseFloat(r.product_price ?? 0) || 0;
  const hasOffer    = r.offer === 'yes' || r.offer === '1' || r.offer == 1;
  const discountPct = hasOffer ? (parseFloat(r.discount_percent) || 0) : 0;
  const finalP      = hasOffer && discountPct > 0
    ? Math.round(original * (1 - discountPct / 100) * 100) / 100
    : original;

  return {
    id:             r.product_id?.toString(),
    name:           r.product_name   ?? '',
    type:           r.product_type   ?? 'single',
    category:       r.product_category ?? 'General',
    description:    r.product_description ?? '',
    original_price: original,
    final_price:    finalP,
    offer:          hasOffer ? 'yes' : 'no',
    offer_pct:      hasOffer ? discountPct : null,
    start_date:     r.offer_start_date ?? null,
    end_date:       r.offer_end_date   ?? null,
    doc_req:        (r.document_required === 'yes' || r.document_required == 1) ? 'yes' : 'no',
    pre_instrs:     r.pre_instructions ?? null,
    report_sts:     r.report_tat_hours  ?? '24 hrs',
    available_for_home: r.available_for_home ?? 1,
    available_for_lab:  r.available_for_lab  ?? 1,
  };
}

// GET /api/tests — list active products from ip_products
exports.getCatalog = async (req, res) => {
  try {
    const { type, search } = req.query;

    let sql    = 'SELECT * FROM ip_products WHERE product_active = 1 AND deleted_at IS NULL';
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
    res.json({ success: true, data: rows.map(mapProduct) });
  } catch (err) {
    const detail = `${err.message} | code=${err.code} | sql=${err.sql}`;
    console.error('getCatalog:', detail);
    res.status(500).json({ success: false, message: 'Server error', debug: detail });
  }
};

// GET /api/tests/:id — single product
exports.getTest = async (req, res) => {
  try {
    const [rows] = await db.execute(
      'SELECT * FROM ip_products WHERE product_id = ? AND product_active = 1 AND deleted_at IS NULL',
      [req.params.id]
    );
    if (!rows.length)
      return res.status(404).json({ success: false, message: 'Product not found' });
    res.json({ success: true, package: mapProduct(rows[0]) });
  } catch (err) {
    console.error('getTest:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};
