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
    report_sts:     r.report_tat_hours != null ? Number(r.report_tat_hours) : null,
    available_for_home: r.available_for_home ?? 1,
    available_for_lab:  r.available_for_lab  ?? 1,
  };
}

const DEFAULT_PAGE_SIZE = 20;
const MAX_PAGE_SIZE     = 100;

// LIKE wildcards in the customer's search text are matched literally.
function _likeEscape(s) {
  return String(s).replace(/[\\%_]/g, (c) => `\\${c}`);
}

// GET /api/tests — list active products from ip_products
//
// Optional filters: type, search (name / category / description), category,
// offer=yes (only products on offer), ids=1,2,3 (only these products, at most
// MAX_PAGE_SIZE — used to load the tests already on a booking).
//
// Paging: pass limit (1–100, default page size 20) and offset. The response
// then also carries total / hasMore so the app can load the next page.
// Without limit the full list is returned as before — checkout's family
// member sheet and My Bookings' edit-tests screen still rely on that.
exports.getCatalog = async (req, res) => {
  try {
    const { type, search, category, offer } = req.query;
    const paged = req.query.limit !== undefined || req.query.offset !== undefined;

    let where    = 'WHERE product_active = 1 AND deleted_at IS NULL';
    const params = [];

    if (type) {
      where += ' AND product_type = ?';
      params.push(type);
    }
    const term = typeof search === 'string' ? search.trim() : '';
    if (term) {
      const like = `%${_likeEscape(term)}%`;
      where += ' AND (product_name LIKE ? OR product_category LIKE ? OR product_description LIKE ?)';
      params.push(like, like, like);
    }
    if (category && category !== 'All') {
      // mapProduct shows a NULL category as 'General', so filter the same way.
      where += " AND COALESCE(NULLIF(product_category, ''), 'General') = ?";
      params.push(category);
    }
    if (offer === 'yes') {
      where += " AND offer IN ('yes', '1')";
    }
    if (req.query.ids !== undefined) {
      const ids = [...new Set(String(req.query.ids).split(','))]
        .map((s) => parseInt(s, 10))
        .filter((n) => Number.isInteger(n) && n > 0)
        .slice(0, MAX_PAGE_SIZE);
      if (ids.length === 0) return res.json({ success: true, data: [] });
      where += ` AND product_id IN (${ids.map(() => '?').join(',')})`;
      params.push(...ids);
    }

    if (!paged) {
      const [rows] = await db.execute(`SELECT * FROM ip_products ${where} ORDER BY product_name`, params);
      return res.json({ success: true, data: rows.map(mapProduct) });
    }

    const limitNum  = Math.min(Math.max(parseInt(req.query.limit, 10) || DEFAULT_PAGE_SIZE, 1), MAX_PAGE_SIZE);
    const offsetNum = Math.max(parseInt(req.query.offset, 10) || 0, 0);

    // LIMIT/OFFSET are validated integers, inlined because mysql2's execute()
    // rejects them as bound parameters on some MySQL/MariaDB versions.
    const [[rows], [[countRow]]] = await Promise.all([
      db.execute(
        `SELECT * FROM ip_products ${where} ORDER BY product_name, product_id LIMIT ${limitNum} OFFSET ${offsetNum}`,
        params
      ),
      db.execute(`SELECT COUNT(*) AS total FROM ip_products ${where}`, params),
    ]);
    const total = Number(countRow?.total) || 0;

    res.json({
      success: true,
      data:    rows.map(mapProduct),
      total,
      limit:   limitNum,
      offset:  offsetNum,
      hasMore: offsetNum + rows.length < total,
    });
  } catch (err) {
    const detail = `${err.message} | code=${err.code} | sql=${err.sql}`;
    console.error('getCatalog:', detail);
    res.status(500).json({ success: false, message: 'Server error', debug: detail });
  }
};

// GET /api/tests/categories — every category that has at least one active
// product, for the app's filter chips (the app only holds one page of
// products, so it can't work the list out from what it has loaded).
exports.getCategories = async (req, res) => {
  try {
    const [rows] = await db.execute(
      `SELECT DISTINCT COALESCE(NULLIF(product_category, ''), 'General') AS category
       FROM ip_products
       WHERE product_active = 1 AND deleted_at IS NULL
       ORDER BY category`
    );
    res.json({ success: true, data: rows.map((r) => r.category) });
  } catch (err) {
    console.error('getCategories:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
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
