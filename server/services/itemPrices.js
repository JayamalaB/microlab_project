'use strict';

// Checks the test prices a customer's app sent against ip_products. A price is
// valid when it is the product's price or its discounted price: GET /api/tests
// applies discount_percent only when the offer flag is on, GET /api/packages
// always applies it, so the app can legitimately hold either one.
//
// `items` are the app's [{ packageId, finalPrice }]. Returns { ok: true } or
// { ok: false, message } — the message is written for the customer.
const PRICE_CHANGED = 'A test price has changed. Please go back, refresh your cart and try again.';
const UNAVAILABLE   = 'A selected test is no longer available. Please update your cart and try again.';

const sameMoney = (a, b) => Math.abs(a - b) < 0.01;

async function checkItemPrices(conn, items) {
  const ids = [...new Set(items.map(i => Number(i.packageId)).filter(Boolean))];
  const [rows] = ids.length
    ? await conn.query(
        'SELECT product_id, product_price, discount_percent FROM ip_products WHERE product_id IN (?)',
        [ids]
      )
    : [[]];
  const products = new Map(rows.map(r => [Number(r.product_id), r]));

  for (const item of items) {
    const product = products.get(Number(item.packageId));
    if (!product) return { ok: false, message: UNAVAILABLE };

    const full       = Number(product.product_price) || 0;
    const discounted = Math.round(full * (1 - (Number(product.discount_percent) || 0) / 100) * 100) / 100;
    const sent       = Number(item.finalPrice);
    if (!sameMoney(sent, full) && !sameMoney(sent, discounted)) {
      console.warn(`[itemPrices] REJECTED product_id=${item.packageId} sent=${item.finalPrice} full=${full} discounted=${discounted}`);
      return { ok: false, message: PRICE_CHANGED };
    }
  }
  return { ok: true };
}

module.exports = { checkItemPrices };
