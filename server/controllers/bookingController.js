const db       = require('../config/db');
const settings = require('../config/settings');
const { syncBookingToClient } = require('../services/clientSync');
const { sendToBookingOwner } = require('../services/customerPush');
const fs   = require('fs');
const path = require('path');

// ── Reports-screen debug log ──────────────────────────────────────────────────
const REPORTS_LOG = path.join(__dirname, '..', 'logs', 'reports_debug.log');
function logReports(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' });
  fs.appendFileSync(REPORTS_LOG, `[${ist}] ${msg}\n`, 'utf8');
}

// ── Refund log ────────────────────────────────────────────────────────────────
const REFUND_LOG = path.join(__dirname, '..', 'logs', 'refund.log');
function logRefund(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' });
  const line = `[${ist}] ${msg}\n`;
  process.stdout.write(line);
  fs.appendFileSync(REFUND_LOG, line, 'utf8');
}
const { triggerScheduledDispatch } = require('../socket/bookingSocket');

let _io = null;
exports.setIo = (io) => { _io = io; };

function _pushToPatient(bookingId, event, payload) {
  if (!_io) return;
  _io.to(String(bookingId)).emit(event, payload);
}

// ── POST /api/bookings ─────────────────────────────────────────────────────────
exports.createBooking = async (req, res) => {
  console.log('\n🔵 [CREATE BOOKING] ─────────────────────────────');
  console.log('📥 Request body:', JSON.stringify(req.body, null, 2));

  const clientId = req.user.client_id;
  const userId   = req.user.user_id;

  const {
    patientId,
    patientIdRef      = null,
    bookingType       = 'home_collection',
    totalAmount       = 0,
    discountAmount    = 0,
    sourceChannel     = 'mobile_app',
    notes             = null,
    items             = [],
    branchId          = null,
    collectionDate    = null,
    availableSlotId   = null,
    collectionAddress = null,
    collectionPincode = null,
    collectionCity      = null,
    collectionLatitude  = null,
    collectionLongitude = null,
    paymentType       = 'pay_later',
    razorpayPaymentId = null,
    razorpayOrderId   = null,
  } = req.body;

  if (!patientId) {
    return res.status(400).json({ success: false, message: 'patientId is required' });
  }

  const isPaid     = paymentType === 'full' && razorpayPaymentId;
  const amountPaid = isPaid ? totalAmount : 0;
  const amountDue  = isPaid ? 0 : totalAmount;
  const txPaymentType = isPaid ? 'RAZORPAY' : 'PAY_LATER';

  // Future-date bookings are held until the cron scheduler fires dispatch
  const todayIST      = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const bookingStatus = (collectionDate && collectionDate > todayIST) ? 'scheduled' : 'pending';

  console.log(`👤 client_id=${clientId} | patient_id=${patientId} | type=${bookingType} | total=₹${totalAmount} | payment=${paymentType} | status=${bookingStatus}`);

  const conn = await db.getConnection();
  try {
    await conn.beginTransaction();

    // Resolve patient_id_ref from ip_patients
    let resolvedPatientIdRef = patientIdRef ?? null;
    const [[patientRow]] = await conn.execute(
      `SELECT patient_id_ref FROM ip_patients WHERE patient_id = ? LIMIT 1`,
      [patientId]
    );
    if (patientRow?.patient_id_ref) resolvedPatientIdRef = patientRow.patient_id_ref;
    console.log(`👤 patientId=${patientId} → patient_id_ref=${resolvedPatientIdRef}`);

    // Resolve slot → get lab_slot_id / technician_slot_id from ip_available_slots
    let labSlotId  = null;
    let techSlotId = null;
    if (availableSlotId) {
      const [[avSlot]] = await conn.execute(
        `SELECT lab_slot_id, technician_slot_id, booking_type
         FROM ip_available_slots WHERE available_slot_id = ?`,
        [availableSlotId]
      );
      if (avSlot) {
        labSlotId  = avSlot.lab_slot_id  ?? null;
        techSlotId = avSlot.technician_slot_id ?? null;
      }
      console.log(`🗓  available_slot_id=${availableSlotId} → lab_slot_id=${labSlotId} tech_slot_id=${techSlotId}`);
    }

    // 1. Master booking record (product_id updated after items loop)
    const bookingRef = `BK${Date.now()}`;
    const [bResult] = await conn.execute(
      `INSERT INTO ip_bookings
         (booking_ref, client_id, branch_id, booking_date, lab_slot_id, available_slot_id,
          booking_type, status, total_amount, discount_amount,
          amount_paid, amount_due,
          source_channel, notes, collection_address, postal_code, city,
          collection_latitude, collection_longitude,
          patient_id, patient_id_ref, product_id,
          payment_status, start_datetime, end_datetime, created_by, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, NOW(), NOW(), ?, NOW())`,
      [bookingRef, clientId, branchId ?? null, collectionDate ?? null, labSlotId ?? null, availableSlotId ?? null,
       bookingType, bookingStatus, totalAmount, discountAmount ?? 0, amountPaid, amountDue,
       sourceChannel, notes ?? null,
       collectionAddress ?? null, collectionPincode ?? null, collectionCity ?? null,
       collectionLatitude ?? null, collectionLongitude ?? null,
       patientId, resolvedPatientIdRef,
       isPaid ? 'paid' : 'unpaid',
       userId ?? null]
    );
    const bookingId = bResult.insertId;
    console.log(`✅ ip_bookings inserted → booking_id=${bookingId}`);

    // 2. Patient → booking link
    await conn.execute(
      `INSERT INTO ip_patient_bookings (booking_id, patient_id, patient_ref, created_at)
       VALUES (?, ?, ?, NOW())`,
      [bookingId, patientId, resolvedPatientIdRef]
    );

    // 3. Line items (tests / packages)
    const bookingItemsInserted = [];
    for (const item of items) {
      const rawId = item.packageId ? Number(item.packageId) : null;

      let validProductId = 0;
      let productName    = null;
      let docRequired    = false;
      if (rawId) {
        const [pkgCheck] = await conn.execute(
          'SELECT product_id, product_name, document_required FROM ip_products WHERE product_id = ? LIMIT 1',
          [rawId]
        );
        if (pkgCheck.length > 0) {
          validProductId = rawId;
          productName    = pkgCheck[0].product_name ?? null;
          const rawDocReq = pkgCheck[0].document_required;
          docRequired    = rawDocReq === 1 || rawDocReq === '1' || rawDocReq === 'yes';
        } else {
          console.log(`⚠️  product_id=${rawId} not found in ip_products — storing 0`);
        }
      }

      const unitPrice  = item.originalPrice ?? item.finalPrice ?? 0;
      const finalPrice = item.finalPrice ?? 0;
      const [biResult] = await conn.execute(
        `INSERT INTO ip_booking_items
           (booking_id, product_id, product_name_snapshot, patient_id, unit_price, final_price, created_at)
         VALUES (?, ?, ?, ?, ?, ?, NOW())`,
        [bookingId, validProductId, productName, patientId, unitPrice, finalPrice]
      );
      bookingItemsInserted.push({ bookingItemId: biResult.insertId, productId: validProductId, docRequired, finalPrice });
      console.log(`✅ ip_booking_items inserted → id=${biResult.insertId} product_id=${validProductId} unit=₹${unitPrice} final=₹${finalPrice}`);
    }

    // Update product_id in ip_bookings — use single item's id, 0 for multi-product
    const singleItem = bookingItemsInserted.length === 1 ? bookingItemsInserted[0] : null;
    if (singleItem && singleItem.validProductId) {
      await conn.execute(
        'UPDATE ip_bookings SET product_id = ? WHERE booking_id = ?',
        [singleItem.validProductId, bookingId]
      );
    }

    // 4. Mark this slot row as booked + increment booked count
    if (availableSlotId) {
      await conn.execute(
        'UPDATE ip_available_slots SET is_available = 0, updated_at = NOW() WHERE available_slot_id = ?',
        [availableSlotId]
      );
      console.log(`🔒 available_slot_id=${availableSlotId} marked unavailable`);
    }
    if (labSlotId) {
      await conn.execute(
        'UPDATE ip_lab_slots SET booked_count = booked_count + 1 WHERE lab_slot_id = ?',
        [labSlotId]
      );
    } else if (techSlotId) {
      await conn.execute(
        'UPDATE ip_technician_slots SET booked_count = booked_count + 1 WHERE tech_slot_id = ?',
        [techSlotId]
      );
    }

    // 5. Payment transaction record
    const txnRef = `TXN${Date.now()}`;
    await conn.execute(
      `INSERT INTO ip_payment_transactions
         (transaction_ref, booking_id, patient_id, payment_type,
          gross_amount, discount_amount, net_amount, amount_paid, amount_due,
          currency, payment_status, transaction_status, is_refund,
          gateway_transaction_id, gateway_order_id, gateway_status, paid_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'INR', ?, ?, 0, ?, ?, ?, ?)`,
      [txnRef, bookingId, patientId, txPaymentType,
       totalAmount, discountAmount ?? 0, totalAmount - (discountAmount ?? 0),
       amountPaid, amountDue,
       isPaid ? 'paid'      : 'pending',
       isPaid ? 'completed' : 'pending',
       razorpayPaymentId ?? null,
       razorpayOrderId   ?? null,
       isPaid ? 'success' : null,
       isPaid ? new Date() : null]
    );
    console.log(`✅ ip_payment_transactions inserted — ref=${txnRef}`);

    // 6. Confirm booking immediately for paid same-day orders only.
    //    Scheduled (future-date) bookings stay 'scheduled' until the cron dispatches them.
    if (isPaid && bookingStatus !== 'scheduled') {
      await conn.execute(
        `UPDATE ip_bookings SET status = 'confirmed', updated_at = NOW() WHERE booking_id = ?`,
        [bookingId]
      );
    }

    await conn.commit();
    console.log(`🎉 Booking created — booking_id=${bookingId} ref=${bookingRef}`);
    console.log('─────────────────────────────────────────────────\n');

    // Sync all bookings to client server regardless of payment status (fire-and-forget)
    syncBookingToClient(bookingId, {
      mobile: req.user.mobile,
      type:   req.user.user_type ?? 'customer',
    }).catch(err => console.error('[clientSync] unhandled:', err.message));

    res.status(201).json({
      success:     true,
      bookingId,
      bookingRef,
      isScheduled: bookingStatus === 'scheduled',
      bookingItems: bookingItemsInserted.map(i => ({
        bookingItemId: i.bookingItemId,
        productId:     i.productId,
        docRequired:   i.docRequired,
      })),
    });
  } catch (err) {
    await conn.rollback();
    console.error('❌ createBooking FAILED:', err.message);
    res.status(500).json({
      success: false,
      message: 'Server error',
      detail:   err.message,
      sqlState: err.sqlState,
      code:     err.code,
    });
  } finally {
    conn.release();
  }
};

// ── GET /api/bookings/mine ─────────────────────────────────────────────────────
exports.getMyBookings = async (req, res) => {
  const clientId  = req.user.client_id;
  const patientId = req.user.id;
  console.log(`\n🔍 [GET MY BOOKINGS] client_id=${clientId} patient_id=${patientId}`);
  try {
    const [rows] = await db.execute(
      `SELECT
         b.booking_id              AS booking_id_num,
         b.booking_ref,
         b.visit_group_id,
         b.status                  AS booking_status,
         b.booking_type,
         b.booking_date            AS collection_date,
         b.total_amount,
         b.discount_amount,
         b.refund_amount,
         b.refund_status,
         b.created_at,
         b.branch_id,
         b.patient_id,
         b.collection_address,
         b.postal_code             AS collection_pincode,
         b.city                    AS collection_city,
         br.branch_name            AS branch_name,
         br.branch_address         AS branch_address,
         br.branch_city            AS branch_location,
         br.branch_pincode         AS branch_pincode,
         pat.patient_name          AS patient_name,
         pat.patient_mobile        AS patient_mobile,
         TIME_FORMAT(av.slot_time, '%h:%i %p') AS slot_time_formatted,
         COALESCE(bpt.payment_status,
           IF(bpt.transaction_status='completed','paid','pending')) AS payment_status,
         bpt.amount_paid,
         bpt.amount_due,
         (SELECT bd.doc_status
          FROM ip_booking_documents bd
          WHERE bd.booking_id = b.booking_id AND bd.file_description = 'prescription'
          ORDER BY bd.created_at DESC LIMIT 1) AS prescription_status,
         (SELECT JSON_ARRAYAGG(bd.file_path)
          FROM ip_booking_documents bd
          WHERE bd.booking_id = b.booking_id AND bd.file_description = 'prescription') AS presc_image_url,
         GROUP_CONCAT(
           CASE WHEN bi.booking_item_id IS NOT NULL
           THEN CONCAT(
             IFNULL(bi.product_id, '0'),                                          ':::',
             IFNULL(bi.product_name_snapshot, IFNULL(pkg.product_name, 'Test')), ':::',
             IFNULL(bi.final_price, '0'),                                         ':::',
             'test'
           ) END
           ORDER BY bi.booking_item_id SEPARATOR '|||'
         ) AS test_items,
         SUM(bi.final_price) AS items_total,
         tc.technician_id,
         tc.collection_status,
         tc.collection_latitude,
         tc.collection_longitude,
         tc.assigned_at,
         tc.en_route_at,
         tc.arrived_at,
         tc.collected_at,
         tc.completed_at,
         u.user_name        AS tech_name,
         u.user_mobile_no   AS tech_mobile,
         tech.tech_photo    AS tech_photo,
         f.overall_rating,
         f.feedback_comments,
         (SELECT tr.report_url
          FROM ip_test_results tr
          WHERE tr.booking_id = b.booking_id
            AND tr.result_status = 'released'
            AND tr.report_url IS NOT NULL
          LIMIT 1) AS report_url,
         (SELECT COUNT(*)
          FROM ip_test_results tr
          WHERE tr.booking_id = b.booking_id
            AND tr.result_status = 'released') AS released_results_count
       FROM ip_bookings b
       LEFT JOIN ip_patients pat       ON pat.patient_id  = b.patient_id
       LEFT JOIN ip_branches br        ON br.branch_id    = b.branch_id
       LEFT JOIN ip_available_slots av   ON av.available_slot_id = b.available_slot_id
       LEFT JOIN ip_booking_items bi   ON bi.booking_id   = b.booking_id
       LEFT JOIN ip_products pkg       ON pkg.product_id  = bi.product_id
       LEFT JOIN ip_payment_transactions bpt
         ON bpt.transaction_id = (
           SELECT t2.transaction_id FROM ip_payment_transactions t2
           WHERE t2.booking_id = b.booking_id AND (t2.is_refund = 0 OR t2.is_refund IS NULL)
           ORDER BY t2.created_at DESC LIMIT 1
         )
       LEFT JOIN ip_technician_collection tc ON tc.booking_id = b.booking_id
       LEFT JOIN ip_technicians tech ON tech.technician_id = tc.technician_id
       LEFT JOIN ip_users u          ON u.user_id = tech.user_id
       LEFT JOIN ip_feedback f        ON f.booking_id = b.booking_id
       WHERE (
         b.client_id = ?
         OR b.booking_id IN (
           SELECT pb.booking_id FROM ip_patient_bookings pb WHERE pb.patient_id = ?
         )
       )
         AND b.deleted_at IS NULL
       GROUP BY b.booking_id
       ORDER BY b.created_at DESC
       LIMIT 50`,
      [clientId, patientId]
    );
    console.log(`✅ Found ${rows.length} booking(s) for client ${clientId}`);

    // ── Reports-screen debug ─────────────────────────────────────────────────
    const reportableRows = rows.filter(r => r.report_url || parseInt(r.released_results_count || 0) > 0);
    logReports(`━━━ getMyBookings  client=${clientId} patient=${patientId} ━━━`);
    logReports(`  Total bookings returned : ${rows.length}`);
    logReports(`  With results (→ Reports): ${reportableRows.length}`);
    logReports(`  All statuses            : ${[...new Set(rows.map(r => r.booking_status))].join(', ') || '(none)'}`);

    rows.forEach((r, i) => {
      const serviceCharge = parseFloat(r.total_amount || 0) - parseFloat(r.items_total || 0);
      const hasReportUrl  = !!r.report_url;
      const releasedCount = parseInt(r.released_results_count || 0);
      const goesToReports = hasReportUrl || releasedCount > 0;
      const reason = goesToReports
        ? (hasReportUrl ? 'has report_url' : `${releasedCount} released result(s)`)
        : 'no report_url, no released results';
      logReports(
        `  [${i + 1}] ${r.booking_ref || r.booking_id_num}` +
        `  status=${r.booking_status}` +
        `  type=${r.booking_type}` +
        `  → reports=${goesToReports ? `YES ✅ (${reason})` : `NO  ❌  (${reason})`}`
      );
      logReports(
        `       total=${r.total_amount}  items_total=${r.items_total}` +
        `  service_charge=${serviceCharge.toFixed(2)}` +
        `  payment_status=${r.payment_status || '(none)'}`
      );
      logReports(
        `       report_url=${r.report_url ? `PRESENT → ${r.report_url}` : 'NULL'}` +
        `  released_results=${releasedCount}` +
        `  collection_status=${r.collection_status || '(none)'}`
      );
      const testSummary = (r.test_items || '')
        .split('|||')
        .filter(Boolean)
        .map(t => { const p = t.split(':::'); return p[1] || p[0]; })
        .join(', ');
      logReports(`       tests=[${testSummary || '(none)'}]`);
    });

    if (reportableRows.length === 0) {
      logReports(`  ⚠️  No bookings with released results — reports screen will show empty state`);
    }
    logReports('');
    // ── end reports debug ────────────────────────────────────────────────────

    res.json({ success: true, bookings: rows });
  } catch (err) {
    console.error('❌ getMyBookings FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── POST /api/bookings/:bookingId/cancel ──────────────────────────────────────
exports.cancelBooking = async (req, res) => {
  const clientId  = req.user.client_id;
  const patientId = req.user.id;
  const bookingId = parseInt(req.params.bookingId, 10);
  const { reason } = req.body;

  try {
    const allowedBookingStatuses    = settings.getList('cancel_allowed_booking_statuses',    ['pending', 'scheduled']);
    const allowedCollectionStatuses = settings.getList('cancel_allowed_collection_statuses', ['assigned', 'en_route', 'arrived']);
    const chargeStatuses            = settings.getList('cancel_charge_trigger_statuses',     ['arrived']);
    const serviceCharge             = parseFloat(settings.get('cancel_service_charge_amount', '0')) || 0;
    const cutoffMinutes             = parseInt(settings.get('cancel_cutoff_minutes', '0'), 10) || 0;

    // Verify booking ownership
    const [[booking]] = await db.execute(
      `SELECT b.booking_id, b.status, b.booking_type, b.total_amount, b.available_slot_id, b.booking_date,
              b.visit_group_id,
              COALESCE(pt.amount_paid, 0) AS amount_paid,
              COALESCE((SELECT SUM(bi.final_price) FROM ip_booking_items bi WHERE bi.booking_id = b.booking_id), 0) AS items_total
       FROM ip_bookings b
       LEFT JOIN ip_payment_transactions pt
         ON pt.booking_id = b.booking_id AND (pt.is_refund = 0 OR pt.is_refund IS NULL)
       WHERE b.booking_id = ?
         AND (b.client_id = ? OR b.patient_id = ?)
         AND b.deleted_at IS NULL
       ORDER BY pt.created_at DESC
       LIMIT 1`,
      [bookingId, clientId, patientId]
    );

    if (!booking) {
      return res.status(404).json({ success: false, message: 'Booking not found' });
    }

    if (!allowedBookingStatuses.includes(booking.status)) {
      return res.status(400).json({ success: false, message: `Cannot cancel a booking with status: ${booking.status}` });
    }

    // Enforce slot cutoff if configured
    if (cutoffMinutes > 0 && booking.available_slot_id) {
      const [[slot]] = await db.execute(
        `SELECT slot_time FROM ip_available_slots WHERE available_slot_id = ?`,
        [booking.available_slot_id]
      );
      if (slot) {
        const istOffsetMs      = (5 * 60 + 30) * 60 * 1000;
        const istNow           = new Date(Date.now() + istOffsetMs);
        const slotDate         = new Date(booking.booking_date);
        const [h, m]           = slot.slot_time.split(':');
        slotDate.setUTCHours(parseInt(h, 10) - 5, parseInt(m, 10) - 30, 0, 0);
        const minutesUntilSlot = (slotDate - istNow) / 60000;
        if (minutesUntilSlot < cutoffMinutes) {
          return res.status(400).json({
            success: false,
            message: `Cancellation is not allowed within ${cutoffMinutes} minutes of the slot time`,
          });
        }
      }
    }

    // Technician collection checks only apply to home collection
    const isHomeCollection = booking.booking_type === 'home_collection';
    let tc = null;
    if (isHomeCollection) {
      const [[row]] = await db.execute(
        `SELECT collection_status, arrived_at FROM ip_technician_collection WHERE booking_id = ? LIMIT 1`,
        [bookingId]
      );
      tc = row ?? null;
      if (tc && !allowedCollectionStatuses.includes(tc.collection_status)) {
        return res.status(400).json({ success: false, message: 'Cannot cancel — sample collection has already started' });
      }
    }

    // Calculate refund
    const amountPaid          = parseFloat(booking.amount_paid) || 0;
    const techHasArrived      = isHomeCollection && tc && chargeStatuses.includes(tc.collection_status);
    // Use the actual service charge on this booking (total - tests).
    // For family bookings the service charge sits only on one member's booking;
    // if this booking has no service charge component, nothing is deducted.
    const bookingServiceCharge = Math.max(0, parseFloat(booking.total_amount) - parseFloat(booking.items_total));
    const chargeApplied        = techHasArrived && bookingServiceCharge > 0 ? bookingServiceCharge : 0;
    const refundAmount         = Math.max(0, amountPaid - chargeApplied);
    const refundStatus         = amountPaid > 0 ? 'pending' : 'none';

    await db.execute(
      `UPDATE ip_bookings
       SET status = 'cancelled',
           cancelled_at = NOW(),
           cancelled_by = 'customer',
           cancellation_reason = ?,
           refund_amount = ?,
           refund_status = ?
       WHERE booking_id = ?`,
      [reason ?? null, refundAmount, refundStatus, bookingId]
    );

    // Cascade to ip_technician_collection so the technician's dashboard list
    // (which filters on collection_status) stops showing this booking as an
    // active job. Mirrors what the admin cancellation path (updateAdminStatus)
    // already does — this customer-facing path previously only updated
    // ip_bookings, leaving the technician's card visible and fully actionable
    // indefinitely even after the patient cancelled.
    if (tc) {
      await db.execute(
        `UPDATE ip_technician_collection
         SET collection_status = 'cancelled', updated_at = NOW()
         WHERE booking_id = ?`,
        [bookingId]
      );
    }

    // ── Razorpay refund (fire if paid online) ──────────────────────────────────
    let finalRefundStatus = refundStatus;
    if (refundAmount > 0) {
      const [[txn]] = await db.execute(
        `SELECT gateway_transaction_id FROM ip_payment_transactions
         WHERE booking_id = ? AND (is_refund = 0 OR is_refund IS NULL)
           AND gateway_transaction_id IS NOT NULL
         ORDER BY created_at DESC LIMIT 1`,
        [bookingId]
      );
      if (txn?.gateway_transaction_id) {
        try {
          const rzpKeyId     = process.env.RAZORPAY_KEY_ID;
          const rzpKeySecret = process.env.RAZORPAY_KEY_SECRET;
          const authHeader   = 'Basic ' + Buffer.from(`${rzpKeyId}:${rzpKeySecret}`).toString('base64');
          const rzpRes = await fetch(
            `https://api.razorpay.com/v1/payments/${txn.gateway_transaction_id}/refund`,
            {
              method:  'POST',
              headers: { 'Authorization': authHeader, 'Content-Type': 'application/json' },
              body:    JSON.stringify({ amount: Math.round(refundAmount * 100) }),
            }
          );
          const rzpBody = await rzpRes.json();
          if (rzpRes.ok && rzpBody.id) {
            const refundTxnRef = `RFN${Date.now()}`;
            await db.execute(
              `INSERT INTO ip_payment_transactions
                 (transaction_ref, booking_id, patient_id, payment_type,
                  gross_amount, net_amount, amount_paid, amount_due,
                  currency, payment_status, transaction_status, is_refund,
                  gateway_transaction_id, gateway_status, paid_at)
               VALUES (?, ?, ?, 'RAZORPAY', ?, ?, ?, 0, 'INR', 'refunded', 'completed', 1, ?, 'refunded', NOW())`,
              [refundTxnRef, bookingId, booking.patient_id ?? null,
               refundAmount, refundAmount, refundAmount,
               rzpBody.id]
            );
            await db.execute(
              `UPDATE ip_bookings SET refund_status = 'processed' WHERE booking_id = ?`,
              [bookingId]
            );
            finalRefundStatus = 'processed';
            logRefund(`✅ SUCCESS — booking_id=${bookingId} payment_id=${txn.gateway_transaction_id} refund_id=${rzpBody.id} amount=₹${refundAmount}`);
          } else {
            logRefund(`❌ FAILED — booking_id=${bookingId} payment_id=${txn.gateway_transaction_id} amount=₹${refundAmount} response=${JSON.stringify(rzpBody)}`);
          }
        } catch (rzpErr) {
          logRefund(`❌ ERROR — booking_id=${bookingId} error=${rzpErr.message}`);
        }
      }
    }

    syncBookingToClient(bookingId, {
      mobile: req.user.mobile,
      type:   req.user.user_type ?? 'customer',
    }).catch(err => console.error('[clientSync] cancel sync failed:', err.message));

    logRefund(`[cancel] booking_id=${bookingId} refund=₹${refundAmount} status=${finalRefundStatus} charge=₹${chargeApplied}`);
    res.json({ success: true, refund_amount: refundAmount, refund_status: finalRefundStatus, service_charge_applied: chargeApplied });
  } catch (err) {
    console.error('❌ cancelBooking FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── POST /api/bookings/:bookingId/pay ─────────────────────────────────────────
exports.payBooking = async (req, res) => {
  const { bookingId } = req.params;
  const { razorpayPaymentId, razorpayOrderId, amount } = req.body;
  const clientId = req.user.client_id;

  if (!razorpayPaymentId || !amount) {
    return res.status(400).json({ success: false, message: 'razorpayPaymentId and amount are required' });
  }

  const conn = await db.getConnection();
  try {
    await conn.beginTransaction();

    const [[booking]] = await conn.execute(
      `SELECT booking_id, patient_id, total_amount
       FROM ip_bookings
       WHERE booking_id = ? AND client_id = ? AND deleted_at IS NULL`,
      [bookingId, clientId]
    );
    if (!booking) {
      await conn.rollback();
      return res.status(404).json({ success: false, message: 'Booking not found' });
    }

    await conn.execute(
      `UPDATE ip_payment_transactions
       SET payment_type = 'RAZORPAY',
           payment_status = 'paid', transaction_status = 'completed',
           amount_paid = ?, amount_due = 0,
           gateway_transaction_id = ?, gateway_order_id = ?,
           gateway_status = 'success', paid_at = NOW(), updated_at = NOW()
       WHERE booking_id = ? AND (is_refund = 0 OR is_refund IS NULL)`,
      [amount, razorpayPaymentId, razorpayOrderId ?? null, bookingId]
    );

    await conn.execute(
      `UPDATE ip_bookings
       SET status = 'confirmed', payment_status = 'paid',
           amount_paid = ?, amount_due = 0, updated_at = NOW()
       WHERE booking_id = ?`,
      [amount, bookingId]
    );

    await conn.commit();
    console.log(`✅ payBooking → booking_id=${bookingId} paid ₹${amount}`);

    // Sync to client server now that payment is confirmed (fire-and-forget)
    syncBookingToClient(Number(bookingId), {
      mobile: req.user.mobile,
      type:   req.user.user_type ?? 'customer',
    }).catch(err => console.error('[clientSync] unhandled:', err.message));

    res.json({ success: true });
  } catch (err) {
    await conn.rollback();
    console.error('❌ payBooking FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  } finally {
    conn.release();
  }
};

// ── GET /api/bookings/:bookingId/results/:resultId/proxy ─────────────────────
exports.proxyReport = async (req, res) => {
  const bookingId = parseInt(req.params.bookingId, 10);
  const resultId  = parseInt(req.params.resultId,  10);
  const { client_id, id: patientId } = req.user;
  try {
    const [[booking]] = await db.execute(
      `SELECT booking_id FROM ip_bookings
       WHERE booking_id = ? AND (client_id = ? OR patient_id = ?) AND deleted_at IS NULL LIMIT 1`,
      [bookingId, client_id, patientId]
    );
    if (!booking) return res.status(404).json({ success: false, message: 'Booking not found' });

    const [[result]] = await db.execute(
      `SELECT report_url FROM ip_test_results
       WHERE result_id = ? AND booking_id = ? AND result_status = 'released' LIMIT 1`,
      [resultId, bookingId]
    );
    if (!result?.report_url) return res.status(404).json({ success: false, message: 'Report not found' });

    const upstream = await fetch(result.report_url);
    if (!upstream.ok) {
      return res.status(502).json({ success: false, message: `Upstream error: ${upstream.status}` });
    }
    const buffer = Buffer.from(await upstream.arrayBuffer());
    res.setHeader('Content-Type', 'application/pdf');
    res.setHeader('Content-Disposition', `attachment; filename="report_${resultId}.pdf"`);
    res.send(buffer);
  } catch (err) {
    console.error('proxyReport error:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── GET /api/bookings/:bookingId/results ─────────────────────────────────────
exports.getBookingResults = async (req, res) => {
  const bookingId = parseInt(req.params.bookingId, 10);
  const clientId  = req.user.client_id;
  const patientId = req.user.id;
  try {
    // Verify booking belongs to this account
    const [[booking]] = await db.execute(
      `SELECT booking_id FROM ip_bookings
       WHERE booking_id = ? AND (client_id = ? OR patient_id = ?) AND deleted_at IS NULL LIMIT 1`,
      [bookingId, clientId, patientId]
    );
    if (!booking) return res.status(404).json({ success: false, message: 'Booking not found' });

    const [rows] = await db.execute(
      `SELECT result_id, test_name, test_code, result_value, result_unit,
              reference_range, result_flag, result_remarks, report_url,
              result_file_path, released_at
       FROM ip_test_results
       WHERE booking_id = ? AND result_status = 'released'
       ORDER BY result_id ASC`,
      [bookingId]
    );
    res.json({ success: true, results: rows });
  } catch (err) {
    console.error('❌ getBookingResults FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── GET /api/bookings/patient/:patientId ───────────────────────────────────────
exports.getPatientBookings = async (req, res) => {
  const { patientId } = req.params;
  try {
    const [rows] = await db.execute(
      `SELECT b.*,
              tc.collection_id, tc.technician_id,
              tc.collection_status, tc.collection_date,
              tc.assigned_at, tc.en_route_at, tc.arrived_at, tc.collected_at,
              tc.collection_address, tc.collection_latitude, tc.collection_longitude,
              u.user_name        AS tech_name,
              u.user_mobile_no   AS tech_mobile,
              tech.tech_photo    AS tech_photo,
              GROUP_CONCAT(DISTINCT pkg.product_name ORDER BY pkg.product_name SEPARATOR ', ') AS test_names,
              SUM(bi.final_price) AS items_total
       FROM ip_bookings b
       JOIN ip_patient_bookings pb ON pb.booking_id = b.booking_id
       LEFT JOIN ip_technician_collection tc ON tc.booking_id = b.booking_id
       LEFT JOIN ip_technicians tech ON tech.technician_id = tc.technician_id
       LEFT JOIN ip_users u          ON u.user_id = tech.user_id
       LEFT JOIN ip_booking_items bi ON bi.booking_id = b.booking_id
       LEFT JOIN ip_products pkg ON pkg.product_id = bi.product_id
       WHERE pb.patient_id = ?
         AND b.deleted_at IS NULL
       GROUP BY b.booking_id
       ORDER BY b.created_at DESC
       LIMIT 50`,
      [patientId]
    );
    res.json({ success: true, bookings: rows });
  } catch (err) {
    console.error('❌ getPatientBookings FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── GET /api/bookings/:bookingId ───────────────────────────────────────────────
exports.getBooking = async (req, res) => {
  const { bookingId } = req.params;
  try {
    const [rows] = await db.execute(
      `SELECT b.*,
              tc.collection_id, tc.technician_id, tc.slot_id,
              tc.collection_status, tc.collection_date,
              tc.assigned_at, tc.en_route_at, tc.arrived_at,
              tc.collected_at, tc.completed_at,
              tc.collection_address, tc.collection_latitude, tc.collection_longitude,
              u.user_name        AS tech_name,
              u.user_mobile_no   AS tech_mobile,
              tech.tech_photo    AS tech_photo,
              GROUP_CONCAT(DISTINCT pkg.product_name ORDER BY pkg.product_name SEPARATOR ', ') AS test_names,
              GROUP_CONCAT(DISTINCT bi.product_id ORDER BY bi.product_id SEPARATOR ',') AS package_ids,
              SUM(bi.final_price) AS items_total
       FROM ip_bookings b
       LEFT JOIN ip_technician_collection tc ON tc.booking_id = b.booking_id
       LEFT JOIN ip_technicians tech ON tech.technician_id = tc.technician_id
       LEFT JOIN ip_users u          ON u.user_id = tech.user_id
       LEFT JOIN ip_booking_items bi ON bi.booking_id = b.booking_id
       LEFT JOIN ip_products pkg ON pkg.product_id = bi.product_id
       WHERE b.booking_id = ?
         AND b.deleted_at IS NULL
       GROUP BY b.booking_id`,
      [bookingId]
    );
    if (!rows.length) {
      return res.status(404).json({ success: false, message: 'Booking not found' });
    }
    res.json({ success: true, booking: rows[0] });
  } catch (err) {
    console.error('❌ getBooking FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── GET /api/bookings/:bookingId/items ────────────────────────────────────────
exports.getItems = async (req, res) => {
  const { bookingId } = req.params;
  try {
    const [rows] = await db.execute(
      `SELECT bi.booking_item_id,
              bi.product_id,
              COALESCE(bi.product_name_snapshot, p.product_name) AS name,
              COALESCE(p.product_category, 'General')            AS category,
              bi.final_price                                      AS price,
              CASE WHEN p.document_required IN (1, '1', 'yes') THEN 1 ELSE 0 END AS doc_required
       FROM ip_booking_items bi
       LEFT JOIN ip_products p ON p.product_id = bi.product_id
       WHERE bi.booking_id = ?
       ORDER BY bi.booking_item_id ASC`,
      [bookingId]
    );
    res.json({ success: true, items: rows });
  } catch (err) {
    console.error('❌ getItems FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── POST /api/bookings/:bookingId/items ───────────────────────────────────────
exports.addItem = async (req, res) => {
  const { bookingId } = req.params;
  const { productId }  = req.body;
  if (!productId) {
    return res.status(400).json({ success: false, message: 'productId is required' });
  }
  try {
    // Get product details
    const [[product]] = await db.execute(
      `SELECT product_id, product_name, product_category, product_price
       FROM ip_products WHERE product_id = ? AND product_active = 1 LIMIT 1`,
      [productId]
    );
    if (!product) {
      return res.status(404).json({ success: false, message: 'Product not found' });
    }
    // Get patient_id from the booking
    const [[booking]] = await db.execute(
      `SELECT patient_id FROM ip_bookings WHERE booking_id = ? LIMIT 1`,
      [bookingId]
    );
    if (!booking) {
      return res.status(404).json({ success: false, message: 'Booking not found' });
    }
    const price = parseFloat(product.product_price ?? 0) || 0;
    const [result] = await db.execute(
      `INSERT INTO ip_booking_items
         (booking_id, product_id, product_name_snapshot, patient_id, unit_price, final_price, created_at)
       VALUES (?, ?, ?, ?, ?, ?, NOW())`,
      [bookingId, product.product_id, product.product_name, booking.patient_id, price, price]
    );
    res.status(201).json({
      success: true,
      item: {
        bookingItemId: result.insertId,
        productId:     product.product_id,
        name:          product.product_name,
        category:      product.product_category ?? 'General',
        price:         price,
      },
    });
  } catch (err) {
    console.error('❌ addItem FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── DELETE /api/bookings/:bookingId/items/:bookingItemId ──────────────────────
exports.removeItem = async (req, res) => {
  const { bookingId, bookingItemId } = req.params;
  try {
    const [result] = await db.execute(
      `DELETE FROM ip_booking_items
       WHERE booking_item_id = ? AND booking_id = ?`,
      [bookingItemId, bookingId]
    );
    if (result.affectedRows === 0) {
      return res.status(404).json({ success: false, message: 'Item not found' });
    }
    res.json({ success: true });
  } catch (err) {
    console.error('❌ removeItem FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── GET /api/bookings/:bookingId/linked-patients ─────────────────────────────
// Returns additional patients linked to this booking by the technician
exports.getLinkedPatients = async (req, res) => {
  const { bookingId } = req.params;
  try {
    // UNION: (1) old approach — patients added to ip_patient_bookings of parent
    //        (2) new approach — sibling bookings linked via visit_group_id
    const [rows] = await db.execute(
      `SELECT p.patient_id, p.patient_name, p.patient_mobile,
              NULL AS booking_ref, NULL AS booking_id,
              NULL AS total_amount, NULL AS amount_due, NULL AS payment_status
       FROM ip_patient_bookings pb
       JOIN ip_patients p ON p.patient_id = pb.patient_id
       WHERE pb.booking_id = ?
         AND pb.patient_id != COALESCE(
           (SELECT patient_id FROM ip_bookings WHERE booking_id = ? LIMIT 1), 0
         )

       UNION

       SELECT p.patient_id, p.patient_name, p.patient_mobile,
              b2.booking_ref, b2.booking_id,
              b2.total_amount, b2.amount_due, b2.payment_status
       FROM ip_bookings b1
       JOIN ip_bookings b2 ON b2.visit_group_id = b1.visit_group_id
                           AND b2.booking_id != b1.booking_id
                           AND b2.deleted_at IS NULL
       JOIN ip_patients p ON p.patient_id = b2.patient_id
       WHERE b1.booking_id = ?
         AND b1.visit_group_id IS NOT NULL

       ORDER BY patient_id ASC`,
      [bookingId, bookingId, bookingId]
    );
    res.json({ success: true, patients: rows });
  } catch (err) {
    console.error('❌ getLinkedPatients FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── PUT /api/bookings/:bookingId/lab-status ────────────────────────────────────
exports.updateLabStatus = async (req, res) => {
  const { status, reportUrl, reportId } = req.body;
  const { bookingId } = req.params;

  const allowed = ['sample_received', 'test_in_progress', 'report_ready'];
  if (!allowed.includes(status)) {
    return res.status(400).json({
      success: false,
      message: `status must be one of: ${allowed.join(', ')}`,
    });
  }

  const socketEventMap = {
    sample_received:  'sample_received_at_lab',
    test_in_progress: 'test_in_progress',
    report_ready:     'report_ready',
  };

  try {
    await db.execute(
      `UPDATE ip_technician_collection
       SET collection_status=?, updated_at=NOW()
       WHERE booking_id=?`,
      [status, bookingId]
    );

    if (status === 'report_ready') {
      await db.execute(
        `UPDATE ip_bookings SET status='completed', updated_at=NOW() WHERE booking_id=?`,
        [bookingId]
      );
    }

    const socketPayload = { bookingId: Number(bookingId) };
    if (status === 'report_ready') {
      socketPayload.reportUrl = reportUrl ?? null;
      socketPayload.reportId  = reportId  ?? null;
    }

    _pushToPatient(bookingId, socketEventMap[status], socketPayload);
    res.json({ success: true, status });
  } catch (err) {
    console.error('❌ updateLabStatus FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};
exports.releaseResult = async (req, res) => {
  const secret = process.env.ADMIN_WEBHOOK_SECRET;
  if (!secret || req.headers['x-admin-secret'] !== secret) {
    return res.status(401).json({ success: false, message: 'Unauthorized' });
  }

  const { bookingId, resultId } = req.params;
  try {
    const [[result]] = await db.execute(
      `SELECT result_id, test_name FROM ip_test_results
       WHERE result_id = ? AND booking_id = ? AND result_status = 'released'`,
      [resultId, bookingId]
    );

    if (!result) {
      return res.status(404).json({ success: false, message: 'Released result not found for this booking' });
    }

    const testName = result.test_name ?? 'Test';

    sendToBookingOwner(
      Number(bookingId),
      'Report Ready 📄',
      `${testName} report is ready. Open the app to view and download it.`,
      { type: 'results_released', booking_id: String(bookingId), result_id: String(resultId) }
    );

    res.json({ success: true });
  } catch (err) {
    console.error('❌ releaseResult FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── PUT /api/bookings/:bookingId/admin-status ─────────────────────────────────
// Admin override for the full booking status lifecycle.
// Updates ip_bookings, ip_technician_collection, AND ip_booking_requests
// in one atomic operation so all three tables stay in sync.
exports.updateAdminStatus = async (req, res) => {
  const { bookingId }                   = req.params;
  const { status, technicianId = null } = req.body;

  // ── Status maps ────────────────────────────────────────────────────────────
  // Which ip_bookings.status each admin status resolves to (null = no change)
  const BOOKING_STATUS_MAP = {
    pending:              'pending',
    confirmed:            'confirmed',
    technician_assigned:  'confirmed',   // tech assigned → booking is confirmed
    en_route:              null,
    arrived:               null,
    sample_collected:      null,
    submitted_to_lab:      null,
    processing:            null,
    partial:               null,
    results_ready:        'completed',
    completed:            'completed',
    cancelled:            'cancelled',
  };

  // Which ip_technician_collection.collection_status each admin status resolves to
  const COLLECTION_STATUS_MAP = {
    technician_assigned: 'assigned',
    en_route:            'en_route',
    arrived:             'arrived',
    sample_collected:    'sample_collected',
    submitted_to_lab:    'handed_to_lab',
    processing:          'collected',
    partial:             'collected',
    results_ready:       'completed',
    completed:           'completed',
    cancelled:           'cancelled',
  };

  if (!Object.prototype.hasOwnProperty.call(BOOKING_STATUS_MAP, status)) {
    return res.status(400).json({
      success: false,
      message: `Invalid status. Allowed: ${Object.keys(BOOKING_STATUS_MAP).join(', ')}`,
    });
  }

  try {
    // ── 1. Update ip_bookings ──────────────────────────────────────────────
    const newBookingStatus = BOOKING_STATUS_MAP[status];
    if (newBookingStatus) {
      await db.execute(
        `UPDATE ip_bookings SET status = ?, updated_at = NOW() WHERE booking_id = ?`,
        [newBookingStatus, bookingId]
      );
    }

    // ── 2. Update / create ip_technician_collection ───────────────────────
    const collectionStatus = COLLECTION_STATUS_MAP[status];
    if (collectionStatus) {
      const [[existing]] = await db.execute(
        `SELECT tc.technician_id FROM ip_technician_collection tc WHERE tc.booking_id = ? LIMIT 1`,
        [bookingId]
      );

      if (existing) {
        // Row already exists — just update the status
        await db.execute(
          `UPDATE ip_technician_collection
           SET collection_status = ?, updated_at = NOW()
           WHERE booking_id = ?`,
          [collectionStatus, bookingId]
        );
      } else if (technicianId) {
        // No row yet — admin is manually assigning a technician; create the row
        const [[booking]] = await db.execute(
          `SELECT b.booking_date, b.collection_address, b.collection_latitude, b.collection_longitude,
                  b.slot_id, pb.patient_id
           FROM ip_bookings b
           LEFT JOIN ip_patient_bookings pb ON pb.booking_id = b.booking_id
           WHERE b.booking_id = ? LIMIT 1`,
          [bookingId]
        );
        const [[techRow]] = await db.execute(
          `SELECT u.user_name FROM ip_technicians t
           JOIN ip_users u ON u.user_id = t.user_id
           WHERE t.technician_id = ? LIMIT 1`,
          [technicianId]
        );
        await db.execute(
          `INSERT INTO ip_technician_collection
             (booking_id, technician_id, technician_name, collection_status, collection_date,
              collection_address, collection_latitude, collection_longitude,
              patient_id, slot_id, assigned_at, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW(), NOW())
           ON DUPLICATE KEY UPDATE
             collection_status = VALUES(collection_status),
             technician_name   = VALUES(technician_name),
             updated_at        = NOW()`,
          [
            bookingId, technicianId, techRow?.user_name ?? null, collectionStatus,
            booking?.booking_date         ?? null,
            booking?.collection_address   ?? null,
            booking?.collection_latitude  ?? null,
            booking?.collection_longitude ?? null,
            booking?.patient_id           ?? null,
            booking?.slot_id              ?? null,
          ]
        );
      }
      // If no row and no technicianId provided, skip — can't create without a tech
    }

    // ── 3. Update ip_booking_requests ─────────────────────────────────────
    if (status === 'technician_assigned') {
      // Resolve the technician to record against the request
      const [[tc]] = await db.execute(
        `SELECT technician_id FROM ip_technician_collection WHERE booking_id = ? LIMIT 1`,
        [bookingId]
      );
      const assignedTechId = tc?.technician_id ?? technicianId;

      if (assignedTechId) {
        // Fetch technician display name to keep ip_booking_requests consistent with socket inserts
        const [[techRow]] = await db.execute(
          `SELECT u.user_name FROM ip_technicians t
           JOIN ip_users u ON u.user_id = t.user_id
           WHERE t.technician_id = ? LIMIT 1`,
          [assignedTechId]
        );
        const techName = techRow?.user_name || '';

        await db.execute(
          `INSERT INTO ip_booking_requests
             (booking_id, technician_id, technician_name, request_status, total_attempts, max_attempts, last_sent_at, responded_at, updated_at)
           VALUES (?, ?, ?, 'accepted', 1, 1, NOW(), NOW(), NOW())
           ON DUPLICATE KEY UPDATE
             request_status = 'accepted',
             responded_at   = NOW(),
             updated_at     = NOW()`,
          [bookingId, assignedTechId, techName]
        );
        // Expire any other pending requests for this booking
        await db.execute(
          `UPDATE ip_booking_requests
           SET request_status = 'expired', updated_at = NOW()
           WHERE booking_id = ? AND technician_id != ? AND request_status = 'pending'`,
          [bookingId, assignedTechId]
        );
      }
    } else if (status === 'cancelled') {
      await db.execute(
        `UPDATE ip_booking_requests
         SET request_status = 'expired', updated_at = NOW()
         WHERE booking_id = ? AND request_status = 'pending'`,
        [bookingId]
      );
    }

    console.log(`✅ updateAdminStatus — booking_id=${bookingId} → ${status}`);
    res.json({ success: true, status });
  } catch (err) {
    console.error('❌ updateAdminStatus FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error', detail: err.message });
  }
};

exports.updateBookingItems = async (req, res) => {
  const { bookingId } = req.params;
  const { items = [], serviceCharge = 0 } = req.body;
  const clientId = req.user.client_id;

  if (!items.length) {
    return res.status(400).json({ success: false, message: 'At least one item required' });
  }

  const conn = await db.getConnection();
  try {
    await conn.beginTransaction();

    const [[booking]] = await conn.execute(
      `SELECT b.booking_id, b.patient_id, b.status, b.amount_paid, b.payment_status,
              tc.collection_status
       FROM ip_bookings b
       LEFT JOIN ip_technician_collection tc ON tc.booking_id = b.booking_id
       WHERE b.booking_id = ? AND b.client_id = ? AND b.deleted_at IS NULL`,
      [bookingId, clientId]
    );
    if (!booking) {
      await conn.rollback();
      return res.status(404).json({ success: false, message: 'Booking not found' });
    }

    // Dynamic rules from ip_settings (defaults match the seeded values)
    const blockIfPaid    = settings.getBool('booking_edit_block_if_paid', true);
    const blockedStatuses = settings.getList(
      'booking_edit_block_collection_statuses',
      ['en_route', 'arrived', 'collection_started', 'sample_collected', 'handed_to_lab']
    );

    if (blockIfPaid && booking.payment_status === 'paid') {
      await conn.rollback();
      return res.status(400).json({ success: false, message: 'Paid bookings cannot be edited' });
    }
    if (booking.collection_status && blockedStatuses.includes(booking.collection_status)) {
      await conn.rollback();
      return res.status(400).json({ success: false, message: 'Technician is already on the way — booking cannot be edited' });
    }

    await conn.execute('DELETE FROM ip_booking_items WHERE booking_id = ?', [bookingId]);

    let newTotal = 0;
    for (const item of items) {
      const rawId = item.packageId ? Number(item.packageId) : null;
      let validProductId = 0;
      let productName = null;
      if (rawId) {
        const [pkgCheck] = await conn.execute(
          'SELECT product_id, product_name FROM ip_products WHERE product_id = ? LIMIT 1',
          [rawId]
        );
        if (pkgCheck.length > 0) {
          validProductId = rawId;
          productName = pkgCheck[0].product_name ?? null;
        }
      }
      const unitPrice  = item.originalPrice ?? item.finalPrice ?? 0;
      const finalPrice = item.finalPrice ?? 0;
      newTotal += finalPrice;
      await conn.execute(
        `INSERT INTO ip_booking_items
           (booking_id, product_id, product_name_snapshot, patient_id, unit_price, final_price, created_at)
         VALUES (?, ?, ?, ?, ?, ?, NOW())`,
        [bookingId, validProductId, productName, booking.patient_id, unitPrice, finalPrice]
      );
    }

    newTotal += Number(serviceCharge) || 0;

    const amountPaid   = Number(booking.amount_paid) || 0;
    const newAmountDue = Math.max(0, newTotal - amountPaid);
    await conn.execute(
      `UPDATE ip_bookings SET total_amount = ?, amount_due = ?, updated_at = NOW() WHERE booking_id = ?`,
      [newTotal, newAmountDue, bookingId]
    );
    await conn.execute(
      `UPDATE ip_payment_transactions
       SET net_amount = ?, amount_due = ?, updated_at = NOW()
       WHERE booking_id = ? AND (is_refund = 0 OR is_refund IS NULL)`,
      [newTotal, newAmountDue, bookingId]
    );

    // Find doc-required booking_item_ids in the new selection
    const [docReqRows] = await conn.execute(
      `SELECT bi.booking_item_id
       FROM ip_booking_items bi
       JOIN ip_products p ON p.product_id = bi.product_id
       WHERE bi.booking_id = ?
         AND p.document_required IN (1, '1', 'yes')`,
      [bookingId]
    );
    const docRequiredItemIds = docReqRows.map(r => r.booking_item_id);

    // If no doc-required tests remain, remove stale prescription documents
    if (docRequiredItemIds.length === 0) {
      await conn.execute(
        `DELETE FROM ip_booking_documents WHERE booking_id = ? AND file_description = 'prescription'`,
        [bookingId]
      );
    }

    await conn.commit();
    console.log(`✅ updateBookingItems → booking_id=${bookingId} new_total=₹${newTotal}`);
    res.json({ success: true, newTotal, newAmountDue, docRequiredItemIds });
  } catch (err) {
    await conn.rollback();
    console.error('❌ updateBookingItems FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error', detail: err.message });
  } finally {
    conn.release();
  }
};

// ── POST /api/bookings/family ─────────────────────────────────────────────────
// Creates multiple bookings in one transaction sharing the same slot/visit.
// members[] = [{ patientId, items, totalAmount, serviceCharge }, ...]
// First member carries the service charge; additional members have serviceCharge = 0.
exports.createFamilyBooking = async (req, res) => {
  console.log('\n🔵 [CREATE FAMILY BOOKING] ──────────────────────────');
  const clientId = req.user.client_id;
  const userId   = req.user.user_id;

  const {
    members           = [],
    availableSlotId   = null,
    collectionDate    = null,
    bookingType       = 'home_collection',
    collectionAddress = null,
    collectionPincode = null,
    collectionCity    = null,
    collectionLatitude  = null,
    collectionLongitude = null,
    branchId          = null,
    paymentType       = 'pay_later',
    razorpayPaymentId = null,
    razorpayOrderId   = null,
  } = req.body;

  if (!Array.isArray(members) || members.length < 2) {
    return res.status(400).json({ success: false, message: 'At least 2 members required' });
  }

  if (!settings.getBool('family_booking_enabled', true)) {
    return res.status(403).json({ success: false, message: 'Family booking is currently unavailable' });
  }

  const maxMembers = parseInt(settings.get('family_booking_max_members', '4'), 10);
  if (members.length > maxMembers) {
    return res.status(400).json({ success: false, message: `Maximum ${maxMembers} members allowed per visit` });
  }

  const isPaid       = paymentType === 'full' && razorpayPaymentId;
  const visitGroupId = `VG${Date.now()}`;

  // Resolve slot → lab_slot_id / technician_slot_id
  let labSlotId  = null;
  let techSlotId = null;
  if (availableSlotId) {
    try {
      const [[avSlot]] = await db.execute(
        `SELECT lab_slot_id, technician_slot_id FROM ip_available_slots WHERE available_slot_id = ?`,
        [availableSlotId]
      );
      if (avSlot) { labSlotId = avSlot.lab_slot_id ?? null; techSlotId = avSlot.technician_slot_id ?? null; }
    } catch (_) {}
  }

  const conn = await db.getConnection();
  try {
    await conn.beginTransaction();
    const createdBookings = [];

    for (const member of members) {
      const { patientId, items = [], totalAmount = 0, serviceCharge = 0 } = member;
      if (!patientId) continue;

      // Resolve patient_id_ref
      let resolvedPatientIdRef = null;
      const [[patRow]] = await conn.execute(
        `SELECT patient_id_ref FROM ip_patients WHERE patient_id = ? LIMIT 1`, [patientId]
      );
      if (patRow?.patient_id_ref) resolvedPatientIdRef = patRow.patient_id_ref;

      const bookingRef  = `BK${Date.now()}${Math.random().toString(36).slice(2, 5).toUpperCase()}`;
      const amountPaid  = isPaid ? totalAmount : 0;
      const amountDue   = isPaid ? 0 : totalAmount;
      const txPayType   = isPaid ? 'RAZORPAY' : 'PAY_LATER';

      const [bResult] = await conn.execute(
        `INSERT INTO ip_bookings
           (booking_ref, client_id, branch_id, booking_date, lab_slot_id, available_slot_id,
            booking_type, status, total_amount, discount_amount,
            amount_paid, amount_due, source_channel, notes,
            collection_address, postal_code, city,
            patient_id, patient_id_ref, product_id,
            payment_status, visit_group_id, start_datetime, end_datetime, created_by, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, 0, ?, ?, 'mobile_app', NULL,
                 ?, ?, ?, ?, ?, 0, ?, ?, NOW(), NOW(), ?, NOW())`,
        [bookingRef, clientId, branchId ?? null, collectionDate ?? null, labSlotId ?? null, availableSlotId ?? null,
         bookingType, totalAmount, amountPaid, amountDue,
         collectionAddress ?? null, collectionPincode ?? null, collectionCity ?? null,
         patientId, resolvedPatientIdRef,
         isPaid ? 'paid' : 'unpaid',
         visitGroupId, userId ?? null]
      );
      const bookingId = bResult.insertId;

      // Patient → booking link
      await conn.execute(
        `INSERT INTO ip_patient_bookings (booking_id, patient_id, patient_ref, created_at) VALUES (?, ?, ?, NOW())`,
        [bookingId, patientId, resolvedPatientIdRef]
      );

      // Line items
      for (const item of items) {
        const rawId = item.packageId ? Number(item.packageId) : null;
        let validProductId = 0; let productName = null;
        if (rawId) {
          const [pkgCheck] = await conn.execute(
            'SELECT product_id, product_name FROM ip_products WHERE product_id = ? LIMIT 1', [rawId]
          );
          if (pkgCheck.length > 0) { validProductId = rawId; productName = pkgCheck[0].product_name ?? null; }
        }
        await conn.execute(
          `INSERT INTO ip_booking_items (booking_id, product_id, product_name_snapshot, patient_id, unit_price, final_price, created_at)
           VALUES (?, ?, ?, ?, ?, ?, NOW())`,
          [bookingId, validProductId, productName, patientId, item.finalPrice ?? 0, item.finalPrice ?? 0]
        );
      }

      // Payment transaction
      const txnRef = `TXN${Date.now()}${Math.random().toString(36).slice(2, 5)}`;
      await conn.execute(
        `INSERT INTO ip_payment_transactions
           (transaction_ref, booking_id, patient_id, payment_type,
            gross_amount, discount_amount, net_amount, amount_paid, amount_due,
            currency, payment_status, transaction_status, is_refund,
            gateway_transaction_id, gateway_order_id, gateway_status, paid_at)
         VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, 'INR', ?, ?, 0, ?, ?, ?, ?)`,
        [txnRef, bookingId, patientId, txPayType,
         totalAmount, totalAmount, amountPaid, amountDue,
         isPaid ? 'paid'      : 'pending',
         isPaid ? 'completed' : 'pending',
         razorpayPaymentId ?? null,
         razorpayOrderId   ?? null,
         isPaid ? 'success' : null,
         isPaid ? new Date() : null]
      );

      if (isPaid) {
        await conn.execute(
          `UPDATE ip_bookings SET status = 'confirmed', updated_at = NOW() WHERE booking_id = ?`, [bookingId]
        );
      }

      // Find booking_item_id for first doc-required item (for prescription linking)
      const [docRows] = await conn.execute(
        `SELECT bi.booking_item_id
         FROM ip_booking_items bi
         JOIN ip_products p ON p.product_id = bi.product_id
         WHERE bi.booking_id = ? AND p.document_required IN (1, '1', 'yes')
         LIMIT 1`,
        [bookingId]
      );
      const docRequiredItemId = docRows.length > 0 ? docRows[0].booking_item_id : null;

      createdBookings.push({ bookingId, bookingRef, docRequiredItemId });
      console.log(`✅ family member booking_id=${bookingId} ref=${bookingRef} patient=${patientId} total=₹${totalAmount} docItemId=${docRequiredItemId}`);
    }

    // Mark slot used once for the whole group
    if (availableSlotId) {
      await conn.execute(
        'UPDATE ip_available_slots SET is_available = 0, updated_at = NOW() WHERE available_slot_id = ?',
        [availableSlotId]
      );
    }
    if (labSlotId) {
      await conn.execute('UPDATE ip_lab_slots SET booked_count = booked_count + 1 WHERE lab_slot_id = ?', [labSlotId]);
    } else if (techSlotId) {
      await conn.execute('UPDATE ip_technician_slots SET booked_count = booked_count + 1 WHERE tech_slot_id = ?', [techSlotId]);
    }

    await conn.commit();
    console.log(`🎉 Family booking done — visitGroupId=${visitGroupId} members=${createdBookings.length}`);
    console.log('─────────────────────────────────────────────────\n');

    if (isPaid) {
      for (const { bookingId } of createdBookings) {
        syncBookingToClient(bookingId, {
          mobile: req.user.mobile,
          type:   req.user.user_type ?? 'customer',
        }).catch(err => console.error('[clientSync] unhandled:', err.message));
      }
    }

    res.status(201).json({ success: true, visitGroupId, bookings: createdBookings });
  } catch (err) {
    await conn.rollback();
    console.error('❌ createFamilyBooking FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error', detail: err.message });
  } finally {
    conn.release();
  }
};

// ── POST /api/bookings/:bookingId/dispatch ────────────────────────────────────
// Called by the CodeIgniter admin portal after creating a booking.
// Reads booking + patient data from DB, then fires the existing dispatch engine
// via triggerScheduledDispatch — same path the cron scheduler uses.
// Protected by adminAuth middleware (HMAC-SHA256 shared secret).
exports.dispatchBooking = async (req, res) => {
  const bid = parseInt(req.params.bookingId, 10);
  console.log(`\n📡 [DISPATCH-API] ── incoming ── bookingId=${bid || 'INVALID'}  ip=${req.ip}`);
  if (!bid) {
    console.warn('[DISPATCH-API] rejected — invalid bookingId');
    return res.status(400).json({ success: false, message: 'Invalid bookingId' });
  }

  try {
    // Same query as dispatchScheduler — gets all fields _handleBookingRequest needs
    const [[row]] = await db.execute(
      `SELECT
         b.booking_id,
         b.patient_id,
         b.branch_id,
         b.booking_type,
         b.status,
         b.collection_address,
         b.collection_latitude   AS patient_lat,
         b.collection_longitude  AS patient_lng,
         p.patient_name,
         p.patient_mobile,
         COALESCE(ts.slot_id, ls.slot_id) AS slot_id,
         ias.slot_time
       FROM ip_bookings b
       JOIN ip_patients p   ON p.patient_id          = b.patient_id
       LEFT JOIN ip_available_slots  ias ON ias.available_slot_id  = b.available_slot_id
       LEFT JOIN ip_technician_slots ts  ON ts.tech_slot_id        = ias.technician_slot_id
       LEFT JOIN ip_lab_slots        ls  ON ls.lab_slot_id         = ias.lab_slot_id
       WHERE b.booking_id  = ?
         AND b.deleted_at IS NULL
       LIMIT 1`,
      [bid]
    );

    if (!row) {
      console.warn(`[DISPATCH-API] booking_id=${bid} NOT FOUND in ip_bookings`);
      return res.status(404).json({ success: false, message: 'Booking not found' });
    }

    console.log(`[DISPATCH-API] booking found — id=${bid} status=${row.status} type=${row.booking_type} patient="${row.patient_name}" branch=${row.branch_id}`);

    if (!['pending', 'confirmed'].includes(row.status)) {
      console.warn(`[DISPATCH-API] REJECTED — status='${row.status}' (must be pending or confirmed)  bookingId=${bid}`);
      return res.status(400).json({
        success: false,
        message: `Booking status is '${row.status}' — dispatch requires status 'pending' or 'confirmed'`,
      });
    }

    // "HH:MM:SS" → "HH:MM"  (null if no slot time stored)
    const slotTime    = row.slot_time ? String(row.slot_time).substring(0, 5) : null;
    const dispatchType = row.booking_type === 'home_collection' ? 'lab' : (row.booking_type ?? 'lab');

    console.log(`[DISPATCH-API] firing dispatch — bookingId=${bid} type=${dispatchType} slotTime=${slotTime ?? 'none'} lat=${row.patient_lat} lng=${row.patient_lng}`);

    // Fire and forget — dispatch runs in the background, response returns immediately
    triggerScheduledDispatch({
      bookingId:       row.booking_id,
      patientId:       row.patient_id,
      patientName:     row.patient_name   ?? 'Patient',
      patientMobile:   row.patient_mobile ?? '',
      patientAddress:  row.collection_address ?? 'Home Collection',
      patientLat:      row.patient_lat  ?? null,
      patientLng:      row.patient_lng  ?? null,
      hospital:        'MicroLab Home Collection',
      bookingType:     dispatchType,
      branchId:        row.branch_id  ?? null,
      slotId:          row.slot_id    ?? null,
      slotLabel:       null,
      appointmentTime: slotTime,
    }, _io);

    res.json({ success: true, message: 'Dispatch started', bookingId: bid });
  } catch (err) {
    console.error('❌ dispatchBooking FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── POST /api/bookings/admin ───────────────────────────────────────────────────
// Creates a booking from the admin portal and auto-dispatches for same-day bookings.
// Protected by adminAuth middleware (HMAC-SHA256). No patient JWT required.
// clientId must be provided in the request body (no req.user available).
exports.createAdminBooking = async (req, res) => {
  console.log('\n🔵 [ADMIN CREATE BOOKING] ─────────────────────────────');

  const {
    clientId,
    patientId,
    bookingType         = 'home_collection',
    totalAmount         = 0,
    discountAmount      = 0,
    notes               = null,
    items               = [],
    branchId            = null,
    collectionDate      = null,
    availableSlotId     = null,
    collectionAddress   = null,
    collectionPincode   = null,
    collectionCity      = null,
    collectionLatitude  = null,
    collectionLongitude = null,
    paymentType         = 'pay_later',
    razorpayPaymentId   = null,
    razorpayOrderId     = null,
  } = req.body;

  if (!clientId)  return res.status(400).json({ success: false, message: 'clientId is required' });
  if (!patientId) return res.status(400).json({ success: false, message: 'patientId is required' });

  const isPaid        = paymentType === 'full' && razorpayPaymentId;
  const amountPaid    = isPaid ? totalAmount : 0;
  const amountDue     = isPaid ? 0 : totalAmount;
  const txPaymentType = isPaid ? 'RAZORPAY' : 'PAY_LATER';

  const todayIST      = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const bookingStatus = (collectionDate && collectionDate > todayIST) ? 'scheduled' : 'pending';

  const conn = await db.getConnection();
  try {
    await conn.beginTransaction();

    // Resolve patient details (name + mobile needed for dispatch)
    const [[patientRow]] = await conn.execute(
      `SELECT patient_id_ref, patient_name, patient_mobile FROM ip_patients WHERE patient_id = ? LIMIT 1`,
      [patientId]
    );
    const resolvedPatientIdRef = patientRow?.patient_id_ref ?? null;

    // Resolve slot IDs from ip_available_slots
    let labSlotId  = null;
    let techSlotId = null;
    if (availableSlotId) {
      const [[avSlot]] = await conn.execute(
        `SELECT lab_slot_id, technician_slot_id FROM ip_available_slots WHERE available_slot_id = ?`,
        [availableSlotId]
      );
      if (avSlot) {
        labSlotId  = avSlot.lab_slot_id        ?? null;
        techSlotId = avSlot.technician_slot_id  ?? null;
      }
    }

    // 1. Master booking record
    const bookingRef = `BK${Date.now()}`;
    const [bResult] = await conn.execute(
      `INSERT INTO ip_bookings
         (booking_ref, client_id, branch_id, booking_date, lab_slot_id, available_slot_id,
          booking_type, status, total_amount, discount_amount,
          amount_paid, amount_due, source_channel, notes,
          collection_address, postal_code, city,
          collection_latitude, collection_longitude,
          patient_id, patient_id_ref, product_id,
          payment_status, start_datetime, end_datetime, created_by, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'admin_panel', ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, NOW(), NOW(), NULL, NOW())`,
      [bookingRef, clientId, branchId ?? null, collectionDate ?? null,
       labSlotId ?? null, availableSlotId ?? null,
       bookingType, bookingStatus, totalAmount, discountAmount ?? 0,
       amountPaid, amountDue,
       notes ?? null,
       collectionAddress ?? null, collectionPincode ?? null, collectionCity ?? null,
       collectionLatitude ?? null, collectionLongitude ?? null,
       patientId, resolvedPatientIdRef,
       isPaid ? 'paid' : 'unpaid']
    );
    const bookingId = bResult.insertId;
    console.log(`✅ [ADMIN] ip_bookings inserted → booking_id=${bookingId} status=${bookingStatus}`);

    // 2. Patient → booking link
    await conn.execute(
      `INSERT INTO ip_patient_bookings (booking_id, patient_id, patient_ref, created_at)
       VALUES (?, ?, ?, NOW())`,
      [bookingId, patientId, resolvedPatientIdRef]
    );

    // 3. Line items
    const bookingItemsInserted = [];
    for (const item of items) {
      const rawId = item.packageId ? Number(item.packageId) : null;
      let validProductId = 0;
      let productName    = null;
      let docRequired    = false;
      if (rawId) {
        const [pkgCheck] = await conn.execute(
          'SELECT product_id, product_name, document_required FROM ip_products WHERE product_id = ? LIMIT 1',
          [rawId]
        );
        if (pkgCheck.length > 0) {
          validProductId = rawId;
          productName    = pkgCheck[0].product_name ?? null;
          const rawDocReq = pkgCheck[0].document_required;
          docRequired    = rawDocReq === 1 || rawDocReq === '1' || rawDocReq === 'yes';
        }
      }
      const unitPrice  = item.originalPrice ?? item.finalPrice ?? 0;
      const finalPrice = item.finalPrice ?? 0;
      const [biResult] = await conn.execute(
        `INSERT INTO ip_booking_items
           (booking_id, product_id, product_name_snapshot, patient_id, unit_price, final_price, created_at)
         VALUES (?, ?, ?, ?, ?, ?, NOW())`,
        [bookingId, validProductId, productName, patientId, unitPrice, finalPrice]
      );
      bookingItemsInserted.push({ bookingItemId: biResult.insertId, productId: validProductId, docRequired });
    }

    // 4. Mark slot unavailable and increment booked count
    if (availableSlotId) {
      await conn.execute(
        'UPDATE ip_available_slots SET is_available = 0, updated_at = NOW() WHERE available_slot_id = ?',
        [availableSlotId]
      );
    }
    if (labSlotId) {
      await conn.execute(
        'UPDATE ip_lab_slots SET booked_count = booked_count + 1 WHERE lab_slot_id = ?',
        [labSlotId]
      );
    } else if (techSlotId) {
      await conn.execute(
        'UPDATE ip_technician_slots SET booked_count = booked_count + 1 WHERE tech_slot_id = ?',
        [techSlotId]
      );
    }

    // 5. Payment transaction record
    const txnRef = `TXN${Date.now()}`;
    await conn.execute(
      `INSERT INTO ip_payment_transactions
         (transaction_ref, booking_id, patient_id, payment_type,
          gross_amount, discount_amount, net_amount, amount_paid, amount_due,
          currency, payment_status, transaction_status, is_refund,
          gateway_transaction_id, gateway_order_id, gateway_status, paid_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'INR', ?, ?, 0, ?, ?, ?, ?)`,
      [txnRef, bookingId, patientId, txPaymentType,
       totalAmount, discountAmount ?? 0, totalAmount - (discountAmount ?? 0),
       amountPaid, amountDue,
       isPaid ? 'paid'      : 'pending',
       isPaid ? 'completed' : 'pending',
       razorpayPaymentId ?? null,
       razorpayOrderId   ?? null,
       isPaid ? 'success' : null,
       isPaid ? new Date() : null]
    );

    await conn.commit();
    console.log(`🎉 [ADMIN] Booking created — booking_id=${bookingId} ref=${bookingRef}`);

    // Auto-dispatch for same-day bookings
    let dispatched = false;
    if (bookingStatus === 'pending' && _io) {
      const [[dispRow]] = await db.execute(
        `SELECT COALESCE(ts.slot_id, ls.slot_id) AS slot_id, ias.slot_time
         FROM ip_bookings b
         LEFT JOIN ip_available_slots  ias ON ias.available_slot_id = b.available_slot_id
         LEFT JOIN ip_technician_slots ts  ON ts.tech_slot_id       = ias.technician_slot_id
         LEFT JOIN ip_lab_slots        ls  ON ls.lab_slot_id        = ias.lab_slot_id
         WHERE b.booking_id = ? LIMIT 1`,
        [bookingId]
      );
      const slotTime     = dispRow?.slot_time ? String(dispRow.slot_time).substring(0, 5) : null;
      const dispatchType = bookingType === 'home_collection' ? 'lab' : (bookingType ?? 'lab');

      triggerScheduledDispatch({
        bookingId,
        patientId,
        patientName:     patientRow?.patient_name   ?? 'Patient',
        patientMobile:   patientRow?.patient_mobile ?? '',
        patientAddress:  collectionAddress   ?? 'Home Collection',
        patientLat:      collectionLatitude  ?? null,
        patientLng:      collectionLongitude ?? null,
        hospital:        'MicroLab Home Collection',
        bookingType:     dispatchType,
        branchId:        branchId            ?? null,
        slotId:          dispRow?.slot_id    ?? null,
        slotLabel:       null,
        appointmentTime: slotTime,
      }, _io);

      dispatched = true;
      console.log(`🚀 [ADMIN] Auto-dispatch fired for booking_id=${bookingId}`);
    }

    res.status(201).json({
      success:     true,
      bookingId,
      bookingRef,
      isScheduled: bookingStatus === 'scheduled',
      dispatched,
      bookingItems: bookingItemsInserted.map(i => ({
        bookingItemId: i.bookingItemId,
        productId:     i.productId,
        docRequired:   i.docRequired,
      })),
    });
  } catch (err) {
    await conn.rollback();
    console.error('❌ createAdminBooking FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error', detail: err.message });
  } finally {
    conn.release();
  }
};



