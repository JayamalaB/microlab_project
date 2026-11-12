'use strict';
const https = require('https');

// Takes the money for a payment the customer has authorised. Without this
// Razorpay releases an authorised payment back to the customer after a few days.
function captureRazorpayPayment(paymentId, amountInRupees) {
  if (!paymentId || paymentId.startsWith('wallet:') || paymentId === 'pay_later') return;
  const keyId     = process.env.RAZORPAY_KEY_ID;
  const keySecret = process.env.RAZORPAY_KEY_SECRET;
  if (!keyId || !keySecret) return;

  const body = JSON.stringify({ amount: Math.round(amountInRupees * 100), currency: 'INR' });
  const auth = 'Basic ' + Buffer.from(`${keyId}:${keySecret}`).toString('base64');
  const req  = https.request({
    hostname: 'api.razorpay.com',
    path:     `/v1/payments/${encodeURIComponent(paymentId)}/capture`,
    method:   'POST',
    headers:  { 'Authorization': auth, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, (upstream) => {
    let data = '';
    upstream.on('data', c => data += c);
    upstream.on('end', () => {
      if (upstream.statusCode === 200) console.log(`💳 Razorpay captured: ${paymentId}`);
      else console.warn(`⚠️  Razorpay capture ${paymentId} → ${upstream.statusCode}: ${data}`);
    });
  });
  req.on('error', err => console.warn(`⚠️  Razorpay capture error: ${err.message}`));
  req.write(body);
  req.end();
}

module.exports = { captureRazorpayPayment };
