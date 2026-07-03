const db = require('../config/db');

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
    collectionCity    = null,
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
  console.log(`👤 client_id=${clientId} | patient_id=${patientId} | type=${bookingType} | total=₹${totalAmount} | payment=${paymentType}`);

  const conn = await db.getConnection();
  try {
    await conn.beginTransaction();

    // Resolve slot → get lab_slot_id / technician_slot_id from ip_avilable_slots
    let labSlotId  = null;
    let techSlotId = null;
    if (availableSlotId) {
      const [[avSlot]] = await conn.execute(
        `SELECT lab_slot_id, technician_slot_id, booking_type
         FROM ip_avilable_slots WHERE available_slot_id = ?`,
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
          patient_id, patient_id_ref, product_id,
          payment_status, start_datetime, end_datetime, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, NOW(), NOW(), NOW())`,
      [bookingRef, clientId, branchId ?? null, collectionDate ?? null, labSlotId ?? null, availableSlotId ?? null,
       bookingType, totalAmount, discountAmount ?? 0, amountPaid, amountDue,
       sourceChannel, notes ?? null,
       collectionAddress ?? null, collectionPincode ?? null, collectionCity ?? null,
       patientId, patientIdRef ?? null,
       isPaid ? 'paid' : 'unpaid']
    );
    const bookingId = bResult.insertId;
    console.log(`✅ ip_bookings inserted → booking_id=${bookingId}`);

    // 2. Patient → booking link
    await conn.execute(
      `INSERT INTO ip_patient_bookings (booking_id, patient_id, patient_ref, created_at)
       VALUES (?, ?, ?, NOW())`,
      [bookingId, patientId, patientIdRef ?? null]
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
        'UPDATE ip_avilable_slots SET is_available = 0, updated_at = NOW() WHERE available_slot_id = ?',
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

    // 6. Confirm booking immediately for paid orders
    if (isPaid) {
      await conn.execute(
        `UPDATE ip_bookings SET status = 'confirmed', updated_at = NOW() WHERE booking_id = ?`,
        [bookingId]
      );
    }

    await conn.commit();
    console.log(`🎉 Booking created — booking_id=${bookingId} ref=${bookingRef}`);
    console.log('─────────────────────────────────────────────────\n');
    res.status(201).json({
      success: true,
      bookingId,
      bookingRef,
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
  const clientId = req.user.client_id;
  console.log(`\n🔍 [GET MY BOOKINGS] client_id=${clientId}`);
  try {
    const [rows] = await db.execute(
      `SELECT
         b.booking_id              AS booking_id_num,
         b.booking_ref,
         b.status                  AS booking_status,
         b.booking_type,
         b.booking_date            AS collection_date,
         b.total_amount,
         b.discount_amount,
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
             IFNULL(pkg.product_name, 'Test'), ':::',
             IFNULL(bi.final_price, '0'),       ':::',
             'test'
           ) END
           ORDER BY bi.booking_item_id SEPARATOR '|||'
         ) AS test_items,
         SUM(bi.final_price) AS items_total
       FROM ip_bookings b
       LEFT JOIN ip_patients pat       ON pat.patient_id  = b.patient_id
       LEFT JOIN ip_branches br        ON br.branch_id    = b.branch_id
       LEFT JOIN ip_avilable_slots av   ON av.available_slot_id = b.available_slot_id
       LEFT JOIN ip_booking_items bi   ON bi.booking_id   = b.booking_id
       LEFT JOIN ip_products pkg       ON pkg.product_id  = bi.product_id
       LEFT JOIN ip_payment_transactions bpt
         ON bpt.transaction_id = (
           SELECT t2.transaction_id FROM ip_payment_transactions t2
           WHERE t2.booking_id = b.booking_id AND (t2.is_refund = 0 OR t2.is_refund IS NULL)
           ORDER BY t2.created_at DESC LIMIT 1
         )
       WHERE b.client_id = ?
         AND b.deleted_at IS NULL
       GROUP BY b.booking_id
       ORDER BY b.created_at DESC
       LIMIT 50`,
      [clientId]
    );
    console.log(`✅ Found ${rows.length} booking(s) for client ${clientId}`);
    res.json({ success: true, bookings: rows });
  } catch (err) {
    console.error('❌ getMyBookings FAILED:', err.message);
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
    res.json({ success: true });
  } catch (err) {
    await conn.rollback();
    console.error('❌ payBooking FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  } finally {
    conn.release();
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
              GROUP_CONCAT(DISTINCT pkg.product_name ORDER BY pkg.product_name SEPARATOR ', ') AS test_names,
              SUM(bi.final_price) AS items_total
       FROM ip_bookings b
       JOIN ip_patient_bookings pb ON pb.booking_id = b.booking_id
       LEFT JOIN ip_technician_collection tc ON tc.booking_id = b.booking_id
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
              GROUP_CONCAT(DISTINCT pkg.product_name ORDER BY pkg.product_name SEPARATOR ', ') AS test_names,
              GROUP_CONCAT(DISTINCT bi.product_id ORDER BY bi.product_id SEPARATOR ',') AS package_ids,
              SUM(bi.final_price) AS items_total
       FROM ip_bookings b
       LEFT JOIN ip_technician_collection tc ON tc.booking_id = b.booking_id
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
