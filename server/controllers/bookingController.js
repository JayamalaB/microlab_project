const db = require('../config/db');

// In-memory reference to the Socket.IO instance (injected by server.js)
let _io = null;
exports.setIo = (io) => { _io = io; };

// ── Notify patient via socket ──────────────────────────────────────────────────
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
    userId              = null,
    roleId              = null,
    bookingType         = 'home_collection',
    totalAmount         = 0,
    discountAmount      = 0,
    sourceChannel       = 'mobile_app',
    notes               = null,
    items               = [],
    // branch booking fields (null for existing flows)
    branchId            = null,
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

    // 1. Master booking record
    const bookingRef = `BK${Date.now()}`;
    console.log(`📋 Inserting booking with ref: ${bookingRef}`);
    console.log(`   SQL params: user_id=${userId ?? null} patient_id=${patientId} booking_type=${bookingType} total=${totalAmount} branch_id=${branchId ?? 'null'} collection_date=${collectionDate ?? 'null'}`);
    const [bResult] = await conn.execute(
      `INSERT INTO booking
         (user_id, role_id, patient_id, patient_id_ref, branch_id, booking_ref,
          booking_status, booking_type, collection_date, total_amount, discount_amount,
          source_channel, notes_remarks, collection_latitude, collection_longitude,
          created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?, NOW(), NOW())`,
      [
        userId ?? null, roleId ?? null, patientId, patientIdRef ?? null,
        branchId ?? null, bookingRef,
        bookingType, collectionDate ?? null, totalAmount, discountAmount ?? 0,
        sourceChannel, notes ?? null,
        collectionLatitude ?? null, collectionLongitude ?? null,
      ]
    );
    const bookingId = bResult.insertId;
    console.log(`✅ booking inserted → booking_id=${bookingId} branch_id=${branchId ?? 'null'} collection_date=${collectionDate ?? 'null'}`);

    // 2. Patient → booking link
    await conn.execute(
      `INSERT INTO patient_booking (patient_id, patient_id_ref, booking_id, created_at)
       VALUES (?, ?, ?, NOW())`,
      [patientId, patientIdRef, bookingId]
    );
    console.log(`✅ patient_booking inserted → patient_id=${patientId} booking_id=${bookingId}`);

    // 3. Line items (tests / packages)
    for (const item of items) {
      const rawId = item.packageId ? Number(item.packageId) : null;

      // Verify the package_id exists in the packages table.
      // If not found (e.g. packages table is empty or ID is from local mock data),
      // store NULL to avoid the fk_bi_package FK constraint failure.
      let validPkgId = null;
      if (rawId) {
        const [pkgCheck] = await conn.execute(
          'SELECT package_id FROM packages WHERE package_id = ? AND deleted_at IS NULL',
          [rawId]
        );
        validPkgId = pkgCheck.length > 0 ? rawId : null;
        if (pkgCheck.length === 0) {
          console.log(`⚠️  package_id=${rawId} not found in packages table — storing NULL for fk safety`);
        }
      }

      await conn.execute(
        `INSERT INTO booking_item (booking_id, package_type, package_id, final_price, created_at)
         VALUES (?, ?, ?, ?, NOW())`,
        [bookingId, item.packageType ?? 'test', validPkgId, item.finalPrice ?? 0]
      );
      console.log(`✅ booking_item inserted → package_id=${validPkgId ?? 'NULL'} type=${item.packageType} price=₹${item.finalPrice}`);
    }

    await conn.commit();
    console.log(`🎉 Booking created successfully — booking_id=${bookingId} ref=${bookingRef}`);
    console.log('─────────────────────────────────────────────────\n');
    res.status(201).json({ success: true, bookingId, bookingRef });
  } catch (err) {
    await conn.rollback();
    console.error('❌ createBooking FAILED:', err.message);
    console.error('   SQL State:', err.sqlState, '| Code:', err.code);
    res.status(500).json({
      success: false,
      message: 'Server error',
      detail: err.message,       // exact SQL error
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
              tcb.collection_booking_id, tcb.technician_id,
              tcb.collection_status, tcb.collection_date,
              tcb.assigned_at, tcb.en_route_at, tcb.arrived_at, tcb.collected_at,
              tcb.collection_address, tcb.collection_latitude, tcb.collection_longitude,
              GROUP_CONCAT(DISTINCT p.name ORDER BY p.name SEPARATOR ', ') AS test_names,
              SUM(bi.final_price) AS items_total
       FROM booking b
       JOIN patient_booking pb ON pb.booking_id = b.booking_id
       LEFT JOIN technician_collection_booking tcb ON tcb.booking_id = b.booking_id
       LEFT JOIN booking_item bi ON bi.booking_id = b.booking_id
       LEFT JOIN packages p ON p.package_id = bi.package_id
       WHERE pb.patient_id = ?
         AND b.deleted_at IS NULL
       GROUP BY b.booking_id
       ORDER BY b.created_at DESC
       LIMIT 50`,
      [patientId]
    );
    console.log(`✅ Found ${rows.length} booking(s) for patient ${patientId}`);
    rows.forEach(r => console.log(`   #${r.booking_id} status=${r.booking_status} collection_status=${r.collection_status ?? 'N/A'} tests=${r.test_names ?? 'none'}`));
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
              tcb.collection_booking_id, tcb.technician_id, tcb.slot_id,
              tcb.collection_status, tcb.collection_date,
              tcb.assigned_at, tcb.en_route_at, tcb.arrived_at,
              tcb.collected_at, tcb.completed_at,
              tcb.collection_address, tcb.collection_latitude, tcb.collection_longitude,
              GROUP_CONCAT(DISTINCT p.name ORDER BY p.name SEPARATOR ', ') AS test_names,
              GROUP_CONCAT(DISTINCT bi.package_id ORDER BY bi.package_id SEPARATOR ',') AS package_ids,
              SUM(bi.final_price) AS items_total
       FROM booking b
       LEFT JOIN technician_collection_booking tcb ON tcb.booking_id = b.booking_id
       LEFT JOIN booking_item bi ON bi.booking_id = b.booking_id
       LEFT JOIN packages p ON p.package_id = bi.package_id
       WHERE b.booking_id = ?
         AND b.deleted_at IS NULL
       GROUP BY b.booking_id`,
      [bookingId]
    );
    if (!rows.length) {
      console.log(`⚠️  Booking ${bookingId} not found`);
      return res.status(404).json({ success: false, message: 'Booking not found' });
    }
    const b = rows[0];
    console.log(`✅ booking_id=${b.booking_id} status=${b.booking_status} collection_status=${b.collection_status ?? 'N/A'} tests=${b.test_names ?? 'none'}`);
    res.json({ success: true, booking: b });
  } catch (err) {
    console.error('❌ getBooking FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};

// ── PUT /api/bookings/:bookingId/lab-status ────────────────────────────────────
exports.updateLabStatus = async (req, res) => {
  const { status, reportUrl, reportId } = req.body;
  const { bookingId } = req.params;

  console.log(`\n🧪 [LAB STATUS UPDATE] bookingId=${bookingId} → status=${status}`);

  const allowed = ['sample_received', 'test_in_progress', 'report_ready'];
  if (!allowed.includes(status)) {
    console.log(`❌ Invalid status: ${status}`);
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
      `UPDATE technician_collection_booking
       SET collection_status=?, updated_at=NOW()
       WHERE booking_id=?`,
      [status, bookingId]
    );
    console.log(`✅ technician_collection_booking.collection_status → '${status}'`);

    if (status === 'report_ready') {
      await db.execute(
        `UPDATE booking SET booking_status='completed', updated_at=NOW()
         WHERE booking_id=?`,
        [bookingId]
      );
      console.log(`✅ booking.booking_status → 'completed'`);
      if (reportUrl) console.log(`📄 Report URL: ${reportUrl}`);
    }

    const socketPayload = { bookingId: Number(bookingId) };
    if (status === 'report_ready') {
      socketPayload.reportUrl = reportUrl ?? null;
      socketPayload.reportId  = reportId  ?? null;
    }

    console.log(`📡 Emitting '${socketEventMap[status]}' to room ${bookingId}`);
    _pushToPatient(bookingId, socketEventMap[status], socketPayload);
    res.json({ success: true, status });
  } catch (err) {
    console.error('❌ updateLabStatus FAILED:', err.message);
    res.status(500).json({ success: false, message: 'Server error' });
  }
};
