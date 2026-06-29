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
const db = require('../config/db');

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

// ── Race-condition protection ──────────────────────────────────────────────────
const acceptedBookings = new Set(); // bookingIds already accepted (blocks duplicates)

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

// ═══════════════════════════════════════════════════════════════════════════════
//  CORE DISPATCH
// ═══════════════════════════════════════════════════════════════════════════════

function dispatchAttempt(io, bookingId) {
  while (true) {
    const dispatch = dispatchQueues.get(bookingId);
    if (!dispatch) return;

    const { queue, bookingData, bookingType = 'lab' } = dispatch;
    const actorMap = bookingType === 'transport' ? onlineDrivers : onlineTechnicians;

    if (dispatch.techIdx >= queue.length) {
      const triedIds = new Set(queue.map(a => a.id));

      const fresh = buildFullQueue(
        bookingData.patientLat ?? null,
        bookingData.patientLng ?? null,
        actorMap,
        bookingData.branchId   ?? null
      ).filter(a => !triedIds.has(a.id));

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
        // Notify patient BEFORE deleting bookingRooms so direct-socket fallback works
        dispatchQueues.delete(bookingId);
        _notifyPatient(io, bookingId, 'booking_timeout', { bookingId });
        bookingRooms.delete(bookingId);
        if (bookingType !== 'transport') {
          dbRun(
            `UPDATE ip_booking_requests
             SET request_status = 'expired'
             WHERE booking_id = ? AND request_status = 'pending'`,
            [bookingId]
          );
        }
        logBlock('⏰', `Booking Timeout  booking=${bookingId}`, [
          'All available actors exhausted — no one responded.',
          'Patient notified.',
        ]);
        return;
      }
    }

    const actor  = dispatch.queue[dispatch.techIdx];
    const online = actorMap.get(actor.id);

    if (!online || !online.isOnline || !online.isAvailable) {
      const why = !online ? 'disconnected' : !online.isOnline ? 'went offline' : 'busy';
      log('⚠️', 'ACTOR_SKIPPED', bookingId,
        `tech=${actor.name} id=${actor.id} reason=${why} → advancing`);
      dispatch.techIdx++;
      dispatch.attemptNum = 1;
      continue;
    }

    io.to(online.socketId).emit('booking_request', bookingData);

    const distLabel = actor.dist === Infinity
      ? 'no GPS'
      : `${actor.dist.toFixed(1)} km`;

    logBlock('📤', `Dispatch Attempt  booking=${bookingId}`, [
      `Technician : ${actor.name} (ID: ${actor.id})`,
      `Distance   : ${distLabel}`,
      `Attempt    : ${dispatch.attemptNum} / ${MAX_ATTEMPTS}`,
      `Status     : Waiting response  (${TIMEOUT_MS / 1000}s timeout)`,
    ]);

    if (bookingType !== 'transport') {
      dbRun(
        `INSERT INTO ip_booking_requests
           (booking_id, technician_id, technician_name, request_status,
            total_attempts, max_attempts, last_sent_at)
         VALUES (?, ?, ?, 'pending', 1, ?, NOW())
         ON DUPLICATE KEY UPDATE
           request_status = 'pending',
           total_attempts = total_attempts + 1,
           last_sent_at   = NOW(),
           updated_at     = NOW()`,
        [bookingId, actor.id, actor.name || '', MAX_ATTEMPTS]
      );
    }

    dispatch.handle = setTimeout(() => {
      dispatch.handle = null;

      if (dispatch.attemptNum < MAX_ATTEMPTS) {
        dispatch.attemptNum++;
        log('🔁', 'TECH_TIMEOUT_RETRY', bookingId,
          `tech=${actor.name} retry=${dispatch.attemptNum}/${MAX_ATTEMPTS} ` +
          `gap=${RETRY_GAP_MS}ms`
        );
        dispatch.handle = setTimeout(() => dispatchAttempt(io, bookingId), RETRY_GAP_MS);
      } else {
        const actorEntry = actorMap.get(actor.id);
        if (actorEntry?.socketId) {
          io.to(actorEntry.socketId).emit('booking_cancelled', { bookingId });
          log('📢', 'OVERLAY_DISMISSED', bookingId,
            `tech=${actor.name} — overlay cleared after ${MAX_ATTEMPTS} timeouts`);
        }

        dispatch.techIdx++;
        dispatch.attemptNum = 1;
        log('⏭️', 'TECH_TIMEOUT_SKIP', bookingId,
          `tech=${actor.name} exhausted ${MAX_ATTEMPTS} attempts → next actor`);
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

async function _trySlotBasedAssign(io, socket, { bookingId, branchId, patientId, patientAddress, patientLat, patientLng, bookingData }) {
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

    // Find the first technician who declared availability for this branch + date
    const [slotRows] = await db.execute(
      `SELECT ts.technician_id, u.user_name
       FROM ip_technician_slots ts
       JOIN ip_technicians t ON t.technician_id = ts.technician_id
       JOIN ip_users u       ON u.user_id        = t.user_id
       WHERE ts.branch_id    = ?
         AND ts.slot_date    = ?
         AND ts.is_available = 1
         AND ts.booked_count < ts.max_bookings
       ORDER BY ts.booked_count ASC
       LIMIT 1`,
      [branchId, collectionDate]
    );

    if (slotRows.length === 0) {
      log('⚠️', 'SLOT_FALLBACK_MISS', bookingId,
        `no slot entry for branch=${branchId} date=${collectionDate}`);
      return false;
    }

    const techId   = slotRows[0].technician_id;
    const techName = slotRows[0].user_name;

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
        techIdx:     0,
        attemptNum:  1,
        handle:      null,
        bookingType: 'lab',
      });

      dispatchAttempt(io, bookingId);

      logBlock('📤', `Slot→Dispatch  booking=${bookingId}`, [
        `Technician : ${techName} (ID: ${techId})`,
        `Date       : ${collectionDate}  Branch : ${branchId}`,
        `Status     : ONLINE — dispatching normally (waiting for acceptance)`,
      ]);

      return true;
    }

    // ── Technician is offline — auto-confirm so patient isn't left waiting indefinitely.
    log('📋', 'SLOT_OFFLINE_ASSIGN', bookingId,
      `tech=${techName} id=${techId} offline — auto-confirming for date=${collectionDate}`);

    await db.execute(
      `INSERT INTO ip_technician_collection
         (booking_id, technician_id, collection_status, collection_date,
          collection_address, collection_latitude, collection_longitude,
          assigned_at, created_at, updated_at)
       VALUES (?, ?, 'assigned', ?, ?, ?, ?, NOW(), NOW(), NOW())
       ON DUPLICATE KEY UPDATE
         technician_id     = VALUES(technician_id),
         collection_status = 'assigned',
         assigned_at       = NOW(),
         updated_at        = NOW()`,
      [bookingId, techId, collectionDate,
       patientAddress ?? null, patientLat ?? null, patientLng ?? null]
    );

    dbRun(`UPDATE ip_bookings SET status = 'confirmed', updated_at = NOW()
           WHERE booking_id = ?`, [bookingId]);

    dbRun(`UPDATE ip_technician_slots
           SET booked_count = booked_count + 1
           WHERE technician_id = ? AND slot_date = ? AND branch_id = ?`,
      [techId, collectionDate, branchId]);

    patientSockets.set(patientId, socket.id);
    bookingRooms.set(bookingId, patientId);

    _notifyPatient(io, bookingId, 'booking_accepted', {
      bookingId,
      technicianId:   techId,
      technicianName: techName,
      trackingId:     String(bookingId),
    });

    logBlock('✅', `Slot-Based Assignment (Offline)  booking=${bookingId}`, [
      `Technician : ${techName} (ID: ${techId})`,
      `Date       : ${collectionDate}`,
      `Branch     : ${branchId}`,
      `Status     : OFFLINE — auto-confirmed, patient notified`,
    ]);

    return true;
  } catch (e) {
    console.error('[_trySlotBasedAssign]', e.message);
    return false;
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOCKET EVENT HANDLERS
// ═══════════════════════════════════════════════════════════════════════════════

module.exports = function bookingSocket(io, socket) {

  // ════════════════════════════════════════════════════════════════════════════
  //  LAB — Technician events
  // ════════════════════════════════════════════════════════════════════════════

  socket.on('technician_online', (data = {}) => {
    const { technicianId, technicianName, sessionId, lat, lng, branchId } = data;
    if (!technicianId) {
      console.warn('technician_online: missing technicianId');
      return;
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
      isOnline:    true,
      isAvailable: true,
    });

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

  socket.on('technician_offline', (data = {}) => {
    const { technicianId } = data;
    if (!technicianId) return;

    onlineTechnicians.delete(technicianId);

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

    if (!bookingId) { console.warn('booking_accepted: missing bookingId'); return; }

    if (acceptedBookings.has(bookingId)) {
      const who = driverName ?? technicianName ??
                  String(driverId ?? technicianId ?? '?');
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

    const dispatch     = dispatchQueues.get(bookingId);
    const queuedActors = dispatch?.queue ?? [];
    if (dispatch?.handle) clearTimeout(dispatch.handle);
    const bookingType = dispatch?.bookingType ?? 'lab';
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
           (booking_id, technician_id, collection_status, collection_date,
            collection_address, collection_latitude, collection_longitude,
            assigned_at, created_at, updated_at)
         VALUES (?, ?, 'assigned', CURDATE(), ?, ?, ?, NOW(), NOW(), NOW())
         ON DUPLICATE KEY UPDATE
           technician_id     = VALUES(technician_id),
           collection_status = 'assigned',
           assigned_at       = NOW(),
           updated_at        = NOW()`,
        [bookingId, actorId,
         bd.patientAddress ?? null, bd.patientLat ?? null, bd.patientLng ?? null]
      ).then(([r]) => {
        log('💾', 'TCB_CREATED', bookingId,
          `tech=${actorName} rows=${r.affectedRows}`);
      }).catch(e => {
        console.error(
          `❌ [TCB INSERT FAILED] booking=${bookingId} tech=${actorId}: ${e.message}`
        );
      });

      dbRun(
        `UPDATE ip_bookings
         SET status = 'confirmed', updated_at = NOW()
         WHERE booking_id = ?`,
        [bookingId]
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
    }

    _notifyPatient(io, bookingId, 'booking_accepted', {
      bookingId,
      technicianId: actorId, technicianName: actorName,
      driverId:     actorId, driverName:     actorName,
      trackingId:   String(bookingId),
    });

    log('👤', 'PATIENT_NOTIFIED', bookingId, 'booking_accepted sent');

    queuedActors.forEach(qa => {
      if (qa.id === actorId) return;
      const entry = actorMap.get(qa.id);
      if (entry?.socketId) {
        io.to(entry.socketId).emit('booking_cancelled', { bookingId });
      }
    });
  });

  // ── Technician rejects (active decline) ─────────────────────────────────────
  socket.on('booking_rejected', (data = {}) => {
    const { bookingId, technicianId } = data;
    if (!bookingId || !technicianId) return;

    log('❌', 'TECH_REJECTED', bookingId, `tech_id=${technicianId} → next actor`);

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
      dispatch.techIdx++;
      dispatch.attemptNum = 1;
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
    dbRun(
      `UPDATE ip_technician_live_location
       SET task_status = 'en_route', updated_at = NOW()
       WHERE technician_id = ?`,
      [technicianId]
    );
    _notifyPatient(io, bookingId, 'technician_en_route', { bookingId });
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
    dbRun(
      `UPDATE ip_technician_live_location
       SET task_status = 'arrived', updated_at = NOW()
       WHERE technician_id = ?`,
      [technicianId]
    );
    _notifyPatient(io, bookingId, 'technician_arrived', { bookingId });
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
    const { bookingId, technicianId } = data;
    if (!bookingId || !technicianId) return;
    log('🧪', 'COLLECTION_STARTED', bookingId, `tech_id=${technicianId}`);
    dbRun(
      `UPDATE ip_technician_collection
       SET collection_status = 'collection_started', updated_at = NOW()
       WHERE booking_id = ?`,
      [bookingId]
    );
    _notifyPatient(io, bookingId, 'collection_started', { bookingId });
  });

  socket.on('sample_collected', (data = {}) => {
    const { bookingId, technicianId } = data;
    if (!bookingId || !technicianId) return;
    log('🧫', 'SAMPLE_COLLECTED', bookingId, `tech_id=${technicianId}`);
    dbRun(
      `UPDATE ip_technician_collection
       SET collection_status = 'sample_collected', collected_at = NOW(), updated_at = NOW()
       WHERE booking_id = ?`,
      [bookingId]
    );
    _notifyPatient(io, bookingId, 'sample_collected', { bookingId });
  });

  // Final technician step — stores completed_at timestamp, frees the technician
  socket.on('handed_to_lab', (data = {}) => {
    const { bookingId, technicianId } = data;
    if (!bookingId || !technicianId) return;
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
       SET collection_status = 'sample_received', updated_at = NOW()
       WHERE booking_id = ?`,
      [bookingId]
    );
    _notifyPatient(io, bookingId, 'sample_received_at_lab', { bookingId });
    log('🧪', 'SAMPLE_RECEIVED', bookingId);
  });

  socket.on('test_in_progress', (data = {}) => {
    const { bookingId } = data;
    if (!bookingId) return;
    dbRun(
      `UPDATE ip_technician_collection
       SET collection_status = 'test_in_progress', updated_at = NOW()
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
       SET collection_status = 'report_ready', updated_at = NOW()
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
  socket.on('booking_request', async (data = {}) => {
    const {
      bookingId, patientId, patientName,
      patientMobile = '', patientAddress = '',
      patientLat, patientLng, hospital,
      bookingType = 'lab',
      branchId   = null,
      branchName = null,
    } = data;

    if (!bookingId || !patientId) {
      console.warn('booking_request: missing bookingId or patientId',
        { bookingId, patientId });
      return;
    }

    socket.patientId = patientId;
    patientSockets.set(patientId, socket.id);
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
      createdAt: new Date().toISOString(),
    };

    const slotCtx = { bookingId, branchId, patientId, patientAddress, patientLat, patientLng, bookingData };

    if (actorMap.size === 0) {
      log('⚠️', 'NO_ACTORS_ONLINE', bookingId, `trying slot-based fallback branch=${branchId}`);
      const assigned = await _trySlotBasedAssign(io, socket, slotCtx);
      if (!assigned) {
        socket.emit('booking_timeout', { bookingId });
        log('⏰', 'BOOKING_TIMEOUT', bookingId, 'no actors online & no slot match');
      }
      return;
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
      log('⚠️', 'ALL_ACTORS_BUSY', bookingId, `trying slot-based fallback branch=${branchId}`);
      const assigned = await _trySlotBasedAssign(io, socket, slotCtx);
      if (!assigned) {
        socket.emit('booking_timeout', { bookingId });
        log('⏰', 'BOOKING_TIMEOUT', bookingId, 'all actors busy & no slot match');
      }
      return;
    }

    logBlock('📋', `Booking Created  #${bookingId}`, [
      `Patient    : ${patientName} (ID: ${patientId})`,
      `Type       : ${bookingType}`,
      `Branch     : ${branchId ?? 'unassigned'}`,
      `Location   : ${
        patientLat != null
          ? `${Number(patientLat).toFixed(4)}, ${Number(patientLng).toFixed(4)}`
          : 'unknown'
      }`,
      '',
      'Nearby Technicians (initial queue):',
      ...queue.map((a, i) =>
        `  ${i + 1}. ${a.name} (ID: ${a.id}) — ${
          a.dist === Infinity ? 'no GPS' : `${a.dist.toFixed(1)} km`
        }`
      ),
      '',
      `Online: ${totalOnline}   Available: ${available}   Queued: ${queue.length}`,
    ]);

    dispatchQueues.set(bookingId, {
      bookingData,
      queue,
      techIdx:     0,
      attemptNum:  1,
      handle:      null,
      bookingType,
    });

    dispatchAttempt(io, bookingId);
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

      onlineTechnicians.delete(tid);
      dbRun(
        `UPDATE ip_technician_live_location
         SET online_status = 'offline', socket_id = NULL, updated_at = NOW()
         WHERE technician_id = ?`,
        [tid]
      );
      log('🔌', 'TECH_DISCONNECT', '-',
        `id=${tid} name=${socket.technicianName ?? '?'}`);
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
