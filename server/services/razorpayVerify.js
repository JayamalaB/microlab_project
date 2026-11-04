'use strict';
const db = require('../config/db');

// Confirms with Razorpay that a payment id the app sent is a real payment for
// the right amount, before anything is marked paid. The app's word alone is
// never enough: it runs on the customer's phone.
//
// amount      rupees expected. Must match within a paisa, or with atLeast the
//             payment must cover it (one payment shared across a family visit).
// checkReuse  rejects an id already recorded on a booking, so one payment
//             can't pay for a second booking. Leave off where the app splits
//             one payment across several bookings by design.
//
// Returns { ok: true, amount, status } with the real rupees paid and Razorpay's
// 'authorized' or 'captured', or { ok: false, message }.
const NOT_CONFIRMED = 'We could not confirm your payment. You have not been charged — please try again.';
const WRONG_AMOUNT  = 'The payment amount did not match this booking. You have not been charged — please try again.';

const TOLERANCE_PAISE = 1;

async function verifyRazorpayPayment(paymentId, { amount, atLeast = false, checkReuse = false }) {
  const fail = (reason, message = NOT_CONFIRMED) => {
    console.warn(`[razorpayVerify] REJECTED payment_id=${paymentId} reason=${reason}`);
    return { ok: false, message };
  };

  if (!/^pay_[A-Za-z0-9]+$/.test(String(paymentId))) return fail('not a Razorpay payment id');

  const keyId     = process.env.RAZORPAY_KEY_ID;
  const keySecret = process.env.RAZORPAY_KEY_SECRET;
  if (!keyId || !keySecret) return fail('Razorpay keys not configured');

  let payment;
  try {
    const res = await fetch(`https://api.razorpay.com/v1/payments/${paymentId}`, {
      headers: { Authorization: 'Basic ' + Buffer.from(`${keyId}:${keySecret}`).toString('base64') },
      signal:  AbortSignal.timeout(10_000),
    });
    if (!res.ok) return fail(`Razorpay replied ${res.status}`);
    payment = await res.json();
  } catch (err) {
    return fail(`lookup failed: ${err.message}`);
  }

  if (!['authorized', 'captured'].includes(payment.status)) return fail(`status=${payment.status}`);
  if (payment.currency !== 'INR') return fail(`currency=${payment.currency}`);

  const expectedPaise = Math.round(Number(amount) * 100);
  const short = expectedPaise - payment.amount;
  if (atLeast ? short > TOLERANCE_PAISE : Math.abs(short) > TOLERANCE_PAISE) {
    return fail(`amount=${payment.amount} expected=${expectedPaise}`, WRONG_AMOUNT);
  }

  if (checkReuse) {
    const [used] = await db.execute(
      `SELECT 1 FROM ip_payment_transactions
       WHERE gateway_transaction_id = ? AND (is_refund = 0 OR is_refund IS NULL) LIMIT 1`,
      [paymentId]
    );
    if (used.length > 0) return fail('already used on a booking', 'This payment has already been used.');
  }

  return { ok: true, amount: payment.amount / 100, status: payment.status };
}

module.exports = { verifyRazorpayPayment };
