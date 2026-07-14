const https  = require('https');
const http   = require('http');
const path   = require('path');
const fs     = require('fs');
const db     = require('../config/db');
const settings = require('../config/settings');

const LOG_FILE = path.join(__dirname, '..', 'logs', 'client_sync.log');

function writeLog(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false }).replace(',', '') + ' IST';
  const line = `[${ist}] ${msg}\n`;
  process.stdout.write(line);
  fs.appendFileSync(LOG_FILE, line, 'utf8');
}

function formatDate(d) {
  if (!d) return null;
  const date = new Date(d);
  const dd = String(date.getDate()).padStart(2, '0');
  const mm = String(date.getMonth() + 1).padStart(2, '0');
  const yy = String(date.getFullYear()).slice(2);
  return `${dd}-${mm}-${yy}`;
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
          try { resolve(JSON.parse(data)); }
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
 * @param {{ mobile: string, type: string }} initiator  — logged-in user
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

  writeLog(`[clientSync] starting — booking_id=${bookingId} initiator=${initiator.mobile} type=${initiator.type}`);

  try {
    // 1. Booking + slot time
    const [[booking]] = await db.execute(
      `SELECT b.booking_id, b.booking_ref, b.booking_type, b.booking_date,
              b.total_amount, b.patient_id,
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

    // 2. Patient
    const [[patient]] = await db.execute(
      `SELECT patient_id, patient_id_ref, patient_name, patient_mobile,
              patient_gender, patient_city, patient_address, patient_email,
              patient_dob, patient_age, patient_relation, health_conditions, patient_photo
       FROM ip_patients WHERE patient_id = ?`,
      [booking.patient_id]
    );
    if (!patient) {
      writeLog(`[clientSync] patient_id=${booking.patient_id} not found`);
      return;
    }

    // 3. Tests + prescription URLs
    const [tests] = await db.execute(
      `SELECT bi.booking_item_id, bi.product_id,
              COALESCE(bi.product_name_snapshot, p.product_name) AS name,
              bi.final_price                                      AS price,
              p.document_required,
              (SELECT bd.file_path
               FROM ip_booking_documents bd
               WHERE bd.booking_id = ?
                 AND bd.booking_item_id = bi.booking_item_id
                 AND bd.file_description = 'prescription'
               LIMIT 1) AS prescription_url
       FROM ip_booking_items bi
       LEFT JOIN ip_products p ON p.product_id = bi.product_id
       WHERE bi.booking_id = ?`,
      [bookingId, bookingId]
    );

    // 4. Payment
    const [[payment]] = await db.execute(
      `SELECT payment_type, amount_paid, amount_due, gateway_transaction_id
       FROM ip_payment_transactions
       WHERE booking_id = ? AND (is_refund = 0 OR is_refund IS NULL)
       ORDER BY created_at DESC LIMIT 1`,
      [bookingId]
    );

    // 5. Build payload
    const isNewPatient = !patient.patient_id_ref;

    const payload = {
      mobile_no:    initiator.mobile,
      user_type:    initiator.type,
      booking_ref:  booking.booking_ref,
      booking_type: booking.booking_type,
      slot_details: {
        date: formatDate(booking.booking_date),
        time: booking.slot_time ?? null,
      },
      blood_test_list: tests.map(t => {
        const docReq = t.document_required === 1 || t.document_required === '1' || t.document_required === 'yes';
        return {
          id:                t.product_id,
          name:              t.name,
          price:             t.price,
          document_required: docReq ? 'yes' : 'no',
          document:          t.prescription_url ?? 'no',
        };
      }),
      payment_details: {
        total_amount:        booking.total_amount,
        paid_amount:         payment?.amount_paid  ?? 0,
        payment_type:        payment?.payment_type === 'RAZORPAY' ? 'full payment' : 'pay_later',
        razorpay_payment_id: payment?.gateway_transaction_id ?? null,
      },
    };

    if (isNewPatient) {
      payload.patient_details = {
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
    } else {
      payload.patient_id = patient.patient_id_ref;
    }

    writeLog(`[clientSync] sending — new_patient=${isNewPatient} tests=${tests.length}`);

    // 6. POST to client server
    const timeoutMs = parseInt(settings.get('client_sync_timeout_ms', '10000'), 10);
    const result    = await postJson(clientUrl, payload, timeoutMs);

    writeLog(`[clientSync] response — ${JSON.stringify(result)}`);

    if (result.status === 'success') {
      if (result.bill_id) {
        await db.execute(
          `UPDATE ip_bookings SET bill_id = ? WHERE booking_id = ?`,
          [String(result.bill_id), bookingId]
        );
        writeLog(`[clientSync] ✅ bill_id=${result.bill_id} saved — booking_id=${bookingId}`);
      }
      if (isNewPatient && result.patient_id) {
        const ref = String(result.patient_id);
        // Update all three tables so no join is needed later
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
    } else {
      writeLog(`[clientSync] ⚠️  client server failure — ${result.msg ?? 'no message'}`);
    }
  } catch (err) {
    writeLog(`[clientSync] ❌ ERROR — ${err.message}`);
  }
}

module.exports = { syncBookingToClient };