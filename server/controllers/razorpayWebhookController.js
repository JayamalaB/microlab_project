const crypto = require('crypto');
const db     = require('../config/db');
const { sendToBookingOwner } = require('../services/customerPush');

const WEBHOOK_LOG = require('path').join(__dirname, '..', 'logs', 'razorpay_webhook.log');
const fs = require('fs');

function log(msg) {
  const ist  = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' });
  const line = `[${ist}] ${msg}\n`;
  process.stdout.write(line);
  fs.appendFileSync(WEBHOOK_LOG, line, 'utf8');
}

exports.handleWebhook = async (req, res) => {
  // req.body is a Buffer (express.raw middleware applied by the route)
  const rawBody  = req.body;
  const sig      = req.headers['x-razorpay-signature'];
  const secret   = process.env.RAZORPAY_WEBHOOK_SECRET;

  if (!secret) {
    log('❌ RAZORPAY_WEBHOOK_SECRET not set in .env');
    return res.status(500).end();
  }

  // Verify signature
  const expected = crypto.createHmac('sha256', secret).update(rawBody).digest('hex');
  if (sig !== expected) {
    log(`❌ Signature mismatch — received: ${sig}`);
    return res.status(400).json({ error: 'Invalid signature' });
  }

  let event;
  try {
    event = JSON.parse(rawBody.toString('utf8'));
  } catch {
    return res.status(400).json({ error: 'Invalid JSON' });
  }

  log(`📩 Event: ${event.event}`);

  if (event.event === 'refund.processed') {
    await handleRefundProcessed(event.payload?.refund?.entity);
  }

  // Always respond 200 quickly so Razorpay stops retrying
  res.status(200).json({ received: true });
};

async function handleRefundProcessed(refund) {
  if (!refund?.id) return;

  const refundId  = refund.id;          // rfnd_xxx
  const paymentId = refund.payment_id;  // pay_xxx
  const amount    = (refund.amount || 0) / 100;

  log(`💸 refund.processed — refund_id=${refundId} payment_id=${paymentId} amount=₹${amount}`);

  try {
    // Find the refund transaction row by refund ID
    const [[txn]] = await db.execute(
      `SELECT pt.transaction_id, pt.booking_id, b.patient_id
       FROM ip_payment_transactions pt
       JOIN ip_bookings b ON b.booking_id = pt.booking_id
       WHERE pt.gateway_transaction_id = ? AND pt.is_refund = 1
       LIMIT 1`,
      [refundId]
    );

    if (!txn) {
      // Fall back: find by the original payment ID
      const [[txn2]] = await db.execute(
        `SELECT pt.transaction_id, pt.booking_id, b.patient_id
         FROM ip_payment_transactions pt
         JOIN ip_bookings b ON b.booking_id = pt.booking_id
         WHERE pt.gateway_transaction_id = ? AND pt.is_refund = 1
         LIMIT 1`,
        [paymentId]
      );
      if (!txn2) {
        log(`⚠️  No refund transaction found for refund_id=${refundId} payment_id=${paymentId}`);
        return;
      }
      Object.assign(txn ?? {}, txn2);
      return await markSettled(txn2, refundId, amount);
    }

    await markSettled(txn, refundId, amount);
  } catch (err) {
    log(`❌ handleRefundProcessed error: ${err.message}`);
  }
}

async function markSettled(txn, refundId, amount) {
  const { transaction_id, booking_id } = txn;

  await db.execute(
    `UPDATE ip_payment_transactions
     SET transaction_status = 'completed', updated_at = NOW()
     WHERE transaction_id = ?`,
    [transaction_id]
  );

  await db.execute(
    `UPDATE ip_bookings
     SET refund_status = 'processed', updated_at = NOW()
     WHERE booking_id = ?`,
    [booking_id]
  );

  log(`✅ Marked settled — booking_id=${booking_id} refund_id=${refundId} ₹${amount}`);

  // Push notification to customer
  try {
    await sendToBookingOwner(booking_id, {
      title: 'Refund Processed',
      body:  `Your refund of ₹${amount} has been credited to your account.`,
      data:  { type: 'refund_processed', bookingId: String(booking_id) },
    });
  } catch (err) {
    log(`⚠️  Push notification failed: ${err.message}`);
  }
}
