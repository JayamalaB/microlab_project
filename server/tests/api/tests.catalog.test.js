// Tests GET /api/tests and GET /api/tests/categories —
// server/controllers/testController.js: getCatalog, getCategories.
//
// The customer app loads the catalog one page at a time (?limit=&offset=)
// and searches on the server; without limit/offset the full list is still
// returned for the screens that need every product.
jest.mock('../../config/db');
const db      = require('../../config/db');
const request = require('supertest');
const { buildTestApp } = require('../helpers/testApp');

const testRoutes = require('../../routes/tests');
const app = buildTestApp('/api/tests', testRoutes);

const product = (id, name, extra = {}) => ({
  product_id: id, product_name: name, product_type: 'single', product_category: 'Blood',
  product_description: '', product_price: '300', offer: 'no', discount_percent: null,
  document_required: 'no', ...extra,
});

beforeEach(() => {
  db.execute.mockReset().mockResolvedValue([[], {}]);
});

describe('GET /api/tests — full list (no paging)', () => {
  test('returns every active product, as before', async () => {
    db.execute.mockResolvedValueOnce([[product(1, 'CBC'), product(2, 'Lipid Profile')]]);

    const res = await request(app).get('/api/tests');

    expect(res.status).toBe(200);
    expect(res.body.data).toHaveLength(2);
    expect(res.body.total).toBeUndefined();
    const sql = db.execute.mock.calls[0][0];
    expect(sql).not.toMatch(/LIMIT/);
    expect(db.execute).toHaveBeenCalledTimes(1); // no COUNT query
  });
});

describe('GET /api/tests — paged', () => {
  test('first page: LIMIT/OFFSET applied, total + hasMore returned', async () => {
    db.execute
      .mockResolvedValueOnce([[product(1, 'A'), product(2, 'B')]]) // page
      .mockResolvedValueOnce([[{ total: 1000 }]]);                  // COUNT

    const res = await request(app).get('/api/tests?limit=2&offset=0');

    expect(res.status).toBe(200);
    expect(res.body.data).toHaveLength(2);
    expect(res.body).toMatchObject({ total: 1000, limit: 2, offset: 0, hasMore: true });
    expect(db.execute.mock.calls[0][0]).toMatch(/LIMIT 2 OFFSET 0/);
    expect(db.execute.mock.calls[1][0]).toMatch(/COUNT\(\*\)/);
  });

  test('last page reports hasMore=false', async () => {
    db.execute
      .mockResolvedValueOnce([[product(999, 'Y'), product(1000, 'Z')]])
      .mockResolvedValueOnce([[{ total: 1000 }]]);

    const res = await request(app).get('/api/tests?limit=20&offset=998');

    expect(res.body.hasMore).toBe(false);
  });

  test('limit is capped at 100 and bad values fall back to safe defaults', async () => {
    db.execute.mockResolvedValueOnce([[]]).mockResolvedValueOnce([[{ total: 0 }]]);
    await request(app).get('/api/tests?limit=5000&offset=-7');
    expect(db.execute.mock.calls[0][0]).toMatch(/LIMIT 100 OFFSET 0/);

    db.execute.mockReset()
      .mockResolvedValueOnce([[]]).mockResolvedValueOnce([[{ total: 0 }]]);
    await request(app).get('/api/tests?limit=abc&offset=xyz');
    expect(db.execute.mock.calls[0][0]).toMatch(/LIMIT 20 OFFSET 0/);
  });

  test('search matches name, category or description, with LIKE wildcards escaped', async () => {
    db.execute.mockResolvedValueOnce([[]]).mockResolvedValueOnce([[{ total: 0 }]]);

    await request(app).get('/api/tests?limit=20&search=' + encodeURIComponent(' 100%_vit '));

    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toMatch(/product_name LIKE \? OR product_category LIKE \? OR product_description LIKE \?/);
    expect(params).toEqual(['%100\\%\\_vit%', '%100\\%\\_vit%', '%100\\%\\_vit%']);
    // The COUNT query uses the same filter and params.
    expect(db.execute.mock.calls[1][1]).toEqual(params);
  });

  test('category and offer filters are applied on the server', async () => {
    db.execute.mockResolvedValueOnce([[]]).mockResolvedValueOnce([[{ total: 0 }]]);

    await request(app).get('/api/tests?limit=20&category=Thyroid&offer=yes');

    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toMatch(/COALESCE\(NULLIF\(product_category, ''\), 'General'\) = \?/);
    expect(sql).toMatch(/offer IN \('yes', '1'\)/);
    expect(params).toEqual(['Thyroid']);
  });

  test('category=All adds no category filter', async () => {
    db.execute.mockResolvedValueOnce([[]]).mockResolvedValueOnce([[{ total: 0 }]]);
    await request(app).get('/api/tests?limit=20&category=All');
    expect(db.execute.mock.calls[0][0]).not.toMatch(/product_category, ''\), 'General'\) = \?/);
  });
});

describe('GET /api/tests?ids= — the tests already on a booking', () => {
  test('returns only the requested products; invalid and duplicate ids are dropped', async () => {
    db.execute.mockResolvedValueOnce([[product(4, 'CBC'), product(9, 'TSH')]]);

    const res = await request(app).get('/api/tests?ids=4,9,abc,4,-2');

    expect(res.status).toBe(200);
    expect(res.body.data).toHaveLength(2);
    const [sql, params] = db.execute.mock.calls[0];
    expect(sql).toMatch(/product_id IN \(\?,\?\)/);
    expect(params).toEqual([4, 9]);
  });

  test('no valid ids → empty list without querying', async () => {
    const res = await request(app).get('/api/tests?ids=abc');
    expect(res.body.data).toEqual([]);
    expect(db.execute).not.toHaveBeenCalled();
  });
});

describe('GET /api/tests/categories', () => {
  test('returns the distinct category names', async () => {
    db.execute.mockResolvedValueOnce([[{ category: 'Blood' }, { category: 'General' }]]);

    const res = await request(app).get('/api/tests/categories');

    expect(res.status).toBe(200);
    expect(res.body.data).toEqual(['Blood', 'General']);
    expect(db.execute.mock.calls[0][0]).toMatch(/DISTINCT/);
  });
});
