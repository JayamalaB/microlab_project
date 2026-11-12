// Tests services/itemPrices.js — the two catalog prices are both valid, and
// anything else the app sends is refused.
const { checkItemPrices } = require('../../services/itemPrices');

const conn = (rows) => ({ query: jest.fn().mockResolvedValue([rows]) });
const product = { product_id: 7, product_price: '1000.00', discount_percent: '10.00' };

beforeAll(() => { jest.spyOn(console, 'warn').mockImplementation(() => {}); });

test('the full price is valid', async () => {
  expect(await checkItemPrices(conn([product]), [{ packageId: 7, finalPrice: 1000 }])).toEqual({ ok: true });
});

test('the discounted price is valid', async () => {
  expect((await checkItemPrices(conn([product]), [{ packageId: 7, finalPrice: 900 }])).ok).toBe(true);
});

test('a product with no discount is valid at its price', async () => {
  const rows = [{ product_id: 7, product_price: '499.50', discount_percent: null }];
  expect((await checkItemPrices(conn(rows), [{ packageId: '7', finalPrice: 499.5 }])).ok).toBe(true);
});

test.each([[1], [0], [899], [-900], ['abc']])('a price of %p is refused', async (finalPrice) => {
  const r = await checkItemPrices(conn([product]), [{ packageId: 7, finalPrice }]);
  expect(r.ok).toBe(false);
  expect(r.message).toMatch(/price has changed/);
});

test('an item with no product is refused, not stored as free', async () => {
  const r = await checkItemPrices(conn([]), [{ packageId: 7, finalPrice: 1 }]);
  expect(r.ok).toBe(false);
  expect(r.message).toMatch(/no longer available/);
});

test('an item with no product id at all is refused', async () => {
  const r = await checkItemPrices(conn([]), [{ packageId: 0, finalPrice: 1 }]);
  expect(r.ok).toBe(false);
});

test('an empty list runs no query', async () => {
  const c = conn([]);
  expect(await checkItemPrices(c, [])).toEqual({ ok: true });
  expect(c.query).not.toHaveBeenCalled();
});
