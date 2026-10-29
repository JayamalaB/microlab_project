const https  = require('https');
const http   = require('http');
const path   = require('path');
const fs     = require('fs');
const db     = require('../config/db');
const settings = require('../config/settings');
const { messaging } = require('../config/firebase');
const { buildSecureId } = require('../utils/secureId');
const { getSecret, refreshSecret } = require('./secretCache');
const dbLogger = require('../utils/dbLogger');
const { logAsmx } = require('./asmxLogger');
const { getBranchCode } = require('./branchCodes');

const LOG_FILE = path.join(__dirname, '..', 'logs', 'client_sync.log');

function writeLog(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false }).replace(',', '') + ' IST';
  const line = `[${ist}] ${msg}\n`;
  process.stdout.write(line);
  fs.appendFileSync(LOG_FILE, line, 'utf8');
  dbLogger.logClientSyncEvent(msg);
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
        lines.push(`  test         : TestId=${t.TestId}  name=${t.TestName}  rate=${Number(t.Rate).toFixed(2)}`);
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
          lines.push(`     test      : TestId=${t.TestId}  name=${t.TestName}  rate=${Number(t.Rate).toFixed(2)}`);
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

function _isSignatureError(result) {
  // ASMX sometimes returns a bare number (401/403) for auth failures
  if (typeof result === 'number') return result === 401 || result === 403;
  const msg = (result?.msg ?? result?.message ?? '').toLowerCase();
  return msg.includes('sign') || msg.includes('secret') ||
         msg.includes('unauthor') || msg.includes('invalid') || msg.includes('auth');
}

function formatDate(d) {
  if (!d) return null;
  const date = new Date(d);
  const dd = String(date.getDate()).padStart(2, '0');
  const mm = String(date.getMonth() + 1).padStart(2, '0');
  const yyyy = String(date.getFullYear());
  return `${dd}/${mm}/${yyyy}`;
}

// ASMX method name for ip_asmx_logs.endpoint — the last path segment of the
// URL (…/Neuralarc.asmx/TechnicianVisitCompleted → "TechnicianVisitCompleted").
function _asmxMethodName(url) {
  try {
    return new URL(url).pathname.split('/').filter(Boolean).pop() || 'unknown';
  } catch {
    return 'unknown';
  }
}

// ── visit_completed formatting helpers ───────────────────────────────────────
// DB DECIMAL ("878.00") → number (878). JSON shows whole amounts without
// ".00" — the same value.
function _toAmount(v) {
  if (v === null || v === undefined || v === '') return 0;
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function _round2(n) {
  return Math.round(n * 100) / 100;
}

// Technician ID as a number when it is numeric ("262" → 262).
function _toIdNumber(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isInteger(n) ? n : v;
}

// "Dinesh Kumar S (0107057)" → "Dinesh Kumar S" — drops a trailing "(code)".
function _cleanTechnicianName(name) {
  if (typeof name !== 'string') return name ?? null;
  return name.replace(/\s*\([^)]*\)\s*$/, '').trim();
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
            p.test_code,
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

  const bloodTestList = tests.map(t => ({
    TestId:   t.test_code,
    TestName: t.name,
    Rate:     t.price,
  }));
  const testAmount = _round2(tests.reduce((s, t) => s + _toAmount(t.price), 0));
  const paymentDetails = {
    test_amount:           testAmount,
    service_charge_amount: _toAmount(booking.home_collection_fare),
    total_amount:          booking.total_amount,
    paid_amount:           payment?.amount_paid  ?? 0,
    payment_type:          payment?.payment_type === 'RAZORPAY' ? 'full payment' : 'pay_later',
    razorpay_payment_id:   payment?.gateway_transaction_id ?? null,
  };
  const patientDetails = {
    name:             patient.patient_name,
    mobile:           patient.patient_mobile,
    gender:           patient.patient_gender?.toLowerCase() ?? null,
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

// Posts payload as <paramName>=<urlencoded JSON> to the Neuralarc ASMX endpoint
// (HTTP POST protocol). paramName is the method's parameter on its ?op= help
// page: bookingJson for the booking methods, visitCompleteJson for
// TechnicianVisitCompleted.
// Response is XML-wrapped: <string xmlns="...">JSON_STRING</string>
// Resolves { httpStatus, body, raw, durationMs } — raw is the response text
// exactly as received. Errors carry err.httpStatus / err.raw / err.durationMs
// when a response arrived but couldn't be read, so callers can log it.
function postAsmx(url, payload, timeoutMs, paramName = 'bookingJson') {
  return new Promise((resolve, reject) => {
    const body    = `${paramName}=` + encodeURIComponent(JSON.stringify(payload));
    const parsed  = new URL(url);
    const lib     = parsed.protocol === 'https:' ? https : http;
    const started = Date.now();
    const fail = (message, extra = {}) =>
      reject(Object.assign(new Error(message), { durationMs: Date.now() - started }, extra));
    const req = lib.request(
      {
        hostname: parsed.hostname,
        port:     parsed.port || (parsed.protocol === 'https:' ? 443 : 80),
        path:     parsed.pathname + parsed.search,
        method:   'POST',
        headers:  {
          'Content-Type':   'application/x-www-form-urlencoded',
          'Content-Length': Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = '';
        res.on('data', chunk => (data += chunk));
        res.on('end', () => {
          const match = data.match(/<string[^>]*>([\s\S]*?)<\/string>/);
          if (!match) {
            fail(`Unexpected ASMX response: ${data.slice(0, 300)}`, { httpStatus: res.statusCode, raw: data });
            return;
          }
          try {
            resolve({ httpStatus: res.statusCode, body: JSON.parse(match[1]), raw: data, durationMs: Date.now() - started });
          } catch (e) {
            fail(`Non-JSON ASMX result: ${match[1].slice(0, 300)}`, { httpStatus: res.statusCode, raw: data });
          }
        });
      }
    );
    req.setTimeout(timeoutMs, () => { req.destroy(); fail('ASMX request timeout'); });
    req.on('error', (err) => fail(err.message, { code: err.code }));
    req.write(body);
    req.end();
  });
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
              b.total_amount, b.home_collection_fare, b.patient_id, b.client_id,
              b.status, b.reference_no, b.visit_group_id,
              TIME_FORMAT(av.slot_time, '%H:%i') AS slot_time
       FROM ip_bookings b
       LEFT JOIN ip_available_slots av ON av.available_slot_id = b.available_slot_id
       WHERE b.booking_id = ?`,
      [bookingId]
    );
    if (!booking) {
      writeLog(`[clientSync] booking_id=${bookingId} not found`);
      return;
    }

    // Diagnostic: log fare for every sync so we can spot NULL home_collection_fare
    if (booking.booking_type === 'home_collection') {
      const fareVal = booking.home_collection_fare;
      writeLog(
        `[clientSync] 🔍 FARE AUDIT booking_id=${bookingId} ref=${booking.booking_ref}` +
        `  home_collection_fare=${fareVal != null ? '₹' + fareVal : 'NULL ⚠️'}` +
        `  total_amount=${booking.total_amount}`
      );
    }

    const timestamp = Math.floor(Date.now() / 1000);
    const secret    = await getSecret();
    const secure_id = buildSecureId(initiator.mobile, initiator.type, String(timestamp), secret);
    const action = initiator.action
      ?? (booking.status === 'cancelled' ? 'cancel'
        : booking.reference_no          ? 'update'
        :                                 'new_booking');

    let payload;
    let tests = [];

    if (action === 'collection_photo_added') {
      // Jayamala's spec for this action is a distinct minimal shape — no
      // booking/patient/test/payment blob, just enough to identify the
      // booking plus who took the photo and the photo itself.
      let technicianName = null;
      let technicianRef  = null; // ASMX technician ID (ip_technicians.technician_id_ref)
      if (initiator.technicianId) {
        const [[techRow]] = await db.execute(
          `SELECT u.user_name, t.technician_id_ref FROM ip_technicians t
           JOIN ip_users u ON u.user_id = t.user_id
           WHERE t.technician_id = ? LIMIT 1`,
          [initiator.technicianId]
        );
        technicianName = techRow?.user_name ?? null;
        technicianRef  = techRow?.technician_id_ref ?? null;
      }
      payload = {
        mobile_no:    initiator.mobile,
        user_type:    initiator.type,
        timestamp,
        secure_id,
        action,
        booking_ref:      booking.booking_ref,
        existing_bill_id: booking.reference_no ?? null,
        technician_details: {
          // The external API's own technician ID; our ID only for
          // technicians it doesn't know (local-fallback logins).
          technician_id:          technicianRef ?? initiator.technicianId ?? null,
          microlab_technician_id: initiator.technicianId ?? null,
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
        existing_bill_id: booking.reference_no ?? null,
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
        existing_bill_id: booking.reference_no ?? null,
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
        let technicianRef  = null; // ASMX technician ID (ip_technicians.technician_id_ref)
        if (initiator.technicianId) {
          const [[techRow]] = await db.execute(
            `SELECT u.user_name, t.technician_id_ref FROM ip_technicians t
             JOIN ip_users u ON u.user_id = t.user_id
             WHERE t.technician_id = ? LIMIT 1`,
            [initiator.technicianId]
          );
          technicianName = techRow?.user_name ?? null;
          technicianRef  = techRow?.technician_id_ref ?? null;
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
            // The external API's own technician ID; our ID only for
            // technicians it doesn't know (local-fallback logins).
            technician_id:          technicianRef ?? initiator.technicianId ?? null,
            microlab_technician_id: initiator.technicianId ?? null,
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
          existing_bill_id: booking.reference_no ?? null,
          action,
          booking_type: booking.booking_type,
          slot_details: {
            date: formatDate(booking.booking_date),
            time: booking.slot_time ?? null,
          },
          blood_test_list: bloodTestList,
          payment_details: paymentDetails,
        };
        // Cancel/reschedule/payment_update/package_update always send patient_id — patient already exists on ASMX side
        if (isNewPatient && !['cancel', 'reschedule', 'payment_update', 'package_update'].includes(action)) {
          payload.patient_details = patientDetails;
        } else {
          payload.patient_id = patient.patient_id_ref;
        }
        writeLog(`[clientSync] sending — new_patient=${isNewPatient} tests=${tests.length}`);
      }
    }

    
    // 6. POST to client server
    const asmxUrl              = process.env.NEURALARC_BOOKING_URL;
    const existingAsmxUrl      = process.env.NEURALARC_EXISTING_BOOKING_URL;
    const cancelAsmxUrl        = process.env.NEURALARC_CANCEL_URL;
    const rescheduleAsmxUrl    = process.env.NEURALARC_RESCHEDULE_URL;
    const paymentAsmxUrl       = process.env.NEURALARC_PAYMENT_URL;
    const packageUpdateAsmxUrl = process.env.NEURALARC_PACKAGE_UPDATE_URL;
    const useAsmx              = action === 'new_booking'      && payload.patient_details != null && !!asmxUrl;
    const useExistingAsmx      = action === 'new_booking'      && payload.patient_details == null && payload.patient_id != null && !!existingAsmxUrl;
    const useCancelAsmx        = action === 'cancel'           && !!cancelAsmxUrl;
    const useRescheduleAsmx    = action === 'reschedule'       && !!rescheduleAsmxUrl;
    const usePaymentAsmx       = action === 'payment_update'   && !!paymentAsmxUrl;
    const usePackageUpdateAsmx = action === 'package_update'   && !!packageUpdateAsmxUrl;

    // Skip these actions if booking was never synced to ASMX (no bill_id).
    if (['cancel', 'reschedule', 'payment_update', 'package_update'].includes(action) && !booking.reference_no) {
      writeLog(`[clientSync] ${action} skipped — no reference_no, booking was never synced to ASMX`);
      return;
    }

    const timeoutMs    = parseInt(settings.get('client_sync_timeout_ms', '10000'), 10);
    const routeLabel   = useAsmx ? 'ASMX:new_booking' : useExistingAsmx ? 'ASMX:existing_booking' : useCancelAsmx ? 'ASMX:cancel' : useRescheduleAsmx ? 'ASMX:reschedule' : usePaymentAsmx ? 'ASMX:payment_update' : usePackageUpdateAsmx ? 'ASMX:package_update' : 'php';
    const asmxEndpoint = useAsmx ? 'NewPatientNewBooking' : useExistingAsmx ? 'ExistingPatientNewBooking' : useCancelAsmx ? 'BookingCancellation' : useRescheduleAsmx ? 'ReScheduleAppointment' : usePaymentAsmx ? 'PaymentUpdate' : usePackageUpdateAsmx ? 'PackageUpdate' : null;
    writeLog(`[clientSync] route=${routeLabel} action=${action}`);
    if (useAsmx || useExistingAsmx || useCancelAsmx || useRescheduleAsmx || usePaymentAsmx || usePackageUpdateAsmx) writeLog(`[clientSync] ASMX payload — ${JSON.stringify(payload)}`);
    let httpStatus, result;
    try {
      ({ httpStatus, body: result } = useAsmx
        ? await postAsmx(asmxUrl, payload, timeoutMs)
        : useExistingAsmx
          ? await postAsmx(existingAsmxUrl, payload, timeoutMs)
          : useCancelAsmx
            ? await postAsmx(cancelAsmxUrl, payload, timeoutMs)
            : useRescheduleAsmx
              ? await postAsmx(rescheduleAsmxUrl, payload, timeoutMs)
              : usePaymentAsmx
                ? await postAsmx(paymentAsmxUrl, payload, timeoutMs)
                : usePackageUpdateAsmx
                  ? await postAsmx(packageUpdateAsmxUrl, payload, timeoutMs)
                  : await postJson(clientUrl, payload, timeoutMs));
    } catch (postErr) {
      // Log the request block even when no response came back (timeout,
      // network error, non-JSON body) — httpStatus/result stay null, the
      // block renders "(no response — see error above)" for RESPONSE.
      _logRequestResponseBlock({ payload, tests, httpStatus: null, result: null });
      if (asmxEndpoint) await logAsmx(asmxEndpoint, { bookingRef: booking.booking_ref, bookingId, mobileNo: initiator.mobile, request: payload, response: null, httpStatus: null, success: false, errorMessage: postErr.message });
      throw postErr; // preserves the existing outer catch's error logging
    }

    _logRequestResponseBlock({ payload, tests, httpStatus, result });
    writeLog(`[clientSync] raw response — ${JSON.stringify(result)}`);

    // Auto-recover: if ASMX rejects due to invalid signature, refresh secret
    // from DB and retry the same call once with the new secure_id.
    if (result && _isSignatureError(result)) {
      writeLog(`[clientSync] ⚠️  signature error — refreshing secret and retrying`);
      const newSecret = await refreshSecret();
      payload.secure_id = buildSecureId(initiator.mobile, initiator.type, String(timestamp), newSecret);
      try {
        ({ httpStatus, body: result } = useAsmx
          ? await postAsmx(asmxUrl, payload, timeoutMs)
          : useExistingAsmx
            ? await postAsmx(existingAsmxUrl, payload, timeoutMs)
            : useCancelAsmx
              ? await postAsmx(cancelAsmxUrl, payload, timeoutMs)
              : useRescheduleAsmx
                ? await postAsmx(rescheduleAsmxUrl, payload, timeoutMs)
                : usePaymentAsmx
                  ? await postAsmx(paymentAsmxUrl, payload, timeoutMs)
                  : usePackageUpdateAsmx
                    ? await postAsmx(packageUpdateAsmxUrl, payload, timeoutMs)
                    : await postJson(clientUrl, payload, timeoutMs));
        _logRequestResponseBlock({ payload, tests, httpStatus, result });
        writeLog(`[clientSync] retry response — ${JSON.stringify(result)}`);
      } catch (retryErr) {
        writeLog(`[clientSync] ❌ retry ERROR — ${retryErr.message}`);
        if (asmxEndpoint) await logAsmx(asmxEndpoint, { bookingRef: booking.booking_ref, bookingId, mobileNo: initiator.mobile, request: payload, response: null, httpStatus: null, success: false, errorMessage: retryErr.message });
        return;
      }
    }

    if (asmxEndpoint) await logAsmx(asmxEndpoint, { bookingRef: booking.booking_ref, bookingId, mobileNo: initiator.mobile, request: payload, response: result, httpStatus, success: result?.status === 'success', errorMessage: result?.status === 'success' ? null : (result?.msg ?? null) });

    if (result.status === 'success') {
      if (result.bill_id && booking.status !== 'cancelled') {
        await db.execute(
          `UPDATE ip_bookings SET reference_no = ?, client_sync_status = 'synced' WHERE booking_id = ?`,
          [String(result.bill_id), bookingId]
        );
        writeLog(`[clientSync] ✅ reference_no=${result.bill_id} saved — booking_id=${bookingId}`);
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
 * @param {{ mobile: string, type: string, technicianId?: number,
 *           handover?: { branchId: number|null, receivedByName: string|null } }} initiator
 *   handover — given at the Handed to Lab step: our branch_id the samples
 *   were handed to, sent as the payload's branch_id (its branch_code).
 *   receivedByName is not sent to the ASMX (stored locally only).
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

  // ASMX TechnicianVisitCompleted — no fallback to micro_booking.php.
  const visitUrl     = process.env.VISIT_COMPLETED_URL;
  const asmxEndpoint = visitUrl ? _asmxMethodName(visitUrl) : 'TechnicianVisitCompleted';

  // One ip_asmx_logs row per visit sync, like technician login — written on
  // every outcome (skipped, error, partial, success). logCtx.bookingRef is
  // filled in once the primary booking is loaded.
  const logCtx = { bookingRef: null, bookingId: primaryBookingId, mobileNo: initiator.mobile };
  let visitLogged = false;
  const _logVisit = async (fields) => {
    visitLogged = true;
    await logAsmx(asmxEndpoint, { ...logCtx, ...fields });
  };

  if (!visitUrl) {
    writeLog(`[clientSync] VISIT_COMPLETED_URL not set in .env — skipping visit_completed booking_id=${primaryBookingId}`);
    await _logVisit({ request: null, response: null, httpStatus: null, success: false,
      errorMessage: 'skipped — VISIT_COMPLETED_URL not set in .env' });
    return;
  }

  writeLog(`[clientSync] starting — action=visit_completed endpoint=${asmxEndpoint} primary_booking_id=${primaryBookingId} initiator=${initiator.mobile}`);

  try {
    const [[primaryBooking]] = await db.execute(
      `SELECT booking_id, booking_ref, patient_id, client_id, branch_id, status, reference_no, visit_group_id
       FROM ip_bookings WHERE booking_id = ?`,
      [primaryBookingId]
    );
    if (!primaryBooking) {
      writeLog(`[clientSync] booking_id=${primaryBookingId} not found — visit_completed skipped`);
      await _logVisit({ request: null, response: null, httpStatus: null, success: false,
        errorMessage: 'skipped — primary booking not found' });
      return;
    }
    logCtx.bookingRef = primaryBooking.booking_ref;

    // Resolve every booking in this visit — primary + siblings sharing the
    // same visit_group_id, same grouping already proven correct by
    // verifyBookingOtp's own status cascade. A solo (non-family) booking
    // just resolves to itself.
    let bookingRows;
    if (primaryBooking.visit_group_id) {
      [bookingRows] = await db.execute(
        `SELECT booking_id, booking_ref, booking_type, booking_date, total_amount,
                home_collection_fare, additional_charge_amount, additional_charge_reason,
                patient_id, client_id, status, reference_no, visit_group_id,
                TIME_FORMAT(
                  (SELECT av.slot_time FROM ip_available_slots av
                   WHERE av.available_slot_id = b.available_slot_id), '%H:%i'
                ) AS slot_time
         FROM ip_bookings b
         WHERE b.visit_group_id = ? AND b.deleted_at IS NULL
         ORDER BY b.booking_id ASC`,
        [primaryBooking.visit_group_id]
      );
    } else {
      const [[b]] = await db.execute(
        `SELECT b.booking_id, b.booking_ref, b.booking_type, b.booking_date, b.total_amount,
                b.home_collection_fare, b.additional_charge_amount, b.additional_charge_reason,
                b.patient_id, b.client_id, b.status, b.reference_no, b.visit_group_id,
                TIME_FORMAT(av.slot_time, '%H:%i') AS slot_time
         FROM ip_bookings b
         LEFT JOIN ip_available_slots av ON av.available_slot_id = b.available_slot_id
         WHERE b.booking_id = ?`,
        [primaryBookingId]
      );
      bookingRows = b ? [b] : [];
    }

    if (bookingRows.length === 0) {
      writeLog(`[clientSync] no bookings resolved for visit — primary_booking_id=${primaryBookingId}`);
      await _logVisit({ request: null, response: null, httpStatus: null, success: false,
        errorMessage: 'skipped — no bookings resolved for the visit' });
      return;
    }

    // Diagnostic: log every booking in this visit group with fare details
    writeLog(`[clientSync] 🔍 VISIT GROUP FARE AUDIT — primary_booking_id=${primaryBookingId} group=${primaryBooking.visit_group_id ?? 'solo'} total_bookings=${bookingRows.length}`);
    bookingRows.forEach((b, i) => {
      const isPrimary = b.booking_id === primaryBookingId;
      const fareVal   = b.home_collection_fare;
      const fareStr   = fareVal != null ? `₹${fareVal}` : 'NULL ⚠️';
      writeLog(
        `[clientSync]   [${i + 1}] booking_id=${b.booking_id} ref=${b.booking_ref}` +
        `  ${isPrimary ? '← PRIMARY' : '← SIBLING'}` +
        `  home_collection_fare=${fareStr}` +
        `  total_amount=${b.total_amount}`
      );
    });

    // Mark all of them pending before attempting the HTTP call.
    try {
      await db.execute(
        `UPDATE ip_bookings SET client_sync_status = 'pending' WHERE booking_id IN (${bookingRows.map(() => '?').join(',')})`,
        bookingRows.map(b => b.booking_id)
      );
    } catch (dbErr) {
      writeLog(`[clientSync] ⚠️  could not set pending — ${dbErr.message}`);
    }

    // One entry per booking in the visit, fields in the agreed order:
    // booking_ref, booking_status, booking_type, existing_bill_id,
    // patient_id | patient_details, slot_details, blood_test_list,
    // payment_details, proof_photo.
    const bookings = [];
    // Parallel to bookings[]: what was sent for each entry, in the same order.
    // The ASMX replies with one result per booking in that order, so result N
    // is matched to sent[N].
    const sent = [];
    for (const b of bookingRows) {
      const data = await _fetchPatientTestsPayment(b);
      if (!data) {
        writeLog(`[clientSync] patient_id=${b.patient_id} not found for booking_id=${b.booking_id} — skipped from visit_completed payload`);
        continue;
      }
      const entry = {
        booking_ref:      b.booking_ref,
        booking_status:   b.status,
        booking_type:     b.booking_type,
        existing_bill_id: b.reference_no ? String(b.reference_no) : 'none',
      };
      if (data.isNewPatient) {
        // Same fields as the shared patientDetails, minus mobile, age as text.
        const { mobile: _mobile, ...patientDetails } = data.patientDetails;
        entry.patient_details = {
          ...patientDetails,
          age: patientDetails.age != null ? String(patientDetails.age) : null,
        };
      } else {
        entry.patient_id = String(data.patient.patient_id_ref); // text — keeps leading zeros
      }
      entry.slot_details = {
        date: formatDate(b.booking_date),
        time: b.slot_time ?? null,
      };
      entry.blood_test_list = data.bloodTestList;
      // total_amount = test_amount + service_charge_amount +
      // additional_charge_amount. The service charge (home-collection fare)
      // isn't stored per booking on its own, so it is what remains of the
      // total after the tests and the technician's additional charge.
      const totalAmount      = _toAmount(data.paymentDetails.total_amount);
      const additionalCharge = _toAmount(b.additional_charge_amount ?? 0);
      entry.payment_details = {
        test_amount:              data.paymentDetails.test_amount,
        service_charge_amount:    _toAmount(b.home_collection_fare),
        additional_charge_amount: additionalCharge,
        additional_charge_reason: b.additional_charge_reason ?? '',
        total_amount:             totalAmount,
        paid_amount:         _toAmount(data.paymentDetails.paid_amount),
        payment_type:        data.paymentDetails.payment_type,
        razorpay_payment_id: data.paymentDetails.razorpay_payment_id,
      };
      entry.proof_photo = data.proofPhoto ?? '';
      bookings.push(entry);
      sent.push({
        bookingId:     b.booking_id,
        bookingRef:    b.booking_ref,
        patientId:     b.patient_id,
        isNewPatient:  !!data.isNewPatient,
        sentPatientId: data.isNewPatient ? null : String(data.patient.patient_id_ref),
      });
    }

    if (bookings.length === 0) {
      writeLog(`[clientSync] no bookings had a resolvable patient — visit_completed skipped for primary_booking_id=${primaryBookingId}`);
      await _logVisit({ request: null, response: null, httpStatus: null, success: false,
        errorMessage: 'skipped — no booking in the visit had a resolvable patient' });
      return;
    }

    let technicianName = null;
    let technicianRef  = null; // ASMX technician ID (ip_technicians.technician_id_ref)
    if (initiator.technicianId) {
      const [[techRow]] = await db.execute(
        `SELECT u.user_name, t.technician_id_ref FROM ip_technicians t
         JOIN ip_users u ON u.user_id = t.user_id
         WHERE t.technician_id = ? LIMIT 1`,
        [initiator.technicianId]
      );
      technicianName = techRow?.user_name ?? null;
      technicianRef  = techRow?.technician_id_ref ?? null;
    }

    const timestamp = Math.floor(Date.now() / 1000);
    const secret    = await getSecret();
    const secure_id = buildSecureId(initiator.mobile, initiator.type, String(timestamp), secret);

    // Account holder = the customer who made the booking (ip_clients), with
    // their customer login (ip_users) as a fallback when the client row has
    // no mobile.
    const [[holder]] = await db.execute(
      `SELECT COALESCE(NULLIF(c.client_mobile_no, ''),
                       (SELECT u.user_mobile_no FROM ip_users u
                        WHERE u.client_id = c.client_id AND u.user_microlab_type = 'patient_user'
                        LIMIT 1)) AS mobile
       FROM ip_clients c WHERE c.client_id = ? LIMIT 1`,
      [primaryBooking.client_id]
    );

    // branch_id = the HANDOVER branch (the branch the samples were handed to
    // at the Handed to Lab step) as its ip_branches.branch_code. The
    // handover step already falls back to the booking's own branch when the
    // technician chose none; without handover info, the booking's branch.
    // Missing code → null (logged) — never derived from branch_id.
    const sendBranchId = initiator.handover?.branchId ?? primaryBooking.branch_id;
    let branchCode = null;
    try {
      branchCode = await getBranchCode(sendBranchId);
    } catch (err) {
      writeLog(`[clientSync] ⚠️  branch_code lookup failed — branch_id=${sendBranchId} error=${err.code ?? err.message}`);
    }
    if (branchCode == null && sendBranchId != null) {
      writeLog(`[clientSync] ⚠️  no branch_code for branch_id=${sendBranchId} — visit_completed branch_id sent as null`);
    }

    const payload = {
      mobile_no:         initiator.mobile,
      user_type:         initiator.type,
      timestamp,
      secure_id,
      action:            'visit_completed',
      patient_mobile_no: holder?.mobile ?? null,
      branch_id:         branchCode,
      technician_details: {
        // The external API's own technician ID (as a number); our ID only
        // for technicians it doesn't know (local-fallback logins).
        technician_id: _toIdNumber(technicianRef ?? initiator.technicianId),
        name:          _cleanTechnicianName(technicianName),
      },
      bookings,
    };

    writeLog(`[clientSync] sending — action=visit_completed bookings=${bookings.length} primary_booking_id=${primaryBookingId}`);

    const timeoutMs = parseInt(settings.get('client_sync_timeout_ms', '10000'), 10);
    const sentIds   = sent.map(s => s.bookingId);

    // Every attempt writes the exact payload sent and the exact response
    // received to logs/client_sync.log (secure_id masked). The same request
    // and response are stored in ip_asmx_logs (request_payload/response_payload).
    const _send = async (attempt) => {
      const shown = { ...payload, secure_id: payload.secure_id ? `${String(payload.secure_id).slice(0, 8)}…` : null };
      writeLog(`[clientSync] ▶ ${asmxEndpoint} REQUEST (${attempt}) booking_id=${primaryBookingId} timeout=${timeoutMs}ms — ${JSON.stringify(shown)}`);
      try {
        const r = await postAsmx(visitUrl, payload, timeoutMs, 'visitCompleteJson');
        writeLog(`[clientSync] ◀ ${asmxEndpoint} RESPONSE (${attempt}) http=${r.httpStatus} ${r.durationMs}ms — ${r.raw}`);
        return r;
      } catch (e) {
        writeLog(`[clientSync] ◀ ${asmxEndpoint} RESPONSE (${attempt}) ERROR http=${e.httpStatus ?? '-'} ${e.durationMs ?? '-'}ms — ${e.message}` +
          (e.raw != null ? ` — raw: ${e.raw}` : ''));
        throw e;
      }
    };
    // ip_asmx_logs.response_payload is a JSON column — an unreadable reply is
    // stored as { raw: "<text>" } so it is never lost.
    const _rawResponse = (e) => (e?.raw != null ? { raw: String(e.raw).slice(0, 20000) } : null);

    let httpStatus, result;
    try {
      ({ httpStatus, body: result } = await _send('attempt 1'));
    } catch (postErr) {
      _logRequestResponseBlock({ payload, tests: [], httpStatus: null, result: null });
      await _logVisit({ request: payload, response: _rawResponse(postErr), httpStatus: postErr.httpStatus ?? null,
        success: false, errorMessage: postErr.message });
      await _setSyncStatus(sentIds, 'failed');
      throw postErr;
    }

    _logRequestResponseBlock({ payload, tests: [], httpStatus, result });

    if (result && _isSignatureError(result)) {
      writeLog(`[clientSync] ⚠️  signature error (visit_completed) — refreshing secret and retrying`);
      const newSecret = await refreshSecret();
      payload.secure_id = buildSecureId(initiator.mobile, initiator.type, String(timestamp), newSecret);
      try {
        ({ httpStatus, body: result } = await _send('attempt 2 — after secret refresh'));
        _logRequestResponseBlock({ payload, tests: [], httpStatus, result });
      } catch (retryErr) {
        await _logVisit({ request: payload, response: _rawResponse(retryErr), httpStatus: retryErr.httpStatus ?? null,
          success: false, errorMessage: retryErr.message });
        await _setSyncStatus(sentIds, 'failed');
        return;
      }
    }

    // A single non-success object is the ASMX rejecting the whole request
    // (signature, validation, server error) — report its own message instead
    // of a misleading "result count 1 != N".
    if (result && !Array.isArray(result) && typeof result === 'object' && result.status !== 'success') {
      const why = `ASMX rejected the visit: ${result.msg ?? result.message ?? 'no message'}`;
      writeLog(`[clientSync] ❌ visit_completed ${why} — nothing saved, primary_booking_id=${primaryBookingId}`);
      await _logVisit({ request: payload, response: result, httpStatus, success: false, errorMessage: why });
      await _setSyncStatus(sentIds, 'failed');
      return;
    }

    // ── Per-booking results ────────────────────────────────────────────────
    // Family visit → a list, one result per booking, in bookings[] order.
    // Single booking → usually a plain object. Both are handled the same way.
    const items = Array.isArray(result) ? result
      : (result && typeof result === 'object') ? [result]
      : null;

    if (!items || items.length !== sent.length) {
      // Can't tell which result belongs to which booking — save nothing.
      const why = !items
        ? 'unrecognised response'
        : `ASMX returned ${items.length} result(s) for ${sent.length} booking(s)`;
      writeLog(`[clientSync] ❌ visit_completed ${why} — nothing saved, primary_booking_id=${primaryBookingId}`);
      await _logVisit({ request: payload, response: result ?? null, httpStatus, success: false, errorMessage: why });
      await _setSyncStatus(sentIds, 'failed');
      return;
    }

    const failures = [];
    for (let i = 0; i < sent.length; i++) {
      const s    = sent[i];
      const item = items[i] ?? {};
      const tag  = `booking ${i + 1}/${sent.length} (booking_id=${s.bookingId} ref=${s.bookingRef})`;

      if (item.status !== 'success') {
        const msg = item.msg ?? item.message ?? 'no message';
        failures.push(`${tag}: ${msg}`);
        writeLog(`[clientSync] ⚠️  ${tag} failed — ${msg}`);
        await _setSyncStatus([s.bookingId], 'failed');
        continue;
      }

      const billId = item.bill_id != null && String(item.bill_id).trim() !== '' ? String(item.bill_id) : null;
      await db.execute(
        `UPDATE ip_bookings SET client_sync_status = 'synced', reference_no = COALESCE(?, reference_no) WHERE booking_id = ?`,
        [billId, s.bookingId]
      );

      const returnedPatientId = item.patient_id != null && String(item.patient_id).trim() !== ''
        ? String(item.patient_id) : null;
      if (s.isNewPatient && returnedPatientId) {
        // New patient — link our patient to the ASMX patient ID, so the next
        // visit sends patient_id instead of patient_details.
        await db.execute(`UPDATE ip_patients SET patient_id_ref = ? WHERE patient_id = ?`, [returnedPatientId, s.patientId]);
        await db.execute(`UPDATE ip_bookings SET patient_id_ref = ? WHERE booking_id = ?`, [returnedPatientId, s.bookingId]);
      } else if (!s.isNewPatient && returnedPatientId && returnedPatientId !== s.sentPatientId) {
        // Existing patient but a different ID came back — never overwrite.
        writeLog(`[clientSync] ⚠️  ${tag} returned patient_id=${returnedPatientId} but sent ${s.sentPatientId} — not overwritten`);
      }

      writeLog(`[clientSync] ✅ ${tag} ${item.action ?? 'synced'} — bill_id=${billId ?? '-'} patient_id=${returnedPatientId ?? '-'}${s.isNewPatient ? ' (new patient linked)' : ''}`);
    }

    await _logVisit({
      request:      payload,
      response:     result,
      httpStatus,
      success:      failures.length === 0,
      errorMessage: failures.length ? failures.join(' | ') : null,
    });

    writeLog(`[clientSync] ${failures.length ? '⚠️ ' : '✅'} visit_completed — ${sent.length - failures.length}/${sent.length} booking(s) synced — primary_booking_id=${primaryBookingId}`);
  } catch (err) {
    writeLog(`[clientSync] ❌ ERROR — ${err.message}`);
    // Every visit sync leaves an ip_asmx_logs row, even when it fails before
    // or after the HTTP call (DB error while building the payload, etc.).
    if (!visitLogged) {
      await _logVisit({ request: null, response: null, httpStatus: null, success: false, errorMessage: err.message });
    }
  }
}

// ip_bookings.client_sync_status for a list of bookings. Never throws — a
// failure here (e.g. the column not accepting 'failed') is only logged.
async function _setSyncStatus(bookingIds, status) {
  if (!bookingIds || bookingIds.length === 0) return;
  try {
    await db.execute(
      `UPDATE ip_bookings SET client_sync_status = ? WHERE booking_id IN (${bookingIds.map(() => '?').join(',')})`,
      [status, ...bookingIds]
    );
  } catch (err) {
    writeLog(`[clientSync] ⚠️  could not set client_sync_status=${status} — ${err.code ?? err.message}`);
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