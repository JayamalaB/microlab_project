const https  = require('https');
const http   = require('http');
const path   = require('path');
const fs     = require('fs');
const db     = require('../config/db');
const settings = require('../config/settings');
const { messaging } = require('../config/firebase');
const { buildSecureId } = require('../utils/secureId');

const LOG_FILE = path.join(__dirname, '..', 'logs', 'client_sync.log');

function writeLog(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false }).replace(',', '') + ' IST';
  const line = `[${ist}] ${msg}\n`;
  process.stdout.write(line);
  fs.appendFileSync(LOG_FILE, line, 'utf8');
}

// "DD-MM-YYYY HH:MM:SS IST" — distinct from writeLog's own header format,
// matches the block-log layout below exactly.
function _formatBlockTimestamp() {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Asia/Kolkata',
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
  }).formatToParts(new Date());
  const get = (t) => parts.find(p => p.type === t)?.value;
  return `${get('day')}-${get('month')}-${get('year')} ${get('hour')}:${get('minute')}:${get('second')} IST`;
}

// One human-readable block per sync attempt — request fields as sent to the
// client server, and the response actually received. Written in addition
// to (not replacing) the existing terse writeLog(...) status lines already
// used throughout this file for non-request events (disabled, DB errors,
// not-found, etc.).
function _logRequestResponseBlock({ payload, tests, httpStatus, result }) {
  const lines = [];
  lines.push('-'.repeat(50));
  lines.push(`[${_formatBlockTimestamp()}]`);
  lines.push('REQUEST');
  lines.push(`  mobile_no    : ${payload.mobile_no}`);
  lines.push(`  user_type    : ${payload.user_type}`);
  lines.push(`  timestamp    : ${payload.timestamp}`);
  lines.push(`  booking_ref  : ${payload.booking_ref}`);
  if (payload.booking_status !== undefined) {
    lines.push(`  booking_status: ${payload.booking_status}`);
  }
  if (payload.existing_bill_id !== undefined) {
    lines.push(`  existing_bill: ${payload.existing_bill_id ?? 'none'}`);
  }
  if (payload.visit_group_id !== undefined) {
    lines.push(`  visit_group_id: ${payload.visit_group_id}`);
  }
  if (payload.booking_type !== undefined) {
    lines.push(`  booking_type : ${payload.booking_type}`);
  }
  if (payload.slot_details) {
    lines.push(`  slot_date    : ${payload.slot_details.date}`);
    lines.push(`  slot_time    : ${payload.slot_details.time}`);
  }
  if (payload.patient_details || payload.patient_id !== undefined) {
    lines.push(payload.patient_details
      ? `  patient      : NEW  name=${payload.patient_details.name}`
      : `  patient      : EXISTING  patient_id=${payload.patient_id}`);
  }
  if (payload.blood_test_list) {
    if (tests.length === 0) {
      lines.push('  test         : (none)');
    } else {
      for (const t of payload.blood_test_list) {
        lines.push(`  test         : id=${t.id}  name=${t.name}  price=${Number(t.price).toFixed(2)}` +
          ` [doc:${t.document_required}]  image=${t.document}`);
      }
    }
  }
  if (payload.payment_details) {
    const p = payload.payment_details;
    const due = Number(p.total_amount) - Number(p.paid_amount);
    lines.push(`  payment      : total=${p.total_amount}  paid=${Number(p.paid_amount).toFixed(2)}` +
      `  due=${due.toFixed(2)}  type=${p.payment_type}  razorpay=${p.razorpay_payment_id ?? ''}`);
  }
  if (payload.technician_details) {
    lines.push(`  technician   : id=${payload.technician_details.technician_id}  name=${payload.technician_details.name}`);
  }
  if (payload.proof_photo !== undefined) {
    lines.push(`  proof_photo  : ${payload.proof_photo}`);
  }
  if (payload.added_test) {
    const at = payload.added_test;
    lines.push(`  added_test   : id=${at.id}  name=${at.name}  price=${Number(at.price).toFixed(2)}` +
      ` [doc:${at.document_required}]  image=${at.document}`);
  }
  if (payload.removed_test) {
    const rt = payload.removed_test;
    lines.push(`  removed_test : id=${rt.id}  name=${rt.name}  price=${Number(rt.price).toFixed(2)}`);
  }
  if (payload.bookings) {
    lines.push(`  bookings     : ${payload.bookings.length} booking(s) in visit`);
    for (const bk of payload.bookings) {
      lines.push(`  ── booking_ref=${bk.booking_ref}  existing_bill=${bk.existing_bill_id ?? 'none'}`);
      lines.push(bk.patient_details
        ? `     patient   : NEW  name=${bk.patient_details.name}`
        : `     patient   : EXISTING  patient_id=${bk.patient_id}`);
      if (bk.blood_test_list.length === 0) {
        lines.push('     test      : (none)');
      } else {
        for (const t of bk.blood_test_list) {
          lines.push(`     test      : id=${t.id}  name=${t.name}  price=${Number(t.price).toFixed(2)}` +
            ` [doc:${t.document_required}]  image=${t.document}`);
        }
      }
      const bp = bk.payment_details;
      const bdue = Number(bp.total_amount) - Number(bp.paid_amount);
      lines.push(`     payment   : total=${bp.total_amount}  paid=${Number(bp.paid_amount).toFixed(2)}` +
        `  due=${bdue.toFixed(2)}  type=${bp.payment_type}`);
      lines.push(`     photo     : ${bk.proof_photo}`);
    }
  }
  lines.push(`  action       : ${payload.action}`);
  lines.push(
    `RESPONSE  status:${httpStatus ?? 'ERR'}` +
    (result?.action     != null ? `  action=${result.action}`         : '') +
    (result?.patient_id  != null ? `  patient_id=${result.patient_id}` : '') +
    (result?.bill_id     != null ? `  bill_id=${result.bill_id}`       : '') +
    (result == null ? '  (no response — see error above)' : '')
  );
  lines.push('-'.repeat(50));
  lines.push('');

  const block = lines.join('\n') + '\n';
  process.stdout.write(block);
  fs.appendFileSync(LOG_FILE, block, 'utf8');
}

function formatDate(d) {
  if (!d) return null;
  const date = new Date(d);
  const dd = String(date.getDate()).padStart(2, '0');
  const mm = String(date.getMonth() + 1).padStart(2, '0');
  const yy = String(date.getFullYear()).slice(2);
  return `${dd}-${mm}-${yy}`;
}

// Shared per-booking data fetch — patient, current tests, current payment,
// and the most recent collection-proof photo. Used by both the generic
// single-booking payload (syncBookingToClient) and the consolidated
// visit-completion payload (syncVisitCompletionToClient) below, so both
// draw from one proven query instead of two copies that could drift apart.
// Takes an already-fetched `booking` row rather than re-querying it.
async function _fetchPatientTestsPayment(booking) {
  const bookingId = booking.booking_id;

  const [[patient]] = await db.execute(
    `SELECT patient_id, patient_id_ref, patient_name, patient_mobile,
            patient_gender, patient_city, patient_address, patient_email,
            patient_dob, patient_age, patient_relation, health_conditions, patient_photo
     FROM ip_patients WHERE patient_id = ?`,
    [booking.patient_id]
  );
  if (!patient) return null;

  const [tests] = await db.execute(
    `SELECT bi.booking_item_id, bi.product_id,
            COALESCE(bi.product_name_snapshot, p.product_name) AS name,
            bi.final_price                                      AS price,
            p.document_required,
            (SELECT bd.file_path
             FROM ip_booking_documents bd
             WHERE bd.booking_id = ?
               AND (bd.booking_item_id = bi.booking_item_id OR bd.booking_item_id IS NULL)
               AND bd.file_description = 'prescription'
             ORDER BY bd.booking_item_id IS NULL, bd.created_at DESC
             LIMIT 1) AS prescription_url
     FROM ip_booking_items bi
     LEFT JOIN ip_products p ON p.product_id = bi.product_id
     WHERE bi.booking_id = ?`,
    [bookingId, bookingId]
  );

  const [[payment]] = await db.execute(
    `SELECT payment_type, amount_paid, amount_due, gateway_transaction_id
     FROM ip_payment_transactions
     WHERE booking_id = ? AND (is_refund = 0 OR is_refund IS NULL)
     ORDER BY created_at DESC LIMIT 1`,
    [bookingId]
  );

  const [[proofRow]] = await db.execute(
    `SELECT file_path FROM ip_booking_documents
     WHERE booking_id = ? AND file_description = 'collection_proof'
     ORDER BY created_at DESC LIMIT 1`,
    [bookingId]
  );

  const isNewPatient = !patient.patient_id_ref;

  const bloodTestList = tests.map(t => {
    const docReq = t.document_required === 1 || t.document_required === '1' || t.document_required === 'yes';
    return {
      id:                t.product_id,
      name:              t.name,
      price:             t.price,
      document_required: docReq ? 'yes' : 'no',
      document:          t.prescription_url ?? 'no',
    };
  });
  const paymentDetails = {
    total_amount:        booking.total_amount,
    paid_amount:         payment?.amount_paid  ?? 0,
    payment_type:        payment?.payment_type === 'RAZORPAY' ? 'full payment' : 'pay_later',
    razorpay_payment_id: payment?.gateway_transaction_id ?? null,
  };
  const patientDetails = {
    name:             patient.patient_name,
    mobile:           patient.patient_mobile,
    gender:           patient.patient_gender,
    location:         patient.patient_city,
    address:          patient.patient_address,
    email:            patient.patient_email,
    date_of_birth:    formatDate(patient.patient_dob),
    age:              patient.patient_age,
    relation:         patient.patient_relation,
    health_condition: patient.health_conditions,
    photo:            patient.patient_photo,
  };

  return {
    patient, tests, payment, isNewPatient,
    bloodTestList, paymentDetails, patientDetails,
    proofPhoto: proofRow?.file_path ?? null,
  };
}

function postJson(url, payload, timeoutMs) {
  return new Promise((resolve, reject) => {
    const body   = JSON.stringify(payload);
    const parsed = new URL(url);
    const lib    = parsed.protocol === 'https:' ? https : http;
    const req    = lib.request(
      {
        hostname: parsed.hostname,
        port:     parsed.port || (parsed.protocol === 'https:' ? 443 : 80),
        path:     parsed.pathname + parsed.search,
        method:   'POST',
        headers:  {
          'Content-Type':   'application/json',
          'Content-Length': Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = '';
        res.on('data', chunk => (data += chunk));
        res.on('end', () => {
          try { resolve({ httpStatus: res.statusCode, body: JSON.parse(data) }); }
          catch (e) { reject(new Error(`Non-JSON response: ${data.slice(0, 300)}`)); }
        });
      }
    );
    req.setTimeout(timeoutMs, () => { req.destroy(); reject(new Error('Request timeout')); });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

/**
 * Syncs a confirmed booking to the client server.
 * Fire-and-forget — never throws, logs all errors.
 *
 * @param {number} bookingId
 * @param {{ mobile: string, type: string, action?: string, technicianId?: number, proofPhoto?: string, addedTest?: object, removedTest?: object, visitGroupId?: string }} initiator
 *   — logged-in user; technicianId/proofPhoto are only used by collection_photo_added,
 *   addedTest by package_added, removedTest by package_removed, technicianId/visitGroupId by family_member_added
 */
async function syncBookingToClient(bookingId, initiator) {
  if (!settings.getBool('client_sync_enabled', true)) {
    writeLog(`[clientSync] disabled — skipping booking_id=${bookingId}`);
    return;
  }

  const clientUrl = process.env.CLIENT_BOOKING_URL;
  if (!clientUrl) {
    writeLog(`[clientSync] CLIENT_SERVER_URL not set — skipping`);
    return;
  }

  writeLog(`[clientSync] starting — booking_id=${bookingId} initiator=${initiator.mobile} type=${initiator.type} action=${initiator.action ?? 'auto'}`);

  // Mark as pending before attempting the HTTP call
  try {
    await db.execute(
      `UPDATE ip_bookings SET client_sync_status = 'pending' WHERE booking_id = ?`,
      [bookingId]
    );
  } catch (dbErr) {
    writeLog(`[clientSync] ⚠️  could not set pending — ${dbErr.message}`);
  }

  try {
    // 1. Booking + slot time
    const [[booking]] = await db.execute(
      `SELECT b.booking_id, b.booking_ref, b.booking_type, b.booking_date,
              b.total_amount, b.patient_id, b.client_id, b.status, b.bill_id,
              b.visit_group_id,
              TIME_FORMAT(av.slot_time, '%h:%i %p') AS slot_time
       FROM ip_bookings b
       LEFT JOIN ip_available_slots av ON av.available_slot_id = b.available_slot_id
       WHERE b.booking_id = ?`,
      [bookingId]
    );
    if (!booking) {
      writeLog(`[clientSync] booking_id=${bookingId} not found`);
      return;
    }

    const timestamp = Math.floor(Date.now() / 1000);
    const secure_id = buildSecureId(initiator.mobile, initiator.type, String(timestamp));
    const action = initiator.action
      ?? (booking.status === 'cancelled' ? 'cancel'
        : booking.bill_id               ? 'update'
        :                                 'new_booking');

    let payload;
    let tests = [];

    if (action === 'collection_photo_added') {
      // Jayamala's spec for this action is a distinct minimal shape — no
      // booking/patient/test/payment blob, just enough to identify the
      // booking plus who took the photo and the photo itself.
      let technicianName = null;
      if (initiator.technicianId) {
        const [[techRow]] = await db.execute(
          `SELECT u.user_name FROM ip_technicians t
           JOIN ip_users u ON u.user_id = t.user_id
           WHERE t.technician_id = ? LIMIT 1`,
          [initiator.technicianId]
        );
        technicianName = techRow?.user_name ?? null;
      }
      payload = {
        mobile_no:    initiator.mobile,
        user_type:    initiator.type,
        timestamp,
        secure_id,
        action,
        booking_ref:      booking.booking_ref,
        existing_bill_id: booking.bill_id ?? null,
        technician_details: {
          technician_id: initiator.technicianId ?? null,
          name:          technicianName,
        },
        proof_photo: initiator.proofPhoto ?? null,
      };
      writeLog(`[clientSync] sending — action=collection_photo_added technician_id=${initiator.technicianId}`);
    } else if (action === 'package_added') {
      // Jayamala's spec for this action is also a distinct minimal shape —
      // just the one newly added test, not the whole booking's test list.
      const at = initiator.addedTest ?? {};
      payload = {
        mobile_no:    initiator.mobile,
        user_type:    initiator.type,
        timestamp,
        secure_id,
        action,
        booking_ref:      booking.booking_ref,
        existing_bill_id: booking.bill_id ?? null,
        added_test: {
          id:                at.id ?? null,
          name:              at.name ?? null,
          price:             at.price ?? null,
          document_required: at.documentRequired ? 'yes' : 'no',
          document:          at.documentUrl ?? 'no',
        },
      };
      writeLog(`[clientSync] sending — action=package_added added_test_id=${at.id}`);
    } else if (action === 'package_removed') {
      // Proposed action, mirrors package_added's shape — awaiting Jayamala
      // confirmation. Just the one removed test, no document fields (nothing
      // to attach to a removal).
      const rt = initiator.removedTest ?? {};
      payload = {
        mobile_no:    initiator.mobile,
        user_type:    initiator.type,
        timestamp,
        secure_id,
        action,
        booking_ref:      booking.booking_ref,
        existing_bill_id: booking.bill_id ?? null,
        removed_test: {
          id:    rt.id ?? null,
          name:  rt.name ?? null,
          price: rt.price ?? null,
        },
      };
      writeLog(`[clientSync] sending — action=package_removed removed_test_id=${rt.id}`);
    } else {
      // Patient + tests + payment — shared with syncVisitCompletionToClient
      // below, so both draw from one proven query instead of two copies
      // that could drift apart.
      const data = await _fetchPatientTestsPayment(booking);
      if (!data) {
        writeLog(`[clientSync] patient_id=${booking.patient_id} not found`);
        return;
      }
      const { isNewPatient, bloodTestList, paymentDetails, patientDetails, patient } = data;
      tests = data.tests;

      if (action === 'family_member_added') {
        // Jayamala's spec for this action omits booking_status/existing_bill_id/
        // booking_type/slot_details entirely, and adds visit_group_id +
        // technician_details instead — a technician is always the initiator
        // for this action, never the account-holder.
        let technicianName = null;
        if (initiator.technicianId) {
          const [[techRow]] = await db.execute(
            `SELECT u.user_name FROM ip_technicians t
             JOIN ip_users u ON u.user_id = t.user_id
             WHERE t.technician_id = ? LIMIT 1`,
            [initiator.technicianId]
          );
          technicianName = techRow?.user_name ?? null;
        }
        payload = {
          mobile_no:      initiator.mobile,
          user_type:      initiator.type,
          timestamp,
          secure_id,
          action,
          booking_ref:      booking.booking_ref,
          visit_group_id:   initiator.visitGroupId ?? booking.visit_group_id ?? null,
          technician_details: {
            technician_id: initiator.technicianId ?? null,
            name:          technicianName,
          },
          blood_test_list: bloodTestList,
          payment_details: paymentDetails,
        };
        if (isNewPatient) {
          payload.patient_details = patientDetails;
        } else {
          payload.patient_id = patient.patient_id_ref;
        }
        writeLog(`[clientSync] sending — family_member_added new_patient=${isNewPatient} tests=${tests.length}`);
      } else {
        payload = {
          mobile_no:    initiator.mobile,
          user_type:    initiator.type,
          timestamp,
          secure_id,
          booking_ref:      booking.booking_ref,
          booking_status:   booking.status,
          existing_bill_id: booking.bill_id ?? null,
          action,
          booking_type: booking.booking_type,
          slot_details: {
            date: formatDate(booking.booking_date),
            time: booking.slot_time ?? null,
          },
          blood_test_list: bloodTestList,
          payment_details: paymentDetails,
        };
        if (isNewPatient) {
          payload.patient_details = patientDetails;
        } else {
          payload.patient_id = patient.patient_id_ref;
        }
        writeLog(`[clientSync] sending — new_patient=${isNewPatient} tests=${tests.length}`);
      }
    }

    
    // 6. POST to client server
    const timeoutMs = parseInt(settings.get('client_sync_timeout_ms', '10000'), 10);
    let httpStatus, result;
    try {
      ({ httpStatus, body: result } = await postJson(clientUrl, payload, timeoutMs));
    } catch (postErr) {
      // Log the request block even when no response came back (timeout,
      // network error, non-JSON body) — httpStatus/result stay null, the
      // block renders "(no response — see error above)" for RESPONSE.
      _logRequestResponseBlock({ payload, tests, httpStatus: null, result: null });
      throw postErr; // preserves the existing outer catch's error logging
    }

    _logRequestResponseBlock({ payload, tests, httpStatus, result });

    if (result.status === 'success') {
      if (result.bill_id && booking.status !== 'cancelled') {
        await db.execute(
          `UPDATE ip_bookings SET bill_id = ?, client_sync_status = 'synced' WHERE booking_id = ?`,
          [String(result.bill_id), bookingId]
        );
        writeLog(`[clientSync] ✅ bill_id=${result.bill_id} saved — booking_id=${bookingId}`);
      } else {
        await db.execute(
          `UPDATE ip_bookings SET client_sync_status = 'synced' WHERE booking_id = ?`,
          [bookingId]
        );
        writeLog(`[clientSync] ✅ synced (no bill_id) — booking_id=${bookingId}`);
      }

      if (payload.patient_details && result.patient_id) {
        const ref = String(result.patient_id);
        await db.execute(
          `UPDATE ip_patients SET patient_id_ref = ? WHERE patient_id = ?`,
          [ref, booking.patient_id]
        );
        await db.execute(
          `UPDATE ip_bookings SET patient_id_ref = ? WHERE booking_id = ?`,
          [ref, bookingId]
        );
        await db.execute(
          `UPDATE ip_patient_bookings SET patient_ref = ? WHERE booking_id = ? AND patient_id = ?`,
          [ref, bookingId, booking.patient_id]
        );
        writeLog(`[clientSync] ✅ patient_id_ref=${result.patient_id} saved — patient_id=${booking.patient_id} booking_id=${bookingId}`);
      }

      // Send "Booking Confirmed" push ONLY for new bookings, not cancel/reschedule/update
      const resolvedAction = payload.action;
      if (resolvedAction === 'new_booking') {
        await _sendBookingConfirmedNotification(booking, initiator.mobile);
      }

    } else {
      writeLog(`[clientSync] ⚠️  client server failure — ${result.msg ?? 'no message'}`);
    }
  } catch (err) {
    writeLog(`[clientSync] ❌ ERROR — ${err.message}`);
  }
}

/**
 * Sends ONE consolidated payload for a whole visit to the client server —
 * the primary booking plus every sibling booking sharing its visit_group_id,
 * each with its own current tests, payment, and collection photo. Called
 * once, from verifyBookingOtp, after OTP verification succeeds. Replaces
 * the per-action package_added / payment_update / family_member_added /
 * collection_photo_added syncs for the technician flow — those calls were
 * removed from their respective controllers; this is now the only place
 * that data reaches the client server for a technician-run visit.
 *
 * The payload shape (action: 'visit_completed', a `bookings` array) is not
 * yet confirmed by Jayamala — unlike every other action in this file, it
 * was not built from a spec they provided. Check client_sync.log after the
 * first real visits to confirm the response actually matches what's
 * expected, not just that it returned status:200.
 *
 * Fire-and-forget — never throws, logs all errors. A failure here can never
 * affect OTP verification itself, since this is called after that response
 * has already been sent to the technician's app.
 *
 * @param {number} primaryBookingId
 * @param {{ mobile: string, type: string, technicianId?: number }} initiator
 */
async function syncVisitCompletionToClient(primaryBookingId, initiator) {
  if (!settings.getBool('client_sync_enabled', true)) {
    writeLog(`[clientSync] disabled — skipping visit_completed booking_id=${primaryBookingId}`);
    return;
  }
  if (!settings.getBool('visit_completion_sync_enabled', true)) {
    writeLog(`[clientSync] visit_completion_sync_enabled=false — skipping booking_id=${primaryBookingId}`);
    return;
  }

  const clientUrl = process.env.CLIENT_BOOKING_URL;
  if (!clientUrl) {
    writeLog(`[clientSync] CLIENT_SERVER_URL not set — skipping visit_completed`);
    return;
  }

  writeLog(`[clientSync] starting — action=visit_completed primary_booking_id=${primaryBookingId} initiator=${initiator.mobile}`);

  try {
    const [[primaryBooking]] = await db.execute(
      `SELECT booking_id, booking_ref, patient_id, status, bill_id, visit_group_id
       FROM ip_bookings WHERE booking_id = ?`,
      [primaryBookingId]
    );
    if (!primaryBooking) {
      writeLog(`[clientSync] booking_id=${primaryBookingId} not found — visit_completed skipped`);
      return;
    }

    // Resolve every booking in this visit — primary + siblings sharing the
    // same visit_group_id, same grouping already proven correct by
    // verifyBookingOtp's own status cascade. A solo (non-family) booking
    // just resolves to itself.
    let bookingRows;
    if (primaryBooking.visit_group_id) {
      [bookingRows] = await db.execute(
        `SELECT booking_id, booking_ref, booking_type, booking_date, total_amount,
                patient_id, client_id, status, bill_id, visit_group_id,
                TIME_FORMAT(
                  (SELECT av.slot_time FROM ip_available_slots av
                   WHERE av.available_slot_id = b.available_slot_id), '%h:%i %p'
                ) AS slot_time
         FROM ip_bookings b
         WHERE b.visit_group_id = ? AND b.deleted_at IS NULL
         ORDER BY b.booking_id ASC`,
        [primaryBooking.visit_group_id]
      );
    } else {
      const [[b]] = await db.execute(
        `SELECT b.booking_id, b.booking_ref, b.booking_type, b.booking_date, b.total_amount,
                b.patient_id, b.client_id, b.status, b.bill_id, b.visit_group_id,
                TIME_FORMAT(av.slot_time, '%h:%i %p') AS slot_time
         FROM ip_bookings b
         LEFT JOIN ip_available_slots av ON av.available_slot_id = b.available_slot_id
         WHERE b.booking_id = ?`,
        [primaryBookingId]
      );
      bookingRows = b ? [b] : [];
    }

    if (bookingRows.length === 0) {
      writeLog(`[clientSync] no bookings resolved for visit — primary_booking_id=${primaryBookingId}`);
      return;
    }

    // Mark all of them pending before attempting the HTTP call.
    try {
      await db.execute(
        `UPDATE ip_bookings SET client_sync_status = 'pending' WHERE booking_id IN (${bookingRows.map(() => '?').join(',')})`,
        bookingRows.map(b => b.booking_id)
      );
    } catch (dbErr) {
      writeLog(`[clientSync] ⚠️  could not set pending — ${dbErr.message}`);
    }

    const bookings = [];
    // Jayamala's endpoint validates patient_id/patient_details at the request
    // root, same as every other action — it doesn't look inside bookings[].
    // Captured here (from the primary booking specifically) so it can also
    // be set at the top level of the payload below, alongside the unchanged
    // per-booking value inside bookings[].
    let primaryPatientId = null;
    let primaryPatientDetails = null;
    for (const b of bookingRows) {
      const data = await _fetchPatientTestsPayment(b);
      if (!data) {
        writeLog(`[clientSync] patient_id=${b.patient_id} not found for booking_id=${b.booking_id} — skipped from visit_completed payload`);
        continue;
      }
      const entry = {
        booking_ref:      b.booking_ref,
        existing_bill_id: b.bill_id ?? null,
        blood_test_list:  data.bloodTestList,
        payment_details:  data.paymentDetails,
        proof_photo:      data.proofPhoto ?? 'no',
      };
      if (data.isNewPatient) {
        entry.patient_details = data.patientDetails;
      } else {
        entry.patient_id = data.patient.patient_id_ref;
      }
      bookings.push(entry);

      if (b.booking_id === primaryBookingId) {
        if (data.isNewPatient) {
          primaryPatientDetails = data.patientDetails;
        } else {
          primaryPatientId = data.patient.patient_id_ref;
        }
      }
    }

    if (bookings.length === 0) {
      writeLog(`[clientSync] no bookings had a resolvable patient — visit_completed skipped for primary_booking_id=${primaryBookingId}`);
      return;
    }

    let technicianName = null;
    if (initiator.technicianId) {
      const [[techRow]] = await db.execute(
        `SELECT u.user_name FROM ip_technicians t
         JOIN ip_users u ON u.user_id = t.user_id
         WHERE t.technician_id = ? LIMIT 1`,
        [initiator.technicianId]
      );
      technicianName = techRow?.user_name ?? null;
    }

    const timestamp = Math.floor(Date.now() / 1000);
    const secure_id = buildSecureId(initiator.mobile, initiator.type, String(timestamp));

    const payload = {
      mobile_no:    initiator.mobile,
      user_type:    initiator.type,
      timestamp,
      secure_id,
      action:          'visit_completed',
      booking_ref:     primaryBooking.booking_ref,
      visit_group_id:  primaryBooking.visit_group_id ?? null,
      technician_details: {
        technician_id: initiator.technicianId ?? null,
        name:          technicianName,
      },
      bookings,
    };
    // Top-level patient_id/patient_details, mirroring the primary booking's
    // own patient — required by Jayamala's validation, which checks the
    // request root the same way every other action does. bookings[]'s own
    // per-entry patient_id/patient_details is unchanged.
    if (primaryPatientDetails) {
      payload.patient_details = primaryPatientDetails;
    } else if (primaryPatientId) {
      payload.patient_id = primaryPatientId;
    }

    writeLog(`[clientSync] sending — action=visit_completed bookings=${bookings.length} primary_booking_id=${primaryBookingId}`);

    const timeoutMs = parseInt(settings.get('client_sync_timeout_ms', '10000'), 10);
    let httpStatus, result;
    try {
      ({ httpStatus, body: result } = await postJson(clientUrl, payload, timeoutMs));
    } catch (postErr) {
      _logRequestResponseBlock({ payload, tests: [], httpStatus: null, result: null });
      throw postErr;
    }

    _logRequestResponseBlock({ payload, tests: [], httpStatus, result });

    if (result.status === 'success') {
      const bookingIds = bookingRows.map(b => b.booking_id);
      await db.execute(
        `UPDATE ip_bookings SET client_sync_status = 'synced' WHERE booking_id IN (${bookingIds.map(() => '?').join(',')})`,
        bookingIds
      );

      // bill_id/patient_id attribution across multiple bookings in one
      // response is unconfirmed — Jayamala has only ever returned a single
      // bill_id/patient_id for a single-booking request before now. Applying
      // a returned value to every sibling booking would be a guess that
      // could silently overwrite an already-correct bill_id, so only the
      // primary booking is updated here. If the real response turns out to
      // carry per-booking identifiers, this needs a follow-up fix once
      // that shape is confirmed.
      if (result.bill_id) {
        await db.execute(
          `UPDATE ip_bookings SET bill_id = ? WHERE booking_id = ?`,
          [String(result.bill_id), primaryBookingId]
        );
        writeLog(`[clientSync] ✅ bill_id=${result.bill_id} saved to primary booking_id=${primaryBookingId} (not applied to siblings — see code comment)`);
      }
      if (result.patient_id) {
        const primaryEntry = bookings.find(bk => bk.booking_ref === primaryBooking.booking_ref);
        if (primaryEntry?.patient_details) {
          const ref = String(result.patient_id);
          await db.execute(`UPDATE ip_patients SET patient_id_ref = ? WHERE patient_id = ?`, [ref, primaryBooking.patient_id]);
          await db.execute(`UPDATE ip_bookings SET patient_id_ref = ? WHERE booking_id = ?`, [ref, primaryBookingId]);
          writeLog(`[clientSync] ✅ patient_id_ref=${result.patient_id} saved to primary patient_id=${primaryBooking.patient_id}`);
        }
      }

      writeLog(`[clientSync] ✅ visit_completed synced — ${bookings.length} booking(s) — primary_booking_id=${primaryBookingId}`);
    } else {
      writeLog(`[clientSync] ⚠️  client server failure — ${result.msg ?? 'no message'}`);
    }
  } catch (err) {
    writeLog(`[clientSync] ❌ ERROR — ${err.message}`);
  }
}

async function _sendBookingConfirmedNotification(booking, initiatorMobile) {
  if (!messaging) {
    writeLog(`[clientSync] push skipped — Firebase not initialised`);
    return;
  }
  try {
    const [[userRow]] = await db.execute(
      `SELECT user_notification_token FROM ip_users
       WHERE user_mobile_no = ? AND user_microlab_type = 'patient_user' LIMIT 1`,
      [initiatorMobile]
    );
    const fcmToken = userRow?.user_notification_token;
    if (!fcmToken) {
      writeLog(`[clientSync] push skipped — no FCM token for ${initiatorMobile}`);
      return;
    }
    await messaging.send({
      token: fcmToken,
      notification: {
        title: 'Booking Confirmed ✅',
        body:  `Your booking #${booking.booking_ref} has been confirmed. We will contact you shortly.`,
      },
      data: {
        type:        'booking_confirmed',
        booking_id:  String(booking.booking_id),
        booking_ref: booking.booking_ref,
      },
      android: {
        priority: 'high',
        notification: { channelId: 'booking_updates' },
      },
    });
    writeLog(`[clientSync] 🔔 push sent — booking_id=${booking.booking_id} mobile=${initiatorMobile}`);
  } catch (pushErr) {
    writeLog(`[clientSync] ⚠️  push failed — ${pushErr.message}`);
  }
}

module.exports = { syncBookingToClient, syncVisitCompletionToClient };