// socket/bookingSocket.js
//
// Handles two booking domains on one socket server:
//   LAB       – technician visits patient to collect samples
//   TRANSPORT – driver picks up patient and drives to hospital
//
// Dispatch algorithm (lab and transport):
//   • Build sorted queue of nearest available actors (isOnline && isAvailable)
//   • Send to one actor at a time — up to MAX_ATTEMPTS silent retries per actor
//   • Active decline/reject → skip to next actor immediately
//   • Silent timeout       → retry same actor (up to MAX_ATTEMPTS); dismiss
//                            actor overlay after all attempts exhausted
//   • Queue exhausted      → extend with buildFullQueue (no size cap);
//                            emit booking_timeout if still nobody
//   • Race-condition guard → acceptedBookings Set blocks duplicate acceptances
//   • Newly-online inject  → on technician_online / driver_online, insert into
//                            active dispatch queues at correct sorted position
//                            (uncontacted slots only — current actor never displaced)
//   • Disconnect mid-job   → patient notified immediately via booking_cancelled

'use strict';
const db              = require('../config/db');
const { messaging }   = require('../config/firebase');
const { sendToBookingOwner } = require('../services/customerPush');
const fs              = require('fs');
const path            = require('path');

const COLLECTION_LOG = path.join(__dirname, '..', 'logs', 'collection.log');
function clog(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false }).replace(',', '') + ' IST';
  const line = `[${ist}] ${msg}\n`;
  process.stdout.write(line);
  fs.appendFileSync(COLLECTION_LOG, line, 'utf8');
}

const DISPATCH_LOG = path.join(__dirname, '..', 'logs', 'dispatch.log');
function dlog(msg) {
  const ist = new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', hour12: false }).replace(',', '') + ' IST';
  const line = `[${ist}] ${msg}\n`;
  process.stdout.write(line);
  fs.appendFileSync(DISPATCH_LOG, line, 'utf8');
}

// "06:30:00" → "6:30 AM"
function _fmtTimeLabel(timeStr) {
  const [h, m] = timeStr.split(':').map(Number);
  const period = h < 12 ? 'AM' : 'PM';
  const h12 = h % 12 || 12;
  return `${h12}:${String(m).padStart(2, '0')} ${period}`;
}

// Send FCM push to one device — fire-and-forget, never blocks dispatch.
async function sendFcmPush(fcmToken, bookingData) {
  if (!messaging || !fcmToken) return;
  try {
    // DATA-ONLY — no notification field so firebaseMessagingBackgroundHandler
    // fires (killed/backgrounded app) and shows our custom notification with
    // Accept + Decline buttons and the 40-second timeoutAfter.
    const msgId = await messaging.send({
      token: fcmToken,
      data: {
        type:           'booking_request',
        bookingId:      String(bookingData.bookingId      ?? ''),
        patientId:      String(bookingData.patientId      ?? ''),
        patientName:    String(bookingData.patientName    ?? ''),
        patientMobile:  String(bookingData.patientMobile  ?? ''),
        patientAddress: String(bookingData.patientAddress ?? ''),
        patientLat:     String(bookingData.patientLat     ?? ''),
        patientLng:     String(bookingData.patientLng     ?? ''),
        hospital:       String(bookingData.hospital       ?? ''),
        bookingType:    String(bookingData.bookingType    ?? 'lab'),
        branchId:       String(bookingData.branchId       ?? ''),
        branchName:     String(bookingData.branchName     ?? ''),
        slotId:          String(bookingData.slotId          ?? ''),
        slotLabel:       String(bookingData.slotLabel       ?? ''),
        appointmentTime: String(bookingData.appointmentTime ?? ''),
        createdAt:      String(bookingData.createdAt      ?? new Date().toISOString()),
      },
      android: {
        priority: 'high',
      },
    });
    console.log(`   ✅ [FCM] push sent  booking=${bookingData.bookingId} msgId=${msgId}`);
  } catch (e) {
    console.error(`   ❌ [FCM] push failed  booking=${bookingData.bookingId}: ${e.message}`);
  }
}

// ── Dispatch config ────────────────────────────────────────────────────────────
const MAX_DRIVERS   = 3;       // initial queue cap (nearest N actors)
const MAX_ATTEMPTS  = 3;       // silent-timeout retries before skipping an actor
const TIMEOUT_MS    = 40_000;  // 40 s per attempt
const RETRY_GAP_MS  = 3_000;   // 3 s gap before retrying the same actor

// ── In-memory actor maps ───────────────────────────────────────────────────────
// Entry shape: { socketId, lat, lng, name, sessionId?, isOnline, isAvailable }
const onlineTechnicians = new Map();
const onlineDrivers     = new Map();

// ── Booking state ──────────────────────────────────────────────────────────────
const patientSockets   = new Map(); // patientId  → socketId
const bookingRooms     = new Map(); // bookingId  → patientId
const dispatchQueues   = new Map(); // bookingId  → dispatch-state object
const lastTechLocation = new Map(); // trackingId → { ...data, _cachedAt }

// Captured on first socket connection; used by triggerScheduledDispatch
let _io = null;

// ── Race-condition protection ──────────────────────────────────────────────────
const acceptedBookings = new Set(); // bookingIds already accepted (blocks duplicates)

// ── Reconnect grace period ─────────────────────────────────────────────────────
// When a technician's socket disconnects (app killed / network drop), we null
// their socketId in onlineTechnicians for GRACE_MS so socket.io emits are
// skipped but FCM still fires.  After GRACE_MS with no reconnect, the in-memory
// entry is evicted.  DB online_status is NOT touched here — only a manual
// technician_offline event changes it (so the tech stays in the dispatch pool).
const graceTimers = new Map(); // technicianId → setTimeout handle
const GRACE_MS    = 45_000;    // 45 s — matches one full server dispatch attempt

// ── Lane 2 — FCM-reachable technician pool ─────────────────────────────────────
// Populated on technician_online; cleared ONLY on technician_offline or logout.
// Survives socket disconnects so techs stay reachable via FCM even when the app
// is killed.  DB online_status is the canonical source of truth.
const fcmOnlineTechnicians = new Map(); // technicianId → { fcmToken, lat, lng, name, branchId }

// ── Active-booking tracking (for disconnect cleanup) ───────────────────────────
const technicianActiveBookings = new Map(); // technicianId → bookingId
const driverActiveBookings     = new Map(); // driverId     → bookingId

// ═══════════════════════════════════════════════════════════════════════════════
//  LOGGING
// ═══════════════════════════════════════════════════════════════════════════════

function log(emoji, label, bookingId, details = '') {
  const ts = new Date().toISOString().slice(11, 23);
  console.log(
    `${ts} ${emoji}  [${String(label).padEnd(24)}] booking=${bookingId}` +
    (details ? ` | ${details}` : '')
  );
}

function logBlock(emoji, title, lines = []) {
  const ts  = new Date().toISOString().slice(11, 23);
  const bar = '═'.repeat(56);
  console.log(`\n${bar}`);
  console.log(`${ts} ${emoji}  ${title}`);
  if (lines.length > 0) {
    console.log('');
    lines.forEach(l => console.log(`   ${l}`));
  }
  console.log(`${bar}\n`);
}

// Fire-and-forget DB write — logs the table, action, params, and any errors
function dbRun(sql, params) {
  const action = sql.trim().slice(0, 6).toUpperCase();
  const tableMatch = sql.match(/(?:INTO|UPDATE|FROM)\s+`?(\w+)`?/i);
  const table = tableMatch ? tableMatch[1] : '?';
  console.log(`   💾 [DB] ${action} ${table} | values: ${JSON.stringify(params)}`);
  db.execute(sql, params)
    .then(() => console.log(`   ✅ [DB] ${action} ${table} — OK`))
    .catch(e  => console.error(`   ❌ [DB] ${action} ${table} FAILED: ${e.message} | params: ${JSON.stringify(params)}`));
}

// Haversine great-circle distance (km)
function haversine(lat1, lon1, lat2, lon2) {
  const R = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * Math.PI / 180) *
    Math.cos(lat2 * Math.PI / 180) *
    Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// Notify patient via room broadcast + direct-socket fallback
function _notifyPatient(io, bookingId, event, payload) {
  io.to(String(bookingId)).emit(event, payload);
  const patientId = bookingRooms.get(bookingId);
  if (patientId) {
    const sid = patientSockets.get(patientId);
    if (sid) io.to(sid).emit(event, payload);
  }
}

// Return a technician to the available pool after a job completes
function _freeTechnician(technicianId, bookingId) {
  const t = onlineTechnicians.get(technicianId);
  if (t) onlineTechnicians.set(technicianId, { ...t, isAvailable: true });
  acceptedBookings.delete(bookingId);
  technicianActiveBookings.delete(technicianId);
  dbRun(
    `UPDATE ip_technician_live_location
     SET booking_id   = NULL,
         task_status  = 'idle',
         online_status= 'online',
         updated_at   = NOW()
     WHERE technician_id = ?`,
    [technicianId]
  );
}

// Cascade a technician-collection status to all sibling bookings sharing the
// same visit_group_id. No-op when visit_group_id IS NULL (normal bookings).
async function _cascadeTcStatus(bookingId, status, timestampCol) {
  try {
    const [[row]] = await db.execute(
      'SELECT visit_group_id FROM ip_bookings WHERE booking_id = ? LIMIT 1',
      [bookingId]
    );
    if (!row?.visit_group_id) return;
    const vgId = row.visit_group_id;
    dbRun(
      `UPDATE ip_technician_collection tc
       JOIN ip_bookings b ON b.booking_id = tc.booking_id
       SET tc.collection_status = ?, tc.${timestampCol} = NOW(), tc.updated_at = NOW()
       WHERE b.visit_group_id = ? AND b.booking_id != ? AND b.deleted_at IS NULL`,
      [status, vgId, bookingId]
    );
  } catch (e) {
    console.error(`❌ [_cascadeTcStatus] booking=${bookingId} status=${status}: ${e.message}`);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  QUEUE BUILDERS
// ═══════════════════════════════════════════════════════════════════════════════

function _sortedAvailableActors(patientLat, patientLng, actorMap, branchId = null) {
  const withGps = [];
  const noGps   = [];

  actorMap.forEach((actor, id) => {
    if (!actor.isOnline || !actor.isAvailable) return;
    if (branchId != null && actor.branchId != null && actor.branchId !== branchId) return;

    if (
      actor.lat  != null && actor.lng  != null &&
      patientLat != null && patientLng != null
    ) {
      withGps.push({
        id, ...actor,
        dist: haversine(patientLat, patientLng, actor.lat, actor.lng),
      });
    } else {
      noGps.push({ id, ...actor, dist: Infinity });
    }
  });

  withGps.sort((a, b) => a.dist - b.dist);
  return [...withGps, ...noGps];
}

function buildQueue(patientLat, patientLng, actorMap, branchId = null) {
  return _sortedAvailableActors(patientLat, patientLng, actorMap, branchId)
    .slice(0, MAX_DRIVERS);
}

function buildFullQueue(patientLat, patientLng, actorMap, branchId = null) {
  return _sortedAvailableActors(patientLat, patientLng, actorMap, branchId);
}

// Build a dispatch queue from Lane 2 (FCM-only techs that went online but whose
// socket later died without a technician_offline).  Excludes techs already tracked
// in onlineTechnicians (Lane 1 handles them via FCM when socketId is null).
function buildFcmQueue(patientLat, patientLng, branchId = null) {
  const entries = [];
  fcmOnlineTechnicians.forEach((tech, id) => {
    if (onlineTechnicians.has(id)) return; // Lane 1 already covers them
    if (branchId != null && tech.branchId != null && tech.branchId !== branchId) return;
    const dist =
      tech.lat != null && patientLat != null
        ? haversine(patientLat, patientLng, tech.lat, tech.lng)
        : Infinity;
    entries.push({ id, ...tech, socketId: null, isOnline: true, isAvailable: true, dist });
  });
  entries.sort((a, b) => a.dist - b.dist);
  return entries;
}

// Temporarily register Lane 2 techs into onlineTechnicians so dispatchAttempt can
// find and track them.  Their real entry replaces this when they reconnect.
function _registerFcmTechs(fcmQueue) {
  for (const tech of fcmQueue) {
    if (!onlineTechnicians.has(tech.id)) {
      onlineTechnicians.set(tech.id, {
        socketId:    null,
        fcmToken:    tech.fcmToken ?? null,
        lat:         tech.lat     ?? null,
        lng:         tech.lng     ?? null,
        name:        tech.name,
        sessionId:   null,
        branchId:    tech.branchId ?? null,
        isOnline:    true,
        isAvailable: true,
      });
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  CORE DISPATCH
// ═══════════════════════════════════════════════════════════════════════════════

// Returns a compact queue snapshot — used inside every logBlock so each log
// entry is self-contained and readable without cross-referencing earlier lines.
function _queueStatus(dispatch, actorMap) {
  const q   = dispatch.queue;
  const idx = dispatch.techIdx;
  const remaining = Math.max(0, q.length - idx);
  const lines = [
    `Queue Status : ${q.length} total  |  tried: ${dispatch.triedIds.size}  |  remaining: ${remaining}`,
  ];
  q.forEach((a, i) => {
    const marker = i < idx ? '✓' : i === idx ? '▶' : '○';
    const dist   = a.dist === Infinity ? 'no GPS' : `${a.dist.toFixed(1)} km`;
    const live   = actorMap.get(a.id);
    const state  = !live
      ? 'offline'
      : !live.isOnline
        ? 'went offline'
        : !live.isAvailable
          ? 'busy'
          : 'available';
    lines.push(`  ${marker} ${i + 1}. ${a.name} (ID: ${a.id})  ${dist}  [${state}]`);
  });
  return lines;
}

async function dispatchAttempt(io, bookingId) {
  while (true) {
    if (!bookingRooms.has(bookingId)) return; // patient cancelled
    const dispatch = dispatchQueues.get(bookingId);
    if (!dispatch) return;

    const { queue, bookingData, bookingType = 'lab' } = dispatch;
    const actorMap = bookingType === 'transport' ? onlineDrivers : onlineTechnicians;

    if (dispatch.techIdx >= queue.length) {
      // Use the persistent triedIds set — tracks techs that were actually dispatched to,
      // not just queued. This prevents re-dispatching skipped techs and is immune to
      // queue mutations (inject, expansion pushes) that would corrupt a recomputed set.
      const triedIds = dispatch.triedIds;

      // Build expansion pool; apply slot hard-filter when this is a slot booking.
      let fresh = buildFullQueue(
        bookingData.patientLat ?? null,
        bookingData.patientLng ?? null,
        actorMap,
        bookingData.branchId   ?? null
      ).filter(a => !triedIds.has(a.id));

      if (dispatch.slotTechIds && dispatch.slotTechIds.size > 0) {
        fresh = fresh.filter(a => dispatch.slotTechIds.has(a.id));
      }

      if (fresh.length > 0) {
        dispatch.queue.push(...fresh);
        logBlock('🔄', `Queue Expanded  booking=${bookingId}`,
          fresh.map((a, i) =>
            `+${i + 1}. ${a.name} (ID: ${a.id}) — ${
              a.dist === Infinity ? 'no GPS' : `${a.dist.toFixed(1)} km`
            }`
          )
        );
      } else {
        // Lane 2: FCM-online techs (socket dead but DB-online — never sent technician_offline)
        if (bookingType !== 'transport') {
          let fcmQueue = buildFcmQueue(
            bookingData.patientLat ?? null,
            bookingData.patientLng ?? null,
            bookingData.branchId   ?? null
          ).filter(a => !triedIds.has(a.id));

          if (dispatch.slotTechIds && dispatch.slotTechIds.size > 0) {
            fcmQueue = fcmQueue.filter(a => dispatch.slotTechIds.has(a.id));
          }

          if (fcmQueue.length > 0) {
            _registerFcmTechs(fcmQueue);
            dispatch.queue.push(...fcmQueue);
            logBlock('📡', `Lane 2 FCM Expansion  booking=${bookingId}`,
              fcmQueue.map((a, i) =>
                `+${i + 1}. ${a.name} (ID: ${a.id}) — FCM-only (socket disconnected)`
              )
            );
            continue; // restart loop: queue now has entries, dispatch next tech
          }
        }

        // Lane 2.5: slot-matched techs fully exhausted — lift the slot constraint
        // and try any available technician so the booking doesn't silently time out
        // when a non-slot tech could still reach the patient.
        if (dispatch.slotTechIds && dispatch.slotTechIds.size > 0) {
          let fallbackFresh = buildFullQueue(
            bookingData.patientLat ?? null,
            bookingData.patientLng ?? null,
            actorMap,
            bookingData.branchId   ?? null
          ).filter(a => !triedIds.has(a.id)); // no slotTechIds filter

          if (fallbackFresh.length === 0 && bookingType !== 'transport') {
            // Also check FCM-only techs without slot constraint
            const fallbackFcm = buildFcmQueue(
              bookingData.patientLat ?? null,
              bookingData.patientLng ?? null,
              bookingData.branchId   ?? null
            ).filter(a => !triedIds.has(a.id));
            if (fallbackFcm.length > 0) {
              _registerFcmTechs(fallbackFcm);
              fallbackFresh = fallbackFcm;
            }
          }

          if (fallbackFresh.length > 0) {
            dispatch.slotTechIds = null; // lift constraint for remaining dispatch
            dispatch.queue.push(...fallbackFresh);
            dlog(`[DISPATCH] SLOT_FALLBACK — bookingId=${bookingId} slot techs exhausted, lifting constraint — ${fallbackFresh.length} any-available tech(s) added`);
            logBlock('🔓', `Slot Fallback  booking=${bookingId}`, [
              'All slot-matched techs exhausted — lifting slot constraint.',
              ...fallbackFresh.map((a, i) =>
                `+${i + 1}. ${a.name} (ID: ${a.id}) — ${
                  a.dist === Infinity ? 'no GPS' : `${a.dist.toFixed(1)} km`
                }`
              ),
            ]);
            continue; // restart loop: dispatch next available tech
          }
        }

        // All slot-matched techs exhausted → tell patient to choose another slot.
        // Generic exhaustion → booking_timeout.
        dlog(`[DISPATCH] ALL TECHS EXHAUSTED — bookingId=${bookingId} triedIds=[${[...dispatch.triedIds].join(',')}] slotId=${dispatch.slotId ?? 'none'}`);
        dispatchQueues.delete(bookingId);
        if (dispatch.slotId != null) {
          dlog(`[DISPATCH] SLOT_EXHAUSTED — bookingId=${bookingId} slot=${dispatch.slotId} — emitting slot_no_availability to patient`);
          await _notifySlotNoAvailability(
            io, bookingId, dispatch.slotId, bookingData.branchId, dispatch.bookingDate, dispatch.appointmentTime
          );
          // Keep bookingRooms alive so the patient can re-select a slot and re-dispatch.
          log('🕐', 'SLOT_EXHAUSTED', bookingId,
            `slot=${dispatch.slotId} — all matched techs rejected/timed out → slot_no_availability sent`);
        } else {
          dlog(`[DISPATCH] BOOKING_TIMEOUT — bookingId=${bookingId} no techs responded — emitting booking_timeout to patient`);
          _notifyPatient(io, bookingId, 'booking_timeout', { bookingId });
          bookingRooms.delete(bookingId);
          logBlock('⏰', `Booking Timeout  booking=${bookingId}`, [
            'All available actors exhausted — no one responded.',
            'Patient notified.',
          ]);
        }
        if (bookingType !== 'transport') {
          dbRun(
            `UPDATE ip_booking_requests
             SET request_status = 'expired'
             WHERE booking_id = ? AND request_status = 'pending'`,
            [bookingId]
          );
        }
        return;
      }
    }

    const actor  = dispatch.queue[dispatch.techIdx];
    const online = actorMap.get(actor.id);

    if (!online || !online.isOnline || !online.isAvailable) {
      const why = !online ? 'disconnected' : !online.isOnline ? 'went offline' : 'busy';
      dispatch.techIdx++;
      dispatch.attemptNum = 1;
      const nextAfterSkip = dispatch.queue[dispatch.techIdx];
      log('⚠️', 'ACTOR_SKIPPED', bookingId,
        `${actor.name} (ID: ${actor.id}) [${why}] skipped → next: ${
          nextAfterSkip ? `${nextAfterSkip.name} (ID: ${nextAfterSkip.id})` : 'none — expanding queue'
        }`);
      continue;
    }

    // Record this tech as attempted before sending — persisted across expansions.
    dispatch.triedIds.add(actor.id);

    // Socket.IO — only when the tech has an active connection.
    // Skipped for offline/FCM-only dispatch entries (socketId is null).
    if (online.socketId) {
      io.to(online.socketId).emit('booking_request', bookingData);
      dlog(`[DISPATCH] socket sent — bookingId=${bookingId} techId=${actor.id} techName=${actor.name} socketId=${online.socketId} attempt=${dispatch.attemptNum}/${MAX_ATTEMPTS}`);
    } else {
      dlog(`[DISPATCH] socket skipped (no socketId) — bookingId=${bookingId} techId=${actor.id} techName=${actor.name} → FCM only attempt=${dispatch.attemptNum}/${MAX_ATTEMPTS}`);
    }

    // FCM push — delivers even when the tech is offline / app is killed.
    sendFcmPush(online.fcmToken, bookingData);
    dlog(`[DISPATCH] FCM push sent — bookingId=${bookingId} techId=${actor.id} techName=${actor.name} fcmToken=${online.fcmToken ? online.fcmToken.slice(0, 20) + '...' : 'NULL'}`);

    const distLabel   = actor.dist === Infinity ? 'no GPS' : `${actor.dist.toFixed(1)} km`;
    const nextInQueue = dispatch.queue[dispatch.techIdx + 1] ?? null;
    const nextLabel   = nextInQueue
      ? `${nextInQueue.name} (ID: ${nextInQueue.id})  ${nextInQueue.dist === Infinity ? 'no GPS' : nextInQueue.dist.toFixed(1) + ' km'}`
      : 'none — queue will expand on exhaustion';

    logBlock('📤', `Dispatch Attempt  booking=${bookingId}`, [
      `▶ Current  : ${actor.name} (ID: ${actor.id})  ${distLabel}`,
      `  Attempt  : ${dispatch.attemptNum} / ${MAX_ATTEMPTS}  (${TIMEOUT_MS / 1000}s timeout each)`,
      `  Channel  : ${online.socketId ? 'Socket.IO + FCM' : 'FCM only (no active socket)'}`,
      '',
      `⬇ Next     : ${nextLabel}`,
      '',
      ..._queueStatus(dispatch, actorMap),
    ]);

    if (bookingType !== 'transport') {
      dbRun(
        `INSERT INTO ip_booking_requests
           (booking_id, technician_id, technician_name, request_status,
            total_attempts, max_attempts, last_sent_at)
         VALUES (?, ?, ?, 'pending', 1, ?, NOW())
         ON DUPLICATE KEY UPDATE
           technician_id   = VALUES(technician_id),
           technician_name = VALUES(technician_name),
           request_status  = 'pending',
           total_attempts  = IF(technician_id = VALUES(technician_id), total_attempts + 1, 1),
           max_attempts    = VALUES(max_attempts),
           last_sent_at    = NOW(),
           updated_at      = NOW()`,
        [bookingId, actor.id, actor.name || '', MAX_ATTEMPTS]
      );
    }

    dispatch.handle = setTimeout(() => {
      dispatch.handle = null;

      if (dispatch.attemptNum < MAX_ATTEMPTS) {
        dispatch.attemptNum++;
        dlog(`[DISPATCH] TIMEOUT_RETRY — bookingId=${bookingId} techId=${actor.id} techName=${actor.name} retry=${dispatch.attemptNum}/${MAX_ATTEMPTS} gap=${RETRY_GAP_MS}ms`);
        log('🔁', 'TECH_TIMEOUT_RETRY', bookingId,
          `tech=${actor.name} retry=${dispatch.attemptNum}/${MAX_ATTEMPTS} ` +
          `gap=${RETRY_GAP_MS}ms`
        );
        dispatch.handle = setTimeout(() => dispatchAttempt(io, bookingId), RETRY_GAP_MS);
      } else {
        dlog(`[DISPATCH] TIMEOUT_EXHAUSTED — bookingId=${bookingId} techId=${actor.id} techName=${actor.name} all ${MAX_ATTEMPTS} attempts failed → moving to next tech`);
        const actorEntry = actorMap.get(actor.id);
        if (actorEntry?.socketId) {
          io.to(actorEntry.socketId).emit('booking_cancelled', { bookingId });
          log('📢', 'OVERLAY_DISMISSED', bookingId,
            `tech=${actor.name} — overlay cleared after ${MAX_ATTEMPTS} timeouts`);
        } else if (actorEntry && !actorEntry.socketId) {
          // Temporary FCM-only entry — remove it so future dispatches are not confused.
          actorMap.delete(actor.id);
          log('🧹', 'FCM_TEMP_CLEANED', bookingId,
            `tech=${actor.name} — FCM-only entry removed after ${MAX_ATTEMPTS} timeouts`);
        }

        dispatch.techIdx++;
        dispatch.attemptNum = 1;
        const nextAfterTimeout = dispatch.queue[dispatch.techIdx];
        dlog(`[DISPATCH] TIMEOUT_MOVE — bookingId=${bookingId} techId=${actor.id} techName=${actor.name} all ${MAX_ATTEMPTS} attempts exhausted → next: ${nextAfterTimeout ? `${nextAfterTimeout.name}(id=${nextAfterTimeout.id})` : 'queue exhausted — expanding'}`);
        log('⏭️', 'TECH_TIMEOUT_SKIP', bookingId,
          `${actor.name} exhausted ${MAX_ATTEMPTS}×${TIMEOUT_MS / 1000}s → next: ${
            nextAfterTimeout ? `${nextAfterTimeout.name} (ID: ${nextAfterTimeout.id})` : 'expanding queue'
          }`);
        dispatchAttempt(io, bookingId);
      }
    }, TIMEOUT_MS);

    break;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SLOT-BASED FALLBACK ASSIGNMENT
//  Used when no technician is online in real-time.
//  Looks up ip_technician_slots for the booking's branch + collection date,
//  auto-confirms the booking, and notifies the patient immediately.
// ═══════════════════════════════════════════════════════════════════════════════

async function _trySlotBasedAssign(io, socket, { bookingId, branchId, patientId, patientAddress, patientLat, patientLng, bookingData, slotId, appointmentTime }) {
  try {
    // Get collection date from the booking record
    const [[booking]] = await db.execute(
      'SELECT booking_date FROM ip_bookings WHERE booking_id = ?',
      [bookingId]
    );
    if (!booking) return false;

    const raw            = booking.booking_date;
    const collectionDate = raw
      ? (raw instanceof Date ? raw.toISOString() : String(raw)).split('T')[0]
      : new Date().toISOString().split('T')[0];

    // Build query — filter by patient's chosen slotId when provided.
    const slotFilter = slotId != null ? 'AND ts.slot_id = ?' : '';
    const slotParams = slotId != null ? [branchId, collectionDate, slotId] : [branchId, collectionDate];

    const [slotRows] = await db.execute(
      `SELECT ts.technician_id, u.user_name
       FROM ip_technician_slots ts
       JOIN ip_technicians t ON t.technician_id = ts.technician_id
       JOIN ip_users u       ON u.user_id        = t.user_id
       WHERE ts.branch_id    = ?
         AND ts.slot_date    = ?
         AND ts.is_available = 1
         AND ts.booked_count < ts.max_bookings
         ${slotFilter}
       ORDER BY ts.booked_count ASC`,
      slotParams
    );

    if (slotRows.length === 0) {
      log('⚠️', 'SLOT_FALLBACK_MISS', bookingId,
        `no slot entry for branch=${branchId} date=${collectionDate} slot=${slotId ?? 'any'}`);
      if (slotId != null) {
        // Patient chose a specific slot — no tech available for it.
        // Notify with available alternates; caller must NOT emit booking_timeout.
        await _notifySlotNoAvailability(io, bookingId, slotId, branchId, collectionDate, appointmentTime);
        return true; // handled — caller skips its own event emit
      }
      return false;
    }

    const techId   = slotRows[0].technician_id;
    const techName = slotRows[0].user_name;
    // All eligible slot techs — used as slotTechIds so expansion can route to any of them.
    const allSlotTechIds = slotId != null
      ? new Set(slotRows.map(r => r.technician_id))
      : null;

    // ── If the slot technician is currently online and available, use the normal
    //    dispatch flow — send them a booking_request and wait for their acceptance.
    //    Only auto-confirm when they are OFFLINE (pre-assigned scheduled booking).
    const onlineTech = onlineTechnicians.get(techId);
    if (onlineTech?.isOnline && onlineTech?.isAvailable && onlineTech?.socketId) {
      const dist =
        patientLat != null && onlineTech.lat != null
          ? haversine(patientLat, patientLng, onlineTech.lat, onlineTech.lng)
          : Infinity;

      dispatchQueues.set(bookingId, {
        bookingData,
        queue: [{
          id:          techId,
          socketId:    onlineTech.socketId,
          lat:         onlineTech.lat,
          lng:         onlineTech.lng,
          name:        techName,
          isOnline:    true,
          isAvailable: true,
          dist,
        }],
        techIdx:      0,
        attemptNum:   1,
        handle:       null,
        triedIds:     new Set(),
        bookingType:     'lab',
        slotId:          slotId ?? null,
        slotTechIds:     allSlotTechIds,
        bookingDate:     collectionDate,
        appointmentTime: appointmentTime ?? null,
      });

      dispatchAttempt(io, bookingId);

      logBlock('📤', `Slot→Dispatch  booking=${bookingId}`, [
        `Technician : ${techName} (ID: ${techId})`,
        `Date       : ${collectionDate}  Branch : ${branchId}`,
        `Slot       : ${slotId ?? 'any'}`,
        `Status     : ONLINE — dispatching normally (waiting for acceptance)`,
      ]);

      return true;
    }

    // ── Technician is offline — send FCM booking request and wait for their response.
    //    Auto-confirm only as a last resort when no FCM token exists in the DB.
    const [[techLoc]] = await db.execute(
      'SELECT fcm_token FROM ip_technician_live_location WHERE technician_id = ?',
      [techId]
    );
    const fcmToken = techLoc?.fcm_token ?? null;

    if (fcmToken) {
      // Register a temporary onlineTechnicians entry with socketId: null so
      // dispatchAttempt can find the tech and track retries.  The real entry
      // will replace this one when the tech's app opens and emits technician_online.
      onlineTechnicians.set(techId, {
        socketId:    null,
        fcmToken,
        lat:         null,
        lng:         null,
        name:        techName,
        sessionId:   null,
        branchId:    branchId ?? null,
        isOnline:    true,
        isAvailable: true,
      });

      // slotInfo is carried through so booking_accepted can increment booked_count.
      dispatchQueues.set(bookingId, {
        bookingData,
        queue: [{
          id:          techId,
          socketId:    null,
          fcmToken,
          lat:         null,
          lng:         null,
          name:        techName,
          isOnline:    true,
          isAvailable: true,
          dist:        Infinity,
        }],
        techIdx:      0,
        attemptNum:   1,
        handle:       null,
        triedIds:     new Set(),
        bookingType:     'lab',
        slotInfo:        { techId, collectionDate, branchId },
        slotId:          slotId ?? null,
        slotTechIds:     allSlotTechIds,
        bookingDate:     collectionDate,
        appointmentTime: appointmentTime ?? null,
      });

      dispatchAttempt(io, bookingId);

      logBlock('📲', `Slot→FCM Dispatch  booking=${bookingId}`, [
        `Technician : ${techName} (ID: ${techId})`,
        `Date       : ${collectionDate}  Branch : ${branchId}`,
        `Status     : OFFLINE — FCM request sent, waiting ${TIMEOUT_MS / 1000}s for response`,
      ]);

      return true;
    }

    // No FCM token — cannot dispatch.  Return false so the caller can emit booking_timeout.
    log('⚠️', 'SLOT_NO_FCM_TOKEN', bookingId,
      `tech=${techName} id=${techId} offline, no FCM token — cannot dispatch for date=${collectionDate}`);
    return false;
  } catch (e) {
    console.error('[_trySlotBasedAssign]', e.message);
    return false;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SLOT NO-AVAILABILITY NOTIFIER
//  Queries alternate available slots for the same branch + date, then emits
//  slot_no_availability to the patient so they can re-select and re-dispatch.
//  bookingRooms entry is intentionally kept alive for the re-dispatch cycle.
// ═══════════════════════════════════════════════════════════════════════════════

async function _notifySlotNoAvailability(io, bookingId, failedSlotId, branchId, collectionDate, appointmentTime = null) {
  let alternateSlots = [];
  let timeIntervals  = [];
  try {
    // When appointmentTime set, return other available times in the same slot first
    if (appointmentTime && failedSlotId != null) {
      const [timeRows] = await db.execute(
        `SELECT DISTINCT ias.slot_time
         FROM ip_available_slots ias
         JOIN ip_technician_slots ts ON ts.tech_slot_id = ias.technician_slot_id
         WHERE ts.branch_id     = ?
           AND ts.slot_id       = ?
           AND ts.slot_date     = ?
           AND ias.is_available = 1
           AND ias.slot_time   != ?
         ORDER BY ias.slot_time ASC`,
        [branchId, failedSlotId, collectionDate, `${appointmentTime}:00`]
      );
      timeIntervals = timeRows.map(r => ({
        time:  r.slot_time.slice(0, 5),
        label: _fmtTimeLabel(r.slot_time),
      }));
    }

    const [rows] = await db.execute(
      `SELECT DISTINCT s.slot_id, s.slot_label
       FROM ip_technician_slots ts
       JOIN ip_slots s ON s.slot_id = ts.slot_id
       WHERE ts.branch_id    = ?
         AND ts.slot_date    = ?
         AND ts.is_available = 1
         AND ts.booked_count < ts.max_bookings
         AND s.slot_active   = 1
         AND ts.slot_id     != ?
       ORDER BY s.slot_start ASC`,
      [branchId, collectionDate, failedSlotId]
    );
    alternateSlots = rows.map(r => ({ slotId: r.slot_id, label: r.slot_label }));
  } catch (e) {
    log('⚠️', 'SLOT_AVAIL_QUERY_ERR', bookingId, e.message);
  }

  _notifyPatient(io, bookingId, 'slot_no_availability', {
    bookingId,
    message: timeIntervals.length > 0
      ? 'No technicians available for this time. Choose another time or slot.'
      : 'No technicians are available for your selected time slot. Please choose another available slot.',
    timeIntervals,
    slots: alternateSlots,
  });

  log('📢', 'SLOT_NO_AVAILABILITY', bookingId,
    `branch=${branchId} date=${collectionDate} failedSlot=${failedSlotId} ` +
    `time=${appointmentTime ?? 'none'} — ${timeIntervals.length} alt-times, ${alternateSlots.length} alt-slots`);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  CORE DISPATCH LOGIC  (called by socket handler + cron scheduler)
// ═══════════════════════════════════════════════════════════════════════════════

async function _handleBookingRequest(io, socket, data = {}) {
  const {
    bookingId, patientId, patientName,
    patientMobile = '', patientAddress = '',
    patientLat, patientLng, hospital,
    bookingType     = 'lab',
    branchId        = null,
    branchName      = null,
    slotId          = null,
    slotLabel       = null,
    appointmentTime = null, // "HH:MM" — exact time within slot
  } = data;

  dlog(`[DISPATCH] ── booking_request received ── bookingId=${bookingId} patientId=${patientId} patientName=${patientName} branchId=${branchId} slotId=${slotId ?? 'none'} appointmentTime=${appointmentTime ?? 'none'} bookingType=${bookingType}`);

  if (!bookingId || !patientId) {
    dlog(`[DISPATCH] GUARD FAILED — missing bookingId or patientId | bookingId=${bookingId} patientId=${patientId}`);
    console.warn('booking_request: missing bookingId or patientId',
      { bookingId, patientId });
    return;
  }

  // Safety gate: future-date bookings must go through the cron scheduler,
  // not real-time socket dispatch. Catch old app versions that emit early.
  const [[bRowDate]] = await db.execute(
    'SELECT booking_date FROM ip_bookings WHERE booking_id = ? LIMIT 1',
    [bookingId]
  );
  if (bRowDate?.booking_date) {
    const bDate    = (bRowDate.booking_date instanceof Date
      ? bRowDate.booking_date.toISOString()
      : String(bRowDate.booking_date)).split('T')[0];
    const todayIST = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
    if (bDate > todayIST) {
      dlog(`[DISPATCH] DEFERRED — bookingId=${bookingId} booking_date=${bDate} is future (today=${todayIST}) — waiting for cron scheduler`);
      log('📅', 'SCHEDULED_DEFER', bookingId,
        `booking_date=${bDate} is future — dispatch deferred to cron`);
      socket.emit('booking_scheduled', { bookingId });
      return;
    }
  }

  dlog(`[DISPATCH] booking_date check passed — proceeding with live dispatch for bookingId=${bookingId}`);
  socket.patientId = patientId;
  // Virtual sockets (cron/admin dispatch) must not overwrite a real patient socket ID.
  if (!socket.isVirtual) {
    patientSockets.set(patientId, socket.id);
  }
  bookingRooms.set(bookingId, patientId);

  if (dispatchQueues.has(bookingId)) {
    log('⚠️', 'DUPLICATE_REQUEST', bookingId,
      `patient=${patientId} — dispatch already running`);
    return;
  }

  const actorMap    = bookingType === 'transport' ? onlineDrivers : onlineTechnicians;
  const totalOnline = actorMap.size;
  const available   = [...actorMap.values()].filter(a => a.isAvailable).length;

  if (bookingType !== 'transport') {
    dbRun(
      `INSERT INTO ip_patient_tracking_metadata
         (booking_id, patient_id, latitude, longitude, source, created_at, updated_at)
       VALUES (?, ?, ?, ?, 'socket', NOW(), NOW())
       ON DUPLICATE KEY UPDATE
         latitude   = VALUES(latitude),
         longitude  = VALUES(longitude),
         updated_at = NOW()`,
      [bookingId, patientId, patientLat ?? null, patientLng ?? null]
    );
  }

  // Build the full booking payload now — needed by both normal dispatch
  // and the slot-based fallback (which sends the complete data to the tech).
  const bookingData = {
    bookingId, patientId, patientName, patientMobile,
    patientAddress, patientLat, patientLng, hospital, bookingType,
    branchId, branchName,
    ...(slotId          != null && { slotId }),
    ...(slotLabel       != null && { slotLabel }),
    ...(appointmentTime != null && { appointmentTime }),
    createdAt: new Date().toISOString(),
  };

  const slotCtx = { bookingId, branchId, patientId, patientAddress, patientLat, patientLng, bookingData, slotId, appointmentTime };

  if (actorMap.size === 0) {
    // Lane 2: try FCM-online techs (socket dead, DB-online, technician_offline not sent)
    if (bookingType !== 'transport') {
      const fcmQueue = buildFcmQueue(patientLat, patientLng, branchId);
      if (fcmQueue.length > 0) {
        _registerFcmTechs(fcmQueue); // injects into actorMap (onlineTechnicians)
        log('📡', 'LANE2_INJECT', bookingId,
          `no socket-online techs — injected ${fcmQueue.length} FCM-only tech(s) into dispatch`);
        // Fall through — actorMap now has entries; buildQueue below will find them
      } else {
        // Lane 3: slot-based scheduled tech
        log('⚠️', 'NO_ACTORS_ONLINE', bookingId, `trying slot-based fallback branch=${branchId}`);
        const assigned = await _trySlotBasedAssign(io, socket, slotCtx);
        if (!assigned) {
          socket.emit('booking_timeout', { bookingId });
          log('⏰', 'BOOKING_TIMEOUT', bookingId, 'no actors online & no slot match');
        }
        return;
      }
    } else {
      // Transport has no FCM or slot fallback
      socket.emit('booking_timeout', { bookingId });
      log('⏰', 'BOOKING_TIMEOUT', bookingId, 'no drivers online');
      return;
    }
  }

  // Priority 1: technicians matching the booking's branch.
  // Priority 2: any available technician (branch mismatch is better than no one).
  // Priority 3: slot-based fallback (tech offline / all busy).
  let queue = buildQueue(patientLat, patientLng, actorMap, branchId);

  if (queue.length === 0 && branchId != null) {
    const anyBranchQueue = buildQueue(patientLat, patientLng, actorMap, null);
    if (anyBranchQueue.length > 0) {
      queue = anyBranchQueue;
      log('⚠️', 'BRANCH_FALLBACK', bookingId,
        `no available tech for branch=${branchId} — using nearest from any branch (${queue.length} found)`);
    }
  }

  if (queue.length === 0) {
    // Lane 2: all socket-online techs are busy — try FCM-online pool
    if (bookingType !== 'transport') {
      const fcmQueue = buildFcmQueue(patientLat, patientLng, null); // no branch filter
      if (fcmQueue.length > 0) {
        _registerFcmTechs(fcmQueue);
        queue = buildQueue(patientLat, patientLng, actorMap, null);
        log('📡', 'LANE2_INJECT', bookingId,
          `all socket techs busy — injected ${fcmQueue.length} FCM-only tech(s)`);
      }
    }
    if (queue.length === 0) {
      // Lane 3: slot-based scheduled tech
      log('⚠️', 'ALL_ACTORS_BUSY', bookingId, `trying slot-based fallback branch=${branchId}`);
      const assigned = await _trySlotBasedAssign(io, socket, slotCtx);
      if (!assigned) {
        socket.emit('booking_timeout', { bookingId });
        log('⏰', 'BOOKING_TIMEOUT', bookingId, 'all actors busy & no slot match');
      }
      return;
    }
  }

  // ── Slot hard-filter ──────────────────────────────────────────────────────
  // When the patient picked a specific slot, restrict dispatch to ONLY techs
  // who declared that slot for the booking date.  Non-slot techs are excluded
  // entirely — they will never receive this request even if closer.
  let slotTechIds   = null; // Set<technicianId> | null
  let bookingDate   = null; // 'YYYY-MM-DD' | null

  if (slotId != null && bookingType !== 'transport') {
    try {
      // Resolve booking date from the DB record (patient chose a future date).
      const [[brow]] = await db.execute(
        'SELECT booking_date FROM ip_bookings WHERE booking_id = ?',
        [bookingId]
      );
      if (brow) {
        const rawDate = brow.booking_date;
        bookingDate   = rawDate
          ? (rawDate instanceof Date ? rawDate.toISOString() : String(rawDate)).split('T')[0]
          : new Date().toISOString().split('T')[0];
      } else {
        bookingDate = new Date().toISOString().split('T')[0];
      }

      const [techRows] = await db.execute(
        `SELECT technician_id FROM ip_technician_slots
         WHERE slot_id      = ?
           AND slot_date    = ?
           AND is_available = 1
           AND booked_count < max_bookings`,
        [slotId, bookingDate]
      );

      slotTechIds = new Set(techRows.map(r => r.technician_id));

      // When the patient chose a specific appointment time, further restrict to
      // techs who still have that exact time available in ip_available_slots.
      if (appointmentTime && slotTechIds.size > 0) {
        const [availRows] = await db.execute(
          `SELECT DISTINCT ts.technician_id
           FROM ip_available_slots ias
           JOIN ip_technician_slots ts ON ts.tech_slot_id = ias.technician_slot_id
           WHERE ts.slot_id      = ?
             AND ts.slot_date   = ?
             AND ias.slot_time  = ?
             AND ias.is_available = 1`,
          [slotId, bookingDate, `${appointmentTime}:00`]
        );
        const timeTechIds = new Set(availRows.map(r => r.technician_id));
        slotTechIds = new Set([...slotTechIds].filter(id => timeTechIds.has(id)));
        log('🕐', 'APPT_TIME_FILTER', bookingId,
          `time=${appointmentTime} → ${slotTechIds.size} tech(s) have this time available`);
      }

      if (slotTechIds.size === 0) {
        // No slot config for this booking date — fall back to any available branch tech
        // rather than failing immediately (handles case where ip_technician_slots has no
        // entries for the chosen date yet).
        log('⚠️', 'SLOT_ZERO_TECHS', bookingId,
          `slot=${slotId} date=${bookingDate} time=${appointmentTime ?? 'any'} — no slot config found, dispatching to any available branch tech`);
        slotTechIds = null; // disable hard-filter below
      }

      if (slotTechIds !== null) {
        // Hard-filter: keep only slot-matched techs in the queue.
        const before = queue.length;
        queue = queue.filter(a => slotTechIds.has(a.id));
        log('🕐', 'SLOT_FILTER', bookingId,
          `slot=${slotId} (${slotLabel ?? '?'}) date=${bookingDate} — ${queue.length}/${before} techs match`);

        // If all online slot-matched techs are already in the queue but NONE are
        // currently available (busy), fall through to Lane 2 / Lane 3.
        if (queue.length === 0) {
          // Lane 2 FCM-only techs with this slot
          let fcmSlotQueue = buildFcmQueue(patientLat, patientLng, branchId)
            .filter(a => slotTechIds.has(a.id));
          if (fcmSlotQueue.length > 0) {
            _registerFcmTechs(fcmSlotQueue);
            queue = buildQueue(patientLat, patientLng, actorMap, branchId)
              .filter(a => slotTechIds.has(a.id));
            log('📡', 'SLOT_LANE2_INJECT', bookingId,
              `injected ${fcmSlotQueue.length} FCM-only slot-matched tech(s)`);
          }
          if (queue.length === 0) {
            // Lane 3 — offline tech with this slot
            log('⚠️', 'SLOT_ALL_BUSY', bookingId,
              `all slot-matched techs busy — trying Lane 3`);
            const assigned = await _trySlotBasedAssign(io, socket, slotCtx);
            if (!assigned) {
              // _trySlotBasedAssign found nothing and didn't emit; we notify here.
              await _notifySlotNoAvailability(io, bookingId, slotId, branchId, bookingDate, appointmentTime);
            }
            // If assigned=true, _trySlotBasedAssign already set dispatchQueues — don't touch it.
            return;
          }
        }
      }
    } catch (err) {
      log('⚠️', 'SLOT_FILTER_ERR', bookingId, err.message);
      // On DB error fall through with unfiltered queue so dispatch isn't blocked.
      slotTechIds = null;
    }
  }

  logBlock('📋', `Booking Created  #${bookingId}`, [
    `Patient    : ${patientName} (ID: ${patientId})`,
    `Type       : ${bookingType}`,
    `Branch     : ${branchId ?? 'unassigned'}`,
    `Slot       : ${slotId != null ? `${slotId} (${slotLabel ?? '?'}) date=${bookingDate} time=${appointmentTime ?? 'any'}` : 'none (no slot filter)'}`,
    `Location   : ${
      patientLat != null
        ? `${Number(patientLat).toFixed(4)}, ${Number(patientLng).toFixed(4)}`
        : 'unknown'
    }`,
    '',
    'Dispatch Queue (slot-filtered, sorted by distance):',
    ...queue.map((a, i) =>
      `  ${i + 1}. ${a.name} (ID: ${a.id}) — ${
        a.dist === Infinity ? 'no GPS' : `${a.dist.toFixed(1)} km`
      }`
    ),
    '',
    `Online: ${totalOnline}   Available: ${available}   Queued: ${queue.length}`,
  ]);

  dlog(`[DISPATCH] queue built — bookingId=${bookingId} totalOnline=${totalOnline} available=${available} queued=${queue.length} techs=[${queue.map(t => `${t.name}(id=${t.id} dist=${t.dist === Infinity ? 'noGPS' : t.dist.toFixed(1) + 'km'})`).join(', ')}]`);

  dispatchQueues.set(bookingId, {
    bookingData,
    queue,
    techIdx:         0,
    attemptNum:      1,
    handle:          null,
    triedIds:        new Set(),
    bookingType,
    slotId:          slotId ?? null,
    slotTechIds:     slotTechIds,
    bookingDate:     bookingDate,
    appointmentTime: appointmentTime ?? null,
  });

  dispatchAttempt(io, bookingId);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOCKET EVENT HANDLERS
// ═══════════════════════════════════════════════════════════════════════════════

module.exports = function bookingSocket(io, socket) {
  _io = io; // capture for triggerScheduledDispatch

  // ════════════════════════════════════════════════════════════════════════════
  //  LAB — Technician events
  // ════════════════════════════════════════════════════════════════════════════

  socket.on('technician_online', (data = {}) => {
    const { technicianId, technicianName, sessionId, lat, lng, branchId, fcmToken } = data;
    if (!technicianId) {
      console.warn('technician_online: missing technicianId');
      return;
    }

    // Cancel the grace-period offline timer if the tech reconnects in time.
    const pendingGrace = graceTimers.get(technicianId);
    if (pendingGrace) {
      clearTimeout(pendingGrace);
      graceTimers.delete(technicianId);
      log('✅', 'GRACE_CANCELLED', '-',
        `tech=${technicianName} (ID: ${technicianId}) reconnected within ${GRACE_MS / 1000}s`);
    }

    socket.technicianId   = technicianId;
    socket.technicianName = technicianName;

    onlineTechnicians.set(technicianId, {
      socketId:    socket.id,
      lat:         lat       ?? null,
      lng:         lng       ?? null,
      name:        technicianName,
      sessionId:   sessionId ?? null,
      branchId:    branchId  ?? null,
      fcmToken:    fcmToken  ?? null,
      isOnline:    true,
      isAvailable: true,
    });

    // Lane 2 pool — survives socket disconnects; cleared only on technician_offline.
    fcmOnlineTechnicians.set(technicianId, {
      fcmToken: fcmToken  ?? null,
      lat:      lat       ?? null,
      lng:      lng       ?? null,
      name:     technicianName,
      branchId: branchId  ?? null,
    });

    // Persist FCM token so it survives server restarts (next dispatchAttempt reads from Map).
    if (fcmToken) {
      dbRun(
        `UPDATE ip_technician_live_location SET fcm_token = ? WHERE technician_id = ?`,
        [fcmToken, technicianId]
      );
    }

    dbRun(
      `INSERT INTO ip_technician_live_location
         (technician_id, socket_id, session_id, latitude, longitude,
          online_status, task_status, last_ping_at, updated_at)
       VALUES (?, ?, ?, ?, ?, 'online', 'idle', NOW(), NOW())
       ON DUPLICATE KEY UPDATE
         socket_id     = VALUES(socket_id),
         session_id    = VALUES(session_id),
         latitude      = VALUES(latitude),
         longitude     = VALUES(longitude),
         online_status = 'online',
         task_status   = 'idle',
         booking_id    = NULL,
         last_ping_at  = NOW(),
         updated_at    = NOW()`,
      [technicianId, socket.id, sessionId ?? null, lat ?? null, lng ?? null]
    );

    logBlock('🟢', `Technician Online`, [
      `Technician : ${technicianName} (ID: ${technicianId})`,
      `Branch     : ${branchId ?? 'unassigned'}`,
      `GPS        : ${lat != null ? `${lat.toFixed(5)}, ${lng.toFixed(5)}` : 'no GPS'}`,
      `Socket     : ${socket.id}`,
    ]);

    db.execute(
      `INSERT INTO ip_technician_sessions
         (technician_id, total_pings, total_bookings_assigned,
          total_bookings_completed, started_at, created_at, updated_at)
       VALUES (?, 0, 0, 0, NOW(), NOW(), NOW())`,
      [technicianId]
    ).then(([result]) => {
      const newSessionId = result.insertId;
      const t = onlineTechnicians.get(technicianId);
      if (t) onlineTechnicians.set(technicianId, { ...t, sessionId: newSessionId });
      dbRun(
        `UPDATE ip_technician_live_location
         SET session_id = ?, updated_at = NOW()
         WHERE technician_id = ?`,
        [newSessionId, technicianId]
      );
      socket.emit('session_started', { sessionId: newSessionId });
      log('📋', 'SESSION_CREATED', '-',
        `tech=${technicianName} (ID: ${technicianId}) session=${newSessionId}`);
    }).catch(e =>
      console.error(`❌ [SESSION INSERT FAILED] tech=${technicianId}: ${e.message}`)
    );

    dispatchQueues.forEach((dispatch, bookingId) => {
      if (dispatch.bookingType !== 'lab') return;
      const bookingBranchId = dispatch.bookingData.branchId ?? null;
      if (bookingBranchId != null && branchId != null && bookingBranchId !== branchId) return;

      const existingIdx = dispatch.queue.findIndex(q => q.id === technicianId);
      if (existingIdx !== -1) {
        const prev = dispatch.queue[existingIdx];
        dispatch.queue[existingIdx] = {
          ...prev,
          socketId: socket.id,
          lat: lat ?? prev.lat,
          lng: lng ?? prev.lng,
        };
        log('🔄', 'QUEUE_ENTRY_REFRESHED', bookingId,
          `tech=${technicianName} (ID: ${technicianId}) socketId+GPS updated`);
        return;
      }

      // Slot-aware guard: if this booking is slot-filtered, only inject techs who
      // declared that slot. A tech from the right branch but wrong slot must not
      // receive this booking request.
      if (dispatch.slotTechIds != null && !dispatch.slotTechIds.has(technicianId)) {
        log('🚫', 'INJECT_SLOT_MISMATCH', bookingId,
          `tech=${technicianName} (ID: ${technicianId}) — not in slot set, skipping inject`);
        return;
      }

      const { patientLat, patientLng } = dispatch.bookingData;
      const dist =
        lat != null && patientLat != null
          ? haversine(patientLat, patientLng, lat, lng)
          : Infinity;

      const futureStart = dispatch.techIdx + 1;
      let insertAt = dispatch.queue.length;
      for (let i = futureStart; i < dispatch.queue.length; i++) {
        if (dist < (dispatch.queue[i].dist ?? Infinity)) { insertAt = i; break; }
      }

      dispatch.queue.splice(insertAt, 0, {
        id: technicianId, socketId: socket.id,
        lat: lat ?? null, lng: lng ?? null,
        name: technicianName,
        isOnline: true, isAvailable: true,
        dist,
      });

      logBlock('🆕', `Queue Injection  booking=${bookingId}`, [
        `Technician : ${technicianName} (ID: ${technicianId})`,
        `Distance   : ${dist === Infinity ? 'no GPS' : `${dist.toFixed(1)} km`}`,
        `Slot       : #${insertAt + 1} of ${dispatch.queue.length}`,
      ]);
    });
  });

  // Heartbeat sent every 20 s by the client while online.
  // Cancels any grace timer (tech is alive), refreshes socketId + GPS, updates last_ping_at.
  socket.on('technician_heartbeat', (data = {}) => {
    const { technicianId, lat, lng } = data;
    if (!technicianId) return;

    const t = onlineTechnicians.get(technicianId);
    if (t) {
      onlineTechnicians.set(technicianId, {
        ...t,
        socketId: socket.id,        // refresh in case this is a reconnected socket
        lat:      lat ?? t.lat,
        lng:      lng ?? t.lng,
      });
    }

    // If a grace timer is running (e.g. brief reconnect race), cancel it.
    const timer = graceTimers.get(technicianId);
    if (timer) {
      clearTimeout(timer);
      graceTimers.delete(technicianId);
      log('💓', 'HEARTBEAT_GRACE_CANCEL', '-', `tech id=${technicianId} — grace cleared`);
    }

    dbRun(
      `UPDATE ip_technician_live_location
       SET last_ping_at = NOW(), updated_at = NOW()
       WHERE technician_id = ?`,
      [technicianId]
    );
  });

  socket.on('technician_offline', (data = {}) => {
    const { technicianId } = data;
    if (!technicianId) return;

    onlineTechnicians.delete(technicianId);
    fcmOnlineTechnicians.delete(technicianId);

    // Explicit offline supersedes any grace period.
    const pendingGrace = graceTimers.get(technicianId);
    if (pendingGrace) { clearTimeout(pendingGrace); graceTimers.delete(technicianId); }

    dbRun(
      `UPDATE ip_technician_live_location
       SET online_status = 'offline',
           socket_id     = NULL,
           booking_id    = NULL,
           task_status   = 'idle',
           updated_at    = NOW()
       WHERE technician_id = ?`,
      [technicianId]
    );

    log('🔴', 'TECH_OFFLINE', '-', `id=${technicianId}`);
  });

  socket.on('update_technician_location', (data = {}) => {
    const {
      technicianId, lat, lng,
      accuracy, speed, bearing, batteryLevel, networkType,
    } = data;
    if (!technicianId || lat == null || lng == null) return;

    const t = onlineTechnicians.get(technicianId);
    if (t) onlineTechnicians.set(technicianId, { ...t, lat, lng });

    dbRun(
      `UPDATE ip_technician_live_location
       SET latitude        = ?,
           longitude       = ?,
           accuracy_meters = ?,
           speed_kmph      = ?,
           bearing_degrees = ?,
           battery_level   = ?,
           network_type    = ?,
           last_ping_at    = NOW(),
           updated_at      = NOW()
       WHERE technician_id = ?`,
      [lat, lng, accuracy ?? null, speed ?? null, bearing ?? null,
       batteryLevel ?? null, networkType ?? null, technicianId]
    );
  });

  // ── Accept (technician OR driver) ───────────────────────────────────────────
  socket.on('booking_accepted', (data = {}) => {
    const {
      bookingId, technicianId, technicianName,
      driverId,  driverName,  sessionId,
    } = data;

    dlog(`[DISPATCH] booking_accepted received — bookingId=${bookingId} technicianId=${technicianId} technicianName=${technicianName} driverId=${driverId ?? 'none'}`);

    if (!bookingId) { console.warn('booking_accepted: missing bookingId'); return; }

    if (acceptedBookings.has(bookingId)) {
      const who = driverName ?? technicianName ??
                  String(driverId ?? technicianId ?? '?');
      dlog(`[DISPATCH] DUPLICATE_BLOCKED — bookingId=${bookingId} actor=${who} booking already claimed`);
      log('🚫', 'DUPLICATE_BLOCKED', bookingId,
        `actor=${who} — booking already claimed by another`);
      return;
    }
    acceptedBookings.add(bookingId);

    const actorId   = driverId   ?? technicianId;
    const actorName = driverName ?? technicianName ?? '';
    if (!actorId) {
      log('⚠️', 'ACCEPT_NO_ACTOR_ID', bookingId);
      acceptedBookings.delete(bookingId);
      return;
    }

    const dispatch        = dispatchQueues.get(bookingId);
    const queuedActors    = dispatch?.queue          ?? [];
    if (dispatch?.handle) clearTimeout(dispatch.handle);
    const bookingType     = dispatch?.bookingType    ?? 'lab';
    const slotInfo        = dispatch?.slotInfo       ?? null;
    const bookingDate     = dispatch?.bookingDate    ?? null;
    const appointmentTime = dispatch?.appointmentTime ?? null;
    dispatchQueues.delete(bookingId);

    const actorMap   = bookingType === 'transport' ? onlineDrivers : onlineTechnicians;
    const actorEntry = actorMap.get(actorId);
    if (actorEntry) {
      actorMap.set(actorId, { ...actorEntry, isAvailable: false });
    }

    if (bookingType === 'transport') {
      driverActiveBookings.set(actorId, bookingId);
    } else {
      technicianActiveBookings.set(actorId, bookingId);
    }

    logBlock('✅', `Booking Assigned  booking=${bookingId}`, [
      `Technician : ${actorName} (ID: ${actorId})`,
      `Type       : ${bookingType}`,
      `Dispatch   : Stopped`,
      `Queue      : Cleared`,
    ]);

    if (bookingType !== 'transport') {
      dbRun(
        `UPDATE ip_booking_requests
         SET request_status = 'accepted',
             responded_at   = NOW(),
             updated_at     = NOW()
         WHERE booking_id = ? AND technician_id = ? AND request_status = 'pending'`,
        [bookingId, actorId]
      );

      const bd = dispatch?.bookingData ?? {};
      db.execute(
        `INSERT INTO ip_technician_collection
           (booking_id, technician_id, technician_name, collection_status, collection_date,
            collection_address, collection_latitude, collection_longitude,
            patient_id, slot_id, assigned_at, created_at, updated_at)
         VALUES (?, ?, ?, 'assigned', CURDATE(), ?, ?, ?, ?, ?, NOW(), NOW(), NOW())
         ON DUPLICATE KEY UPDATE
           technician_id     = VALUES(technician_id),
           technician_name   = VALUES(technician_name),
           collection_status = 'assigned',
           assigned_at       = NOW(),
           updated_at        = NOW()`,
        [bookingId, actorId, actorName || null,
         bd.patientAddress ?? null, bd.patientLat ?? null, bd.patientLng ?? null,
         bd.patientId ? Number(bd.patientId) : null,
         bd.slotId   ? Number(bd.slotId)   : null]
      ).then(([r]) => {
        log('💾', 'TCB_CREATED', bookingId,
          `tech=${actorName} rows=${r.affectedRows}`);
        // Cascade assignment to sibling bookings in the same visit group
        ;(async () => {
          try {
            const [[parentRow]] = await db.execute(
              'SELECT visit_group_id FROM ip_bookings WHERE booking_id = ? LIMIT 1',
              [bookingId]
            );
            if (!parentRow?.visit_group_id) return;
            const vgId = parentRow.visit_group_id;
            await db.execute(
              `INSERT INTO ip_technician_collection
                 (booking_id, technician_id, technician_name, collection_status, collection_date,
                  collection_address, collection_latitude, collection_longitude,
                  patient_id, slot_id, assigned_at, created_at, updated_at)
               SELECT b.booking_id, ?, ?, 'assigned', CURDATE(), ?, ?, ?, pb.patient_id, ?, NOW(), NOW(), NOW()
               FROM ip_bookings b
               LEFT JOIN ip_patient_bookings pb ON pb.booking_id = b.booking_id
               WHERE b.visit_group_id = ? AND b.booking_id != ? AND b.deleted_at IS NULL
               ON DUPLICATE KEY UPDATE
                 technician_id     = VALUES(technician_id),
                 technician_name   = VALUES(technician_name),
                 collection_status = 'assigned',
                 assigned_at       = NOW(),
                 updated_at        = NOW()`,
              [actorId, actorName || null,
               bd.patientAddress ?? null, bd.patientLat ?? null, bd.patientLng ?? null,
               bd.slotId ? Number(bd.slotId) : null,
               vgId, bookingId]
            );
            dbRun(
              `UPDATE ip_bookings
               SET technician_id = ?, technician_name = ?, updated_at = NOW()
               WHERE visit_group_id = ? AND booking_id != ? AND deleted_at IS NULL`,
              [actorId, actorName || null, vgId, bookingId]
            );
            log('💾', 'TCB_SIBLING_CASCADE', bookingId,
              `visit_group=${vgId} tech=${actorName}`);
          } catch (e) {
            console.error(`❌ [TCB SIBLING CASCADE FAILED] booking=${bookingId}: ${e.message}`);
          }
        })();
      }).catch(e => {
        console.error(
          `❌ [TCB INSERT FAILED] booking=${bookingId} tech=${actorId}: ${e.message}`
        );
      });

      dbRun(
        `UPDATE ip_bookings
         SET status = 'assigned', technician_id = ?, technician_name = ?, updated_at = NOW()
         WHERE booking_id = ?`,
        [actorId, actorName || null, bookingId]
      );

      dbRun(
        `UPDATE ip_technician_live_location
         SET booking_id    = ?,
             task_status   = 'assigned',
             online_status = 'busy',
             updated_at    = NOW()
         WHERE technician_id = ?`,
        [bookingId, actorId]
      );

      const tech = onlineTechnicians.get(actorId);
      if (tech?.sessionId) {
        dbRun(
          `UPDATE ip_technician_sessions
           SET total_bookings_assigned = total_bookings_assigned + 1,
               updated_at              = NOW()
           WHERE session_id = ?`,
          [tech.sessionId]
        );
      }

      // If this acceptance came from a slot-based FCM dispatch, increment the
      // slot's booked_count (normally done in the auto-confirm path).
      if (slotInfo && slotInfo.techId === actorId) {
        dbRun(
          `UPDATE ip_technician_slots
           SET booked_count = booked_count + 1
           WHERE technician_id = ? AND slot_date = ? AND branch_id = ?`,
          [slotInfo.techId, slotInfo.collectionDate, slotInfo.branchId]
        );
      }

      // Mark the exact appointment time as taken so no other booking can claim it.
      if (appointmentTime && bookingDate) {
        dbRun(
          `UPDATE ip_available_slots ias
           JOIN ip_technician_slots ts ON ts.tech_slot_id = ias.technician_slot_id
           SET ias.is_available = 0, ias.updated_at = NOW()
           WHERE ts.technician_id  = ?
             AND ts.slot_date      = ?
             AND ias.slot_time     = ?
             AND ias.is_available  = 1
           LIMIT 1`,
          [actorId, bookingDate, `${appointmentTime}:00`]
        );
        log('💾', 'APPT_SLOT_MARKED', bookingId,
          `tech=${actorId} date=${bookingDate} time=${appointmentTime} → is_available=0`);
      }
    }

    _notifyPatient(io, bookingId, 'booking_accepted', {
      bookingId,
      technicianId: actorId, technicianName: actorName,
      driverId:     actorId, driverName:     actorName,
      trackingId:   String(bookingId),
    });

    dlog(`[DISPATCH] ACCEPTED — bookingId=${bookingId} techId=${actorId} techName=${actorName} | dispatch stopped | patient notified | other techs cancelled`);
    log('👤', 'PATIENT_NOTIFIED', bookingId, 'booking_accepted sent');

    sendToBookingOwner(
      bookingId,
      'Technician Assigned 🧑‍⚕️',
      `${actorName} has been assigned to your booking. They will be on their way soon.`,
      { type: 'technician_assigned', booking_id: String(bookingId) }
    );

    queuedActors.forEach(qa => {
      if (qa.id === actorId) return;
      const entry = actorMap.get(qa.id);
      if (entry?.socketId) {
        io.to(entry.socketId).emit('booking_cancelled', { bookingId });
        dlog(`[DISPATCH] booking_cancelled sent to techId=${qa.id} techName=${qa.name} (not the acceptor)`);
      }
    });
  });

  // ── Technician rejects (active decline) ─────────────────────────────────────
  socket.on('booking_rejected', (data = {}) => {
    const { bookingId, technicianId } = data;
    dlog(`[DISPATCH] booking_rejected received — bookingId=${bookingId} techId=${technicianId} → moving to next tech`);
    if (!bookingId || !technicianId) return;

    dbRun(
      `UPDATE ip_booking_requests
       SET request_status = 'rejected',
           responded_at   = NOW(),
           updated_at     = NOW()
       WHERE booking_id = ? AND technician_id = ?`,
      [bookingId, technicianId]
    );

    const dispatch = dispatchQueues.get(bookingId);
    if (dispatch) {
      if (dispatch.handle) { clearTimeout(dispatch.handle); dispatch.handle = null; }
      const rejectedName = dispatch.queue[dispatch.techIdx]?.name ?? `ID: ${technicianId}`;
      dispatch.techIdx++;
      dispatch.attemptNum = 1;
      const nextAfterReject = dispatch.queue[dispatch.techIdx];
      dlog(`[DISPATCH] REJECTED_MOVE — bookingId=${bookingId} techId=${technicianId} techName=${rejectedName} actively declined → next: ${nextAfterReject ? `${nextAfterReject.name}(id=${nextAfterReject.id})` : 'queue exhausted — expanding'}`);
      log('❌', 'TECH_REJECTED', bookingId,
        `${rejectedName} (ID: ${technicianId}) declined → next: ${
          nextAfterReject ? `${nextAfterReject.name} (ID: ${nextAfterReject.id})` : 'expanding queue'
        }`);
      dispatchAttempt(io, bookingId);
    }
  });

  // ── Journey milestones (lab) ─────────────────────────────────────────────────

  socket.on('technician_en_route', (data = {}) => {
    const { bookingId, technicianId } = data;
    if (!bookingId || !technicianId) return;
    log('🚴', 'TECH_EN_ROUTE', bookingId, `tech_id=${technicianId}`);
    dbRun(
      `UPDATE ip_technician_collection
       SET collection_status = 'en_route', en_route_at = NOW(), updated_at = NOW()
       WHERE booking_id = ?`,
      [bookingId]
    );
    _cascadeTcStatus(bookingId, 'en_route', 'en_route_at');
    dbRun(
      `UPDATE ip_technician_live_location
       SET task_status = 'en_route', updated_at = NOW()
       WHERE technician_id = ?`,
      [technicianId]
    );
    _notifyPatient(io, bookingId, 'technician_en_route', { bookingId });
    sendToBookingOwner(
      bookingId,
      'Technician On the Way 🚴',
      'Your technician is on the way to your location.',
      { type: 'technician_en_route', booking_id: String(bookingId) }
    );
  });

  socket.on('technician_arrived', (data = {}) => {
    const { bookingId, technicianId } = data;
    if (!bookingId || !technicianId) return;
    log('📍', 'TECH_ARRIVED', bookingId, `tech_id=${technicianId}`);
    dbRun(
      `UPDATE ip_technician_collection
       SET collection_status = 'arrived', arrived_at = NOW(), updated_at = NOW()
       WHERE booking_id = ?`,
      [bookingId]
    );
    _cascadeTcStatus(bookingId, 'arrived', 'arrived_at');
    dbRun(
      `UPDATE ip_technician_live_location
       SET task_status = 'arrived', updated_at = NOW()
       WHERE technician_id = ?`,
      [technicianId]
    );
    _notifyPatient(io, bookingId, 'technician_arrived', { bookingId });
    sendToBookingOwner(
      bookingId,
      'Technician Arrived 📍',
      'Your technician has arrived at your location.',
      { type: 'technician_arrived', booking_id: String(bookingId) }
    );
  });

  socket.on('collection_completed', (data = {}) => {
    const { bookingId, technicianId } = data;
    if (!bookingId || !technicianId) return;

    log('🏁', 'BOOKING_COMPLETED', bookingId, `tech_id=${technicianId}`);

    _freeTechnician(technicianId, bookingId);

    dbRun(
      `UPDATE ip_technician_collection
       SET collection_status = 'all_collected', collected_at = NOW(), updated_at = NOW()
       WHERE booking_id = ?`,
      [bookingId]
    );
    _cascadeTcStatus(bookingId, 'all_collected', 'collected_at');
    dbRun(
      `UPDATE ip_bookings
       SET status = 'collected', updated_at = NOW()
       WHERE booking_id = ?`,
      [bookingId]
    );

    const tech = onlineTechnicians.get(technicianId);
    if (tech?.sessionId) {
      dbRun(
        `UPDATE ip_technician_sessions
         SET total_bookings_completed = total_bookings_completed + 1,
             updated_at               = NOW()
         WHERE session_id = ?`,
        [tech.sessionId]
      );
    }

    _notifyPatient(io, bookingId, 'collection_completed', { bookingId });
    bookingRooms.delete(bookingId);
    lastTechLocation.delete(String(bookingId));
  });

  // ── New 7-step technician flow ───────────────────────────────────────────────

  socket.on('collection_started', (data = {}) => {
    clog(`[collection_started] RAW event received | data=${JSON.stringify(data)}`);
    const { bookingId, technicianId } = data;
    clog(`[collection_started] parsed bookingId=${bookingId} (type=${typeof bookingId})  technicianId=${technicianId} (type=${typeof technicianId})`);
    if (!bookingId || !technicianId) {
      clog(`[collection_started] GUARD FAILED — dropped. bookingId falsy=${!bookingId}  technicianId falsy=${!technicianId}`);
      return;
    }
    log('🧪', 'COLLECTION_STARTED', bookingId, `tech_id=${technicianId}`);
    clog(`[collection_started] running UPDATE for booking_id=${bookingId}`);
    db.execute(
      `UPDATE ip_technician_collection
       SET collection_status = 'collection_started', collection_started_at = NOW(), updated_at = NOW()
       WHERE booking_id = ?`,
      [bookingId]
    )
    .then(([result]) => {
      clog(`[collection_started] DB OK — affectedRows=${result.affectedRows}  changedRows=${result.changedRows}  booking_id=${bookingId}`);
      if (result.affectedRows === 0) {
        clog(`[collection_started] WARNING: 0 rows affected — no row with booking_id=${bookingId} in ip_technician_collection`);
      }
    })
    .catch(e => {
      clog(`[collection_started] DB ERROR — booking_id=${bookingId}  error="${e.message}"  code=${e.code}`);
    });
    _cascadeTcStatus(bookingId, 'collection_started', 'collection_started_at');
    _notifyPatient(io, bookingId, 'collection_started', { bookingId });
  });

  socket.on('sample_collected', (data = {}) => {
    clog(`[sample_collected] RAW event received | data=${JSON.stringify(data)}`);
    const { bookingId, technicianId } = data;
    clog(`[sample_collected] parsed bookingId=${bookingId}  technicianId=${technicianId}`);
    if (!bookingId || !technicianId) {
      clog(`[sample_collected] GUARD FAILED — dropped. bookingId falsy=${!bookingId}  technicianId falsy=${!technicianId}`);
      return;
    }
    log('🧫', 'SAMPLE_COLLECTED', bookingId, `tech_id=${technicianId}`);
    clog(`[sample_collected] running UPDATE for booking_id=${bookingId}`);
    db.execute(
      `UPDATE ip_technician_collection
       SET collection_status = 'sample_collected', collected_at = NOW(), updated_at = NOW()
       WHERE booking_id = ?`,
      [bookingId]
    )
    .then(([result]) => {
      clog(`[sample_collected] DB OK — affectedRows=${result.affectedRows}  changedRows=${result.changedRows}  booking_id=${bookingId}`);
      if (result.affectedRows === 0) {
        clog(`[sample_collected] WARNING: 0 rows affected — no row with booking_id=${bookingId}`);
      }
    })
    .catch(e => {
      clog(`[sample_collected] DB ERROR — booking_id=${bookingId}  error="${e.message}"  code=${e.code}`);
    });
    _cascadeTcStatus(bookingId, 'sample_collected', 'collected_at');
    _notifyPatient(io, bookingId, 'sample_collected', { bookingId });
  });

  // Final technician step — stores completed_at timestamp, frees the technician
  socket.on('handed_to_lab', (data = {}) => {
    clog(`[handed_to_lab] RAW event received | data=${JSON.stringify(data)}`);
    const { bookingId, technicianId } = data;
    clog(`[handed_to_lab] parsed bookingId=${bookingId}  technicianId=${technicianId}`);
    if (!bookingId || !technicianId) {
      clog(`[handed_to_lab] GUARD FAILED — dropped. bookingId falsy=${!bookingId}  technicianId falsy=${!technicianId}`);
      return;
    }
    log('🏥', 'HANDED_TO_LAB', bookingId, `tech_id=${technicianId}`);

    _freeTechnician(technicianId, bookingId);

    dbRun(
      `UPDATE ip_technician_collection
       SET collection_status = 'handed_to_lab', completed_at = NOW(), updated_at = NOW()
       WHERE booking_id = ?`,
      [bookingId]
    );
    dbRun(
      `UPDATE ip_bookings
       SET status = 'collected', updated_at = NOW()
       WHERE booking_id = ?`,
      [bookingId]
    );

    // Cascade to sibling bookings in the same visit group (technician-added members)
    ;(async () => {
      try {
        const [[parentRow]] = await db.execute(
          'SELECT visit_group_id FROM ip_bookings WHERE booking_id = ? LIMIT 1',
          [bookingId]
        );
        if (parentRow?.visit_group_id) {
          const vgId = parentRow.visit_group_id;
          dbRun(
            `UPDATE ip_technician_collection tc
             JOIN ip_bookings b ON b.booking_id = tc.booking_id
             SET tc.collection_status = 'handed_to_lab', tc.completed_at = NOW(), tc.updated_at = NOW()
             WHERE b.visit_group_id = ? AND b.booking_id != ?`,
            [vgId, bookingId]
          );
          dbRun(
            `UPDATE ip_bookings
             SET status = 'collected', updated_at = NOW()
             WHERE visit_group_id = ? AND booking_id != ?`,
            [vgId, bookingId]
          );
          clog(`[handed_to_lab] sibling cascade — visit_group=${vgId} booking=${bookingId}`);
        }
      } catch (e) {
        console.error(`[handed_to_lab] sibling cascade error: ${e.message}`);
      }
    })();

    const tech = onlineTechnicians.get(technicianId);
    if (tech?.sessionId) {
      dbRun(
        `UPDATE ip_technician_sessions
         SET total_bookings_completed = total_bookings_completed + 1,
             updated_at               = NOW()
         WHERE session_id = ?`,
        [tech.sessionId]
      );
    }

    _notifyPatient(io, bookingId, 'handed_to_lab', { bookingId });
    bookingRooms.delete(bookingId);
    lastTechLocation.delete(String(bookingId));
  });

  // ── Lab pipeline stages ──────────────────────────────────────────────────────

  socket.on('sample_received_at_lab', (data = {}) => {
    const { bookingId } = data;
    if (!bookingId) return;
    dbRun(
      `UPDATE ip_technician_collection
       SET collection_status = 'sample_received', sample_received_at = NOW(), updated_at = NOW()
       WHERE booking_id = ?`,
      [bookingId]
    );
    _notifyPatient(io, bookingId, 'sample_received_at_lab', { bookingId });
    log('🧪', 'SAMPLE_RECEIVED', bookingId);
    sendToBookingOwner(
      bookingId,
      'Sample Reached Lab 🧪',
      'Your sample has been received at the lab and is being processed.',
      { type: 'sample_received_at_lab', booking_id: String(bookingId) }
    );
  });

  socket.on('test_in_progress', (data = {}) => {
    const { bookingId } = data;
    if (!bookingId) return;
    dbRun(
      `UPDATE ip_technician_collection
       SET collection_status = 'test_in_progress', test_in_progress_at = NOW(), updated_at = NOW()
       WHERE booking_id = ?`,
      [bookingId]
    );
    _notifyPatient(io, bookingId, 'test_in_progress', { bookingId });
    log('⚗️', 'TEST_IN_PROGRESS', bookingId);
  });

  socket.on('report_ready', (data = {}) => {
    const { bookingId, reportUrl, reportId } = data;
    if (!bookingId) return;
    dbRun(
      `UPDATE ip_technician_collection
       SET collection_status = 'report_ready', report_ready_at = NOW(), updated_at = NOW()
       WHERE booking_id = ?`,
      [bookingId]
    );
    _notifyPatient(io, bookingId, 'report_ready', {
      bookingId,
      reportUrl: reportUrl ?? null,
      reportId:  reportId  ?? null,
    });
    log('📄', 'REPORT_READY', bookingId);
  });

  // ════════════════════════════════════════════════════════════════════════════
  //  TRANSPORT — Driver events
  // ════════════════════════════════════════════════════════════════════════════

  socket.on('driver_online', (data = {}) => {
    const { driverId, driverName, lat, lng } = data;
    if (!driverId) { console.warn('driver_online: missing driverId'); return; }

    socket.driverId   = driverId;
    socket.driverName = driverName;

    onlineDrivers.set(driverId, {
      socketId:    socket.id,
      lat:         lat  ?? null,
      lng:         lng  ?? null,
      name:        driverName,
      isOnline:    true,
      isAvailable: true,
    });

    logBlock('🚗', `Driver Online`, [
      `Driver : ${driverName} (ID: ${driverId})`,
      `GPS    : ${lat != null ? `${lat.toFixed(5)}, ${lng.toFixed(5)}` : 'no GPS'}`,
    ]);

    dispatchQueues.forEach((dispatch, bookingId) => {
      if (dispatch.bookingType !== 'transport') return;
      if (dispatch.queue.some(q => q.id === driverId)) return;

      const { patientLat, patientLng } = dispatch.bookingData;
      const dist =
        lat != null && patientLat != null
          ? haversine(patientLat, patientLng, lat, lng)
          : Infinity;

      const futureStart = dispatch.techIdx + 1;
      let insertAt = dispatch.queue.length;
      for (let i = futureStart; i < dispatch.queue.length; i++) {
        if (dist < (dispatch.queue[i].dist ?? Infinity)) { insertAt = i; break; }
      }

      dispatch.queue.splice(insertAt, 0, {
        id: driverId, socketId: socket.id,
        lat: lat ?? null, lng: lng ?? null,
        name: driverName,
        isOnline: true, isAvailable: true,
        dist,
      });

      logBlock('🆕', `Queue Injection (transport)  booking=${bookingId}`, [
        `Driver   : ${driverName} (ID: ${driverId})`,
        `Distance : ${dist === Infinity ? 'no GPS' : `${dist.toFixed(1)} km`}`,
        `Slot     : #${insertAt + 1} of ${dispatch.queue.length}`,
      ]);
    });
  });

  socket.on('driver_offline', (data = {}) => {
    const { driverId } = data;
    if (!driverId) return;
    onlineDrivers.delete(driverId);
    log('🔴', 'DRIVER_OFFLINE', '-', `id=${driverId}`);
  });

  socket.on('update_driver_location', (data = {}) => {
    const { driverId, lat, lng } = data;
    if (!driverId || lat == null || lng == null) return;
    const d = onlineDrivers.get(driverId);
    if (d) onlineDrivers.set(driverId, { ...d, lat, lng });
  });

  socket.on('booking_declined', (data = {}) => {
    const { bookingId, driverId } = data;
    if (!bookingId) return;
    log('❌', 'DRIVER_DECLINED', bookingId, `driver_id=${driverId} → next actor`);
    const dispatch = dispatchQueues.get(bookingId);
    if (dispatch) {
      if (dispatch.handle) { clearTimeout(dispatch.handle); dispatch.handle = null; }
      dispatch.techIdx++;
      dispatch.attemptNum = 1;
      dispatchAttempt(io, bookingId);
    }
  });

  socket.on('driver_arrived', (data = {}) => {
    const { bookingId, driverId } = data;
    if (!bookingId) return;
    _notifyPatient(io, bookingId, 'driver_arrived', { bookingId });
    log('📍', 'DRIVER_ARRIVED', bookingId, `driver_id=${driverId}`);
  });

  socket.on('trip_completed', (data = {}) => {
    const { bookingId, driverId } = data;
    if (!bookingId) return;

    log('🏁', 'TRIP_COMPLETED', bookingId, `driver_id=${driverId}`);

    if (driverId) {
      const d = onlineDrivers.get(driverId);
      if (d) onlineDrivers.set(driverId, { ...d, isAvailable: true });
      driverActiveBookings.delete(driverId);
    }
    acceptedBookings.delete(bookingId);

    _notifyPatient(io, bookingId, 'trip_completed', { bookingId });
    bookingRooms.delete(bookingId);
    lastTechLocation.delete(String(bookingId));
  });

  // ════════════════════════════════════════════════════════════════════════════
  //  SHARED — Patient registration + tracking + booking dispatch
  // ════════════════════════════════════════════════════════════════════════════

  socket.on('register_patient_socket', (data = {}) => {
    const { patientId, bookingId } = data;
    if (!patientId || !bookingId) return;
    socket.patientId = patientId;
    patientSockets.set(patientId, socket.id);
    bookingRooms.set(bookingId, patientId);
    log('👤', 'PATIENT_REGISTERED', bookingId, `patient=${patientId}`);

    // Catch-up: patient may be reconnecting after a technician was already assigned
    // (admin booking, or patient lost connection mid-journey).
    // Query once and push the current state so they don't have to wait for the next event.
    db.execute(
      `SELECT technician_id, technician_name, collection_status
       FROM ip_technician_collection
       WHERE booking_id = ?
         AND collection_status NOT IN ('handed_to_lab', 'completed')
       LIMIT 1`,
      [bookingId]
    ).then(([[row]]) => {
      if (!row) return; // no assignment yet — normal patient flow, nothing to send

      // Tell the patient a technician is already assigned
      socket.emit('booking_accepted', {
        bookingId,
        technicianId:   row.technician_id,
        technicianName: row.technician_name,
        driverId:       row.technician_id,
        driverName:     row.technician_name,
        trackingId:     String(bookingId),
      });

      // Re-send last known location if cached within the last 5 minutes
      const lastLoc = lastTechLocation.get(String(bookingId));
      if (lastLoc && Date.now() - lastLoc._cachedAt < 300_000) {
        socket.emit('location_update', lastLoc);
      }

      // Re-send the current journey stage so UI moves to the right screen
      const s = row.collection_status;
      if      (s === 'en_route')          socket.emit('technician_en_route',  { bookingId });
      else if (s === 'arrived')           socket.emit('technician_arrived',   { bookingId });
      else if (s === 'collection_started') socket.emit('collection_started',  { bookingId });
      else if (s === 'sample_collected')  socket.emit('sample_collected',     { bookingId });

      log('📡', 'PATIENT_CATCHUP', bookingId,
        `status=${s} tech=${row.technician_id} (${row.technician_name})`);
    }).catch(e =>
      console.error(`[register_patient_socket] catch-up query failed booking=${bookingId}: ${e.message}`)
    );
  });

  socket.on('join_tracking', (payload) => {
    const room = String(
      payload && payload.trackingId ? payload.trackingId : payload || ''
    );
    if (!room) return;
    socket.join(room);
    const last = lastTechLocation.get(room);
    if (last && Date.now() - last._cachedAt < 300_000)
      socket.emit('location_update', last);
    log('🚪', 'JOIN_TRACKING', room);
  });

  // Live location relay: tech/driver → patient room + DB
  socket.on('send_location', (data) => {
    if (!data) return;
    const {
      trackingId, technicianId, driverId, sessionId, bookingId,
      lat: dataLat, lng: dataLng, latitude, longitude,
      accuracy, speed, bearing, batteryLevel, networkType,
      addressLabel, isPatient, name,
    } = data;

    const lat = dataLat ?? latitude;
    const lng = dataLng ?? longitude;
    if (!trackingId || lat == null || lng == null) return;

    if (technicianId) {
      const t = onlineTechnicians.get(technicianId);
      if (t) onlineTechnicians.set(technicianId, { ...t, lat, lng });
    }

    const out = { trackingId, lat, lng, speed, bearing, addressLabel, isPatient, name };
    lastTechLocation.set(String(trackingId), { ...out, _cachedAt: Date.now() });

    io.to(String(trackingId)).emit('location_update', out);

    const bId   = parseInt(trackingId, 10);
    const patId = isNaN(bId)
      ? bookingRooms.get(trackingId)
      : (bookingRooms.get(bId) ?? bookingRooms.get(String(bId)));
    if (patId) {
      const patSid = patientSockets.get(patId);
      if (patSid) io.to(patSid).emit('location_update', out);
    }

    if (technicianId) {
      dbRun(
        `UPDATE ip_technician_live_location
         SET latitude        = ?,
             longitude       = ?,
             accuracy_meters = ?,
             speed_kmph      = ?,
             bearing_degrees = ?,
             battery_level   = ?,
             network_type    = ?,
             address_label   = ?,
             last_ping_at    = NOW(),
             updated_at      = NOW()
         WHERE technician_id = ?`,
        [lat, lng, accuracy ?? null, speed ?? null, bearing ?? null,
         batteryLevel ?? null, networkType ?? null, addressLabel ?? null, technicianId]
      );
      dbRun(
        `INSERT INTO ip_technician_location_log
           (technician_id, session_id, booking_id, latitude, longitude,
            accuracy_meters, speed_kmph, bearing_degrees,
            battery_level, network_type, source, device_timestamp, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'app', NOW(), NOW())`,
        [technicianId, sessionId ?? null, bookingId ?? null,
         lat, lng, accuracy ?? null, speed ?? null, bearing ?? null,
         batteryLevel ?? null, networkType ?? null]
      );
      if (bookingId) {
        dbRun(
          `INSERT INTO ip_patient_tracking_data
             (booking_id, tracked_entity_id, latitude, longitude,
              accuracy_meters, address_label, source, device_timestamp, created_at)
           VALUES (?, ?, ?, ?, ?, ?, 'technician_app', NOW(), NOW())`,
          [bookingId, technicianId, lat, lng, accuracy ?? null, addressLabel ?? null]
        );
      }
      if (sessionId) {
        dbRun(
          `UPDATE ip_technician_sessions
           SET total_pings = total_pings + 1, updated_at = NOW()
           WHERE session_id = ?`,
          [sessionId]
        );
      }
    }
  });

  // ── Patient-initiated booking request ─────────────────────────────────────────
  socket.on('booking_request', (data) => _handleBookingRequest(io, socket, data));

  // ── Patient cancels pending search ───────────────────────────────────────────
  socket.on('patient_cancel_search', (data = {}) => {
    const bookingId = data.bookingId;
    if (!bookingId) return;

    log('🚫', 'PATIENT_CANCEL_SEARCH', bookingId);

    // Pull dispatch state before deleting so we can stop the timeout and
    // dismiss the overlay on whichever tech currently holds the request.
    const dispatch = dispatchQueues.get(bookingId);
    if (dispatch) {
      clearTimeout(dispatch.handle); // stop the 40s retry timer immediately
      const actor = dispatch.queue[dispatch.techIdx];
      if (actor) {
        const actorMap   = dispatch.bookingType === 'transport' ? onlineDrivers : onlineTechnicians;
        const techEntry  = actorMap.get(actor.id);
        if (techEntry?.socketId) {
          io.to(techEntry.socketId).emit('booking_cancelled', { bookingId });
          log('📢', 'CANCEL_OVERLAY_DISMISSED', bookingId,
            `tech=${actor.name} (id=${actor.id})`);
        }
      }
    }

    dispatchQueues.delete(bookingId);
    bookingRooms.delete(bookingId);
  });

  // ── Disconnect cleanup ────────────────────────────────────────────────────────
  socket.on('disconnect', () => {

    if (socket.technicianId) {
      const tid = socket.technicianId;

      const activeBookingId = technicianActiveBookings.get(tid);
      if (activeBookingId) {
        _notifyPatient(io, activeBookingId, 'booking_cancelled', {
          bookingId: activeBookingId,
          reason:    'technician_disconnected',
        });
        technicianActiveBookings.delete(tid);
        acceptedBookings.delete(activeBookingId);
        log('⚠️', 'TECH_DISCONNECT_BOOKING', activeBookingId,
          `tech=${socket.technicianName ?? '?'} id=${tid} — patient notified`);
      }

      // Null socketId so dispatch skips socket.io and falls through to FCM.
      // The entry stays in onlineTechnicians so the tech is still reachable
      // for the grace period — the 45 s window lets them reconnect seamlessly.
      const techEntry = onlineTechnicians.get(tid);
      if (techEntry) {
        onlineTechnicians.set(tid, { ...techEntry, socketId: null });
      }

      // Cancel any prior grace timer before starting a fresh one.
      const existingGrace = graceTimers.get(tid);
      if (existingGrace) clearTimeout(existingGrace);

      graceTimers.set(tid, setTimeout(() => {
        graceTimers.delete(tid);
        onlineTechnicians.delete(tid);
        // DB online_status stays 'online' — only an explicit technician_offline event
        // changes it.  Just null the now-stale socket_id.
        dbRun(
          `UPDATE ip_technician_live_location
           SET socket_id = NULL, updated_at = NOW()
           WHERE technician_id = ?`,
          [tid]
        );
        log('⏰', 'GRACE_EXPIRED', '-',
          `tech=${socket.technicianName ?? '?'} id=${tid} — evicted from memory after ${GRACE_MS / 1000}s (DB stays online)`);
      }, GRACE_MS));

      log('⏳', 'TECH_DISCONNECT', '-',
        `id=${tid} name=${socket.technicianName ?? '?'} — grace period started (${GRACE_MS / 1000}s)`);
    }

    if (socket.driverId) {
      const did = socket.driverId;

      const activeBookingId = driverActiveBookings.get(did);
      if (activeBookingId) {
        _notifyPatient(io, activeBookingId, 'booking_cancelled', {
          bookingId: activeBookingId,
          reason:    'driver_disconnected',
        });
        driverActiveBookings.delete(did);
        acceptedBookings.delete(activeBookingId);
        log('⚠️', 'DRIVER_DISCONNECT_BOOKING', activeBookingId,
          `driver=${socket.driverName ?? '?'} id=${did} — patient notified`);
      }

      onlineDrivers.delete(did);
      log('🔌', 'DRIVER_DISCONNECT', '-', `id=${did}`);
    }

    if (socket.patientId) patientSockets.delete(socket.patientId);
  });
};

// ── Scheduled dispatch entry point (called by dispatchScheduler cron) ─────────
// Creates a virtual socket that routes patient-facing events to the booking room
// so they're delivered if the patient reconnects; otherwise silently dropped.
module.exports.triggerScheduledDispatch = async function(bookingData, io) {
  const ioRef = io ?? _io;
  if (!ioRef) {
    console.error('[Scheduler] triggerScheduledDispatch: io not available yet');
    return;
  }
  const { bookingId } = bookingData;
  const virtualSocket = {
    id:        `sched_${bookingId}_${Date.now()}`,
    isVirtual: true, // prevents _handleBookingRequest from clobbering a real patient socket
    patientId: null,
    emit(event, payload) {
      ioRef.to(String(bookingId)).emit(event, payload);
      log('📅', 'SCHED_EMIT', bookingId, event);
    },
  };
  await _handleBookingRequest(ioRef, virtualSocket, bookingData);
};