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

  const {
    patientId,
    patientIdRef        = null,
    bookingType         = 'home_collection',
    totalAmount         = 0,
    notes               = null,
    items               = [],
    branchId            = null,
    slotId              = null,
    appointmentTime     = null,  // "HH:MM" — exact time within slot
    collectionDate      = null,
    collectionLatitude  = null,
    collectionLongitude = null,
  } = req.body;

  if (!patientId) {
    console.log('❌ Missing patientId');
    return res.status(400).json({ success: false, message: 'patientId is required' });
  }

  console.log(`👤 Patient ID: ${patientId} | Type: ${bookingType} | Total: ₹${totalAmount}`);
  console.log(`📦 Items: ${items.length}`, items.map(i => `packageId=${i.packageId} price=₹${i.finalPrice}`));

  const conn = await db.getConnection();
  try {
    await conn.beginTransaction();
    console.log('🔄 Transaction started');

    // Derive start/end datetime — NOT NULL in ip_bookings, fall back to today if not sent
    const dateStr       = collectionDate ?? new Date().toISOString().slice(0, 10);
    const startDatetime = appointmentTime ? `${dateStr} ${appointmentTime}:00` : `${dateStr} 00:00:00`;
    const endDatetime   = `${dateStr} 23:59:59`;

    // Get primary product_id from first item (ip_bookings.product_id is NOT NULL)
    const firstRawId = items[0]?.packageId ? Number(items[0].packageId) : null;
    let primaryProductId = firstRawId ?? 0; // 0 fallback if no product sent

    // 1. Master booking record
    const bookingRef = `BK${Date.now()}`;
    console.log(`📋 Inserting booking ref=${bookingRef} client_id=${patientId} product_id=${primaryProductId}`);

    const bookingParams = [
      patientId, branchId ?? null, slotId ?? null, bookingRef, primaryProductId,
      bookingType, collectionDate ?? null,
      startDatetime, endDatetime,
      totalAmount, notes ?? null,
      collectionLatitude ?? null, collectionLongitude ?? null,
    ];
    console.log('💾 [DB] INSERT ip_bookings | values:', JSON.stringify({
      client_id: patientId, branch_id: branchId, slot_id: slotId,
      booking_ref: bookingRef, product_id: primaryProductId, booking_type: bookingType,
      booking_date: collectionDate, start_datetime: startDatetime,
      end_datetime: endDatetime, amount_due: totalAmount,
      notes, collection_latitude: collectionLatitude, collection_longitude: collectionLongitude,
    }));
    const [bResult] = await conn.execute(
      `INSERT INTO ip_bookings
         (client_id, branch_id, slot_id, booking_ref, product_id,
          status, booking_type, booking_date,
          start_datetime, end_datetime,
          amount_due, notes,
          collection_latitude, collection_longitude,
          created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())`,
      bookingParams
    );
    const bookingId = bResult.insertId;
    console.log(`✅ ip_bookings inserted → booking_id=${bookingId}`);

    // 2. Patient → booking link
    console.log('💾 [DB] INSERT ip_patient_bookings | values:', JSON.stringify({ patient_id: patientId, patient_ref: patientIdRef, booking_id: bookingId }));
    await conn.execute(
      `INSERT INTO ip_patient_bookings (patient_id, patient_ref, booking_id, created_at)
       VALUES (?, ?, ?, NOW())`,
      [patientId, patientIdRef ?? null, bookingId]
    );
    console.log(`✅ ip_patient_bookings inserted → patient_id=${patientId} booking_id=${bookingId}`);

    // 3. Line items
    for (const item of items) {
      const productId = item.packageId ? Number(item.packageId) : null;
      console.log('💾 [DB] INSERT ip_booking_items | values:', JSON.stringify({ booking_id: bookingId, product_id: productId, final_price: item.finalPrice }));
      await conn.execute(
        `INSERT INTO ip_booking_items (booking_id, product_id, final_price, created_at)
         VALUES (?, ?, ?, NOW())`,
        [bookingId, productId, item.finalPrice ?? 0]
      );
      console.log(`✅ ip_booking_items inserted → product_id=${productId} price=₹${item.finalPrice}`);
    }

    await conn.commit();
    console.log(`🎉 Booking created — booking_id=${bookingId} ref=${bookingRef}`);
    console.log('─────────────────────────────────────────────────\n');
    res.status(201).json({ success: true, bookingId, bookingRef });
  } catch (err) {
    await conn.rollback();
    console.error('❌ createBooking FAILED:', err.message);
    console.error('   SQL State:', err.sqlState, '| Code:', err.code);
    res.status(500).json({
      success: false,
      message: 'Server error',
      detail: err.message,
      sqlState: err.sqlState,
      code: err.code,
    });
  } finally {
    conn.release();
  }
};

// ── GET /api/bookings/patient/:patientId ───────────────────────────────────────
exports.getPatientBookings = async (req, res) => {
  const { patientId } = req.params;
  console.log(`\n🔍 [GET PATIENT BOOKINGS] patientId=${patientId}`);
  try {
    const [rows] = await db.execute(
      `SELECT b.*,
              tcb.collection_id, tcb.technician_id,
              tcb.collection_status,
              tcb.assigned_at, tcb.en_route_at, tcb.arrived_at, tcb.collected_at,
              tcb.collection_address, tcb.collection_latitude, tcb.collection_longitude,
              GROUP_CONCAT(DISTINCT p.product_name ORDER BY p.product_name SEPARATOR ', ') AS test_names,
              SUM(bi.final_price) AS items_total
       FROM ip_bookings b
       JOIN ip_patient_bookings pb ON pb.booking_id = b.booking_id
       LEFT JOIN ip_technician_collection tcb ON tcb.booking_id = b.booking_id
       LEFT JOIN ip_booking_items bi ON bi.booking_id = b.booking_id
       LEFT JOIN ip_products p ON p.product_id = bi.product_id
       WHERE pb.patient_id = ?
       GROUP BY b.booking_id
       ORDER BY b.created_at DESC
       LIMIT 50`,
      [patientId]
    );
    console.log(`✅ Found ${rows.length} booking(s) for patient ${patientId}`);
    res.json({ success: true, bookings: rows });
  } catch (err) {
    console.error('❌ getPatientBookings FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── GET /api/bookings/:bookingId ───────────────────────────────────────────────
exports.getBooking = async (req, res) => {
  const { bookingId } = req.params;
  console.log(`\n🔍 [GET BOOKING] bookingId=${bookingId}`);
  try {
    const [rows] = await db.execute(
      `SELECT b.*,
              tcb.collection_id, tcb.technician_id, tcb.slot_id,
              tcb.collection_status,
              tcb.assigned_at, tcb.en_route_at, tcb.arrived_at,
              tcb.collected_at, tcb.completed_at,
              tcb.collection_address, tcb.collection_latitude, tcb.collection_longitude,
              GROUP_CONCAT(DISTINCT p.product_name ORDER BY p.product_name SEPARATOR ', ') AS test_names,
              GROUP_CONCAT(DISTINCT bi.product_id ORDER BY bi.product_id SEPARATOR ',') AS package_ids,
              SUM(bi.final_price) AS items_total
       FROM ip_bookings b
       LEFT JOIN ip_technician_collection tcb ON tcb.booking_id = b.booking_id
       LEFT JOIN ip_booking_items bi ON bi.booking_id = b.booking_id
       LEFT JOIN ip_products p ON p.product_id = bi.product_id
       WHERE b.booking_id = ?
       GROUP BY b.booking_id`,
      [bookingId]
    );
    if (!rows.length) {
      console.log(`⚠️  Booking ${bookingId} not found`);
      return res.status(404).json({ success: false, message: 'Booking not found' });
    }
    const b = rows[0];
    console.log(`✅ booking_id=${b.booking_id} status=${b.status}`);
    res.json({ success: true, booking: b });
  } catch (err) {
    console.error('❌ getBooking FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── GET /api/bookings/:bookingId/tech-location ────────────────────────────────
// Returns the technician's last-known GPS for a booking so the patient's
// tracking screen can place the marker immediately on open, without waiting
// for the next live location_update socket event.
exports.getTechLocation = async (req, res) => {
  const { bookingId } = req.params;
  try {
    const [rows] = await db.execute(
      `SELECT
         ll.latitude,
         ll.longitude,
         ll.last_ping_at,
         ll.online_status,
         ll.task_status
       FROM ip_technician_collection tc
       JOIN ip_technician_live_location ll ON ll.technician_id = tc.technician_id
       WHERE tc.booking_id = ?
         AND tc.collection_status IN ('en_route','arrived','assigned')
       LIMIT 1`,
      [bookingId]
    );
    if (!rows.length || rows[0].latitude == null) {
      return res.status(404).json({ success: false, message: 'No location yet' });
    }
    const r = rows[0];
    console.log(`✅ [TECH-LOCATION] booking=${bookingId} lat=${r.latitude} lng=${r.longitude}`);
    res.json({
      success: true,
      lat: parseFloat(r.latitude),
      lng: parseFloat(r.longitude),
      lastPingAt: r.last_ping_at,
    });
  } catch (err) {
    console.error('[getTechLocation]', err.message);
    res.status(500).json({ success: false, message: err.message });
  }
};

// ── PUT /api/bookings/:bookingId/lab-status ────────────────────────────────────
exports.updateLabStatus = async (req, res) => {
  const { status, reportUrl, reportId } = req.body;
  const { bookingId } = req.params;

  console.log(`\n🧪 [LAB STATUS UPDATE] bookingId=${bookingId} → status=${status}`);

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
        `UPDATE ip_bookings SET status='completed', updated_at=NOW()
         WHERE booking_id=?`,
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
