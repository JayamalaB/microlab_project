const crypto   = require('crypto');
const db       = require('../config/db');
const qrStore  = require('../services/qrSessionStore');
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
  log(`📥 request received — ip=${req.ip} method=${req.method} content-type=${req.headers['content-type'] ?? 'none'}`);

  // req.body is a Buffer (express.raw middleware applied by the route)
  const rawBody  = req.body;
  const sig      = req.headers['x-razorpay-signature'];
  const secret   = process.env.RAZORPAY_WEBHOOK_SECRET;

  log(`   body type=${Buffer.isBuffer(rawBody) ? 'Buffer' : typeof rawBody} length=${rawBody?.length ?? 0}`);
  log(`   x-razorpay-signature=${sig ?? 'MISSING'}`);
  log(`   RAZORPAY_WEBHOOK_SECRET set=${!!secret}`);

  if (!secret) {
    log('❌ RAZORPAY_WEBHOOK_SECRET not set in .env');
    return res.status(500).end();
  }

  // Verify signature
  const expected = crypto.createHmac('sha256', secret).update(rawBody).digest('hex');
  log(`   expected=${expected}`);
  log(`   received=${sig}`);
  if (sig !== expected) {
    log(`❌ Signature mismatch — received: ${sig}`);
    return res.status(400).json({ error: 'Invalid signature' });
  }
  log('✅ Signature verified');

  let event;
  try {
    event = JSON.parse(rawBody.toString('utf8'));
  } catch {
    return res.status(400).json({ error: 'Invalid JSON' });
  }

  log(`📩 Event: ${event.event}`);

  if (event.event === 'refund.processed') {
    await handleRefundProcessed(event.payload?.refund?.entity);
  } else if (event.event === 'qr_code.credited') {
    await handleQrCodeCredited(event.payload);
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

async function handleQrCodeCredited(payload) {
  const payment = payload?.payment?.entity;
  const qrCode  = payload?.qr_code?.entity;
  if (!payment?.id || !qrCode?.id) {
    log('⚠️  qr_code.credited — missing payment or qr_code entity');
    return;
  }

  const qrId      = qrCode.id;
  const paymentId = payment.id;
  const amount    = (payment.amount || 0) / 100;
  const bookingId = parseInt(qrCode.notes?.booking_id, 10);

  log(`💰 qr_code.credited — qr_id=${qrId} payment_id=${paymentId} amount=₹${amount} booking_id=${bookingId}`);

  if (!bookingId) {
    log('⚠️  qr_code.credited — no booking_id in QR notes, cannot record payment');
    return;
  }

  try {
    const [[booking]] = await db.execute(
      `SELECT booking_id, total_amount, amount_paid, patient_id FROM ip_bookings WHERE booking_id = ?`,
      [bookingId]
    );
    if (!booking) {
      log(`⚠️  qr_code.credited — booking_id=${bookingId} not found`);
      return;
    }

    const totalAmount   = parseFloat(booking.total_amount) || 0;
    const currentPaid   = parseFloat(booking.amount_paid)  || 0;
    const newAmountPaid = Math.min(currentPaid + amount, totalAmount);
    const newAmountDue  = Math.max(0, totalAmount - newAmountPaid);
    const newStatus     = newAmountDue <= 0 ? 'paid' : 'partial';

    await db.execute(
      `UPDATE ip_bookings SET payment_status = ?, amount_paid = ?, amount_due = ?, updated_at = NOW() WHERE booking_id = ?`,
      [newStatus, newAmountPaid, newAmountDue, bookingId]
    );

    const txnRef  = `TXN${Date.now()}QR`;
    const isPartial = newAmountDue > 0 ? 1 : 0;
    await db.execute(
      `INSERT INTO ip_payment_transactions
         (transaction_ref, booking_id, patient_id, payment_type, payment_mode,
          gross_amount, net_amount, amount_paid, amount_due,
          currency, payment_status, transaction_status, is_refund, is_partial,
          gateway_transaction_id, gateway_status, paid_at)
       VALUES (?, ?, ?, 'QR_UPI', 'RAZORPAY', ?, ?, ?, ?, 'INR', ?, ?, 0, ?, ?, 'captured', NOW())`,
      [
        txnRef, bookingId, booking.patient_id,
        amount, amount, amount, newAmountDue,
        newStatus, newAmountDue > 0 ? 'partial' : 'completed',
        isPartial, paymentId,
      ]
    );

    // Mark in-memory session so the polling endpoint can confirm to the client
    const session = qrStore.sessions.get(qrId);
    if (session) {
      session.paid      = true;
      session.paymentId = paymentId;
    }

    log(`✅ QR payment recorded — booking_id=${bookingId} payment_id=${paymentId} ₹${amount} status=${newStatus}`);
  } catch (err) {
    log(`❌ handleQrCodeCredited error: ${err.message}`);
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
     SET refund_status = 'initiated', updated_at = NOW()
     WHERE booking_id = ?`,
    [booking_id]
  );

  log(`✅ Marked settled — booking_id=${booking_id} refund_id=${refundId} ₹${amount}`);

  // Push notification to customer
  try {
    await sendToBookingOwner(
      booking_id,
      'Refund Initiated',
      `Your refund of ₹${amount} has been initiated and will be credited to your account within 5–7 working days.`,
      { type: 'refund_processed', bookingId: String(booking_id) },
    );
  } catch (err) {
    log(`⚠️  Push notification failed: ${err.message}`);
  }
}
