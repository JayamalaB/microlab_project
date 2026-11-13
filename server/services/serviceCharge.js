'use strict';
const db = require('../config/db');
const { serviceChargeForKm } = require('./fareCalculator');

// Home Collection service charge, decided when a technician accepts.
//
//   booking   no charge; ip_bookings.service_charge_status = 'pending'
//   accept    customer ↔ branch being offered, one way (served_distance_km),
//             up and down (× 2) → the ip_products row whose km range covers it.
//             Saved as 'calculated' (home_collection_fare,
//             service_charge_product_id, service_charge_km) — not in the total.
//             No product → 'no_product': no charge, the technician adds a
//             charge package.
//   arrival   added to total_amount / amount_due → 'applied'.
//   reassign  the next accept works it out again from the new branch; when it
//             was already applied, the difference goes into the total.
//
// One service charge per visit, carried by one booking — the main member
// (the one created with 'pending'); if that member is cancelled before it is
// applied, the next active member takes it over. Bookings with
// service_charge_status NULL were booked before this change and keep their
// booking-time fare: nothing here touches them.
//
// Every function returns a result object and never throws — a failure is
// returned as { skipped: reason }.

const MISSING_COLUMN = 'ER_BAD_FIELD_ERROR';
const ARRIVED_OR_LATER = [
  'arrived', 'collection_started', 'sample_collected', 'otp_verified', 'collected',
  'all_collected', 'handed_to_lab_pending', 'handed_to_lab', 'completed',
];
const round2 = (n) => Math.round(n * 100) / 100;
const num = (v) => (v == null || v === '' ? 0 : Number(v) || 0);

// Amount due and payment status for a new total. Nothing paid yet → the
// payment status stays as it was.
function totals(row, newTotal) {
  const paid = num(row.amount_paid);
  const amountDue = Math.max(0, round2(newTotal - paid));
  const paymentStatus = paid > 0 ? (amountDue <= 0 ? 'paid' : 'partial') : row.payment_status;
  return { amountDue, paymentStatus, overpaid: Math.max(0, round2(paid - newTotal)) };
}

async function _safely(label, bookingId, fn) {
  try {
    return await fn();
  } catch (err) {
    if (err.code === MISSING_COLUMN) return { skipped: 'service charge columns missing — run add_service_charge_on_accept.sql' };
    console.error(`❌ [serviceCharge] ${label} failed booking=${bookingId}: ${err.message}`);
    return { skipped: err.message };
  }
}

// Marks a new Home Collection booking as "service charge on the spot".
// conn: the booking's own transaction connection.
async function markPending(conn, bookingId) {
  return _safely('markPending', bookingId, async () => {
    await conn.execute(`UPDATE ip_bookings SET service_charge_status = 'pending' WHERE booking_id = ?`, [bookingId]);
    return { status: 'pending' };
  });
}

// The visit's bookings, oldest first.
async function _visitRows(bookingId) {
  const [rows] = await db.execute(
    `SELECT b.booking_id, b.status, b.service_charge_status, b.home_collection_fare,
            b.total_amount, b.amount_paid, b.payment_status
     FROM ip_bookings b
     JOIN ip_bookings p ON p.booking_id = ?
     WHERE b.deleted_at IS NULL
       AND (b.booking_id = p.booking_id
            OR (p.visit_group_id IS NOT NULL AND b.visit_group_id = p.visit_group_id))
     ORDER BY b.booking_id ASC`,
    [bookingId]
  );
  return rows ?? [];
}

// The booking that carries the visit's service charge, or null for a visit
// booked before this change. A cancelled carrier whose charge was not applied
// yet hands it over to the first active member.
async function _carrier(bookingId) {
  const rows = await _visitRows(bookingId);
  let carrier = rows.find(r => r.service_charge_status != null);
  if (!carrier) return null;
  if (carrier.status === 'cancelled' && carrier.service_charge_status !== 'applied') {
    const next = rows.find(r => r.status !== 'cancelled');
    if (next && next.booking_id !== carrier.booking_id) {
      await db.execute(
        `UPDATE ip_bookings
            SET service_charge_status = NULL, home_collection_fare = NULL,
                service_charge_product_id = NULL, service_charge_km = NULL
          WHERE booking_id = ?`,
        [carrier.booking_id]
      );
      await db.execute(`UPDATE ip_bookings SET service_charge_status = 'pending' WHERE booking_id = ?`, [next.booking_id]);
      carrier = { ...next, service_charge_status: 'pending', home_collection_fare: null };
    }
  }
  return carrier;
}

// A technician accepted (or an admin assigned one): works the charge out from
// servedDistanceKm (customer ↔ serving branch, one way).
async function calculateOnAccept(bookingId, { servedDistanceKm }) {
  return _safely('calculateOnAccept', bookingId, async () => {
    const carrier = await _carrier(bookingId);
    if (!carrier) return { skipped: 'booked before the service charge moved to accept — booking-time fare kept' };
    if (servedDistanceKm == null) return { skipped: 'customer ↔ branch distance unknown' };

    const km = round2(Number(servedDistanceKm));
    const sc = await serviceChargeForKm(km);
    const newStatus = sc.product ? 'calculated' : 'no_product';
    const result = {
      carrierId: carrier.booking_id, oneWayKm: km, roundTripKm: sc.roundTripKm,
      productName: sc.product?.product_name ?? null, price: sc.price,
    };

    if (carrier.service_charge_status === 'applied') {
      // Already in the bill (reassigned after arrival): the difference goes in.
      const oldFare  = num(carrier.home_collection_fare);
      const newFare  = sc.price ?? 0;
      const oldTotal = num(carrier.total_amount);
      const newTotal = round2(oldTotal - oldFare + newFare);
      const t = totals(carrier, newTotal);
      const [r] = await db.execute(
        `UPDATE ip_bookings
            SET home_collection_fare = ?, service_charge_product_id = ?, service_charge_km = ?,
                home_collection_distance_km = ?, service_charge_status = ?,
                total_amount = ?, amount_due = ?, payment_status = ?, updated_at = NOW()
          WHERE booking_id = ? AND service_charge_status = 'applied' AND total_amount = ?`,
        [sc.price, sc.product?.product_id ?? null, sc.roundTripKm, km, sc.product ? 'applied' : 'no_product',
         newTotal, t.amountDue, t.paymentStatus, carrier.booking_id, carrier.total_amount]
      );
      if (r.affectedRows !== 1) return { skipped: 'booking changed meanwhile — not recalculated' };
      return { ...result, status: sc.product ? 'applied' : 'no_product', difference: round2(newFare - oldFare),
        totalAmount: newTotal, amountDue: t.amountDue, overpaid: t.overpaid };
    }

    await db.execute(
      `UPDATE ip_bookings
          SET home_collection_fare = ?, service_charge_product_id = ?, service_charge_km = ?,
              home_collection_distance_km = ?, service_charge_status = ?, updated_at = NOW()
        WHERE booking_id = ?`,
      [sc.price, sc.product?.product_id ?? null, sc.roundTripKm, km, newStatus, carrier.booking_id]
    );
    return { ...result, status: newStatus };
  });
}

// The technician arrived: the calculated charge goes into the bill.
async function applyOnArrival(bookingId) {
  return _safely('applyOnArrival', bookingId, async () => {
    const carrier = await _carrier(bookingId);
    if (!carrier) return { skipped: 'booked before the service charge moved to accept' };
    if (carrier.service_charge_status !== 'calculated') return { skipped: `service charge is ${carrier.service_charge_status}` };

    const fare = num(carrier.home_collection_fare);
    const newTotal = round2(num(carrier.total_amount) + fare);
    const t = totals(carrier, newTotal);
    const [r] = await db.execute(
      `UPDATE ip_bookings
          SET total_amount = ?, amount_due = ?, payment_status = ?, service_charge_status = 'applied', updated_at = NOW()
        WHERE booking_id = ? AND service_charge_status = 'calculated' AND total_amount = ?`,
      [newTotal, t.amountDue, t.paymentStatus, carrier.booking_id, carrier.total_amount]
    );
    if (r.affectedRows !== 1) return { skipped: 'booking changed meanwhile — not applied' };
    return { status: 'applied', carrierId: carrier.booking_id, fare, totalAmount: newTotal, amountDue: t.amountDue };
  });
}

// Applies the charge when any booking of the visit is at arrival or later —
// a catch-up for screens that load after the arrival step.
async function applyIfArrived(bookingId) {
  return _safely('applyIfArrived', bookingId, async () => {
    const [[row]] = await db.execute(
      `SELECT 1 AS arrived
       FROM ip_technician_collection tc
       JOIN ip_bookings b ON b.booking_id = tc.booking_id
       JOIN ip_bookings p ON p.booking_id = ?
       WHERE (b.booking_id = p.booking_id
              OR (p.visit_group_id IS NOT NULL AND b.visit_group_id = p.visit_group_id))
         AND tc.collection_status IN (${ARRIVED_OR_LATER.map(() => '?').join(', ')})
       LIMIT 1`,
      [bookingId, ...ARRIVED_OR_LATER]
    );
    if (!row) return { skipped: 'technician has not arrived yet' };
    return applyOnArrival(bookingId);
  });
}

// What the apps show. The amount only once it is in the bill ('applied').
//   { status, productName, oneWayKm, roundTripKm, amount, carrierBookingId }
// status null = booked before this change (booking-time fare, shown as before).
async function view(bookingId) {
  return _safely('view', bookingId, async () => {
    const [rows] = await db.execute(
      `SELECT b.booking_id, b.service_charge_status, b.home_collection_fare, b.service_charge_km,
              b.home_collection_distance_km, p2.product_name
       FROM ip_bookings b
       JOIN ip_bookings p ON p.booking_id = ?
       LEFT JOIN ip_products p2 ON p2.product_id = b.service_charge_product_id
       WHERE b.deleted_at IS NULL AND b.service_charge_status IS NOT NULL
         AND (b.booking_id = p.booking_id
              OR (p.visit_group_id IS NOT NULL AND b.visit_group_id = p.visit_group_id))
       ORDER BY b.status = 'cancelled', b.booking_id ASC
       LIMIT 1`,
      [bookingId]
    );
    const r = rows?.[0];
    if (!r) return { status: null };
    const applied = r.service_charge_status === 'applied';
    return {
      status:           r.service_charge_status,
      carrierBookingId: r.booking_id,
      productName:      applied ? r.product_name ?? null : null,
      oneWayKm:         r.home_collection_distance_km != null ? Number(r.home_collection_distance_km) : null,
      roundTripKm:      r.service_charge_km != null ? Number(r.service_charge_km) : null,
      amount:           applied ? num(r.home_collection_fare) : null,
    };
  });
}

module.exports = {
  ARRIVED_OR_LATER, markPending, calculateOnAccept, applyOnArrival, applyIfArrived, view,
};
