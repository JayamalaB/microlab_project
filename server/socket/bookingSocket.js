'use strict';

const {
  BookingRequest,
  TechnicianLiveLocation,
  TechnicianLocationLog,
  TechnicianSession,
  TechnicianCollectionBooking,
  PatientTrackingData,
} = require('../models');

// ── In-memory state ──────────────────────────────────────────────────────────
const onlineTechnicians = new Map(); // technicianId → { socketId, lat, lng, name, sessionId }
const patientSockets    = new Map(); // patientId    → socketId
const bookingRooms      = new Map(); // bookingId    → patientId
const dispatchQueues    = new Map(); // bookingId    → { bookingData, queue, techIdx, attemptNum, handle }
const lastTechLocation  = new Map(); // trackingId   → { ...payload, _cachedAt }

const MAX_ATTEMPTS       = 3;
const ATTEMPT_TIMEOUT_MS = 40_000;
const RETRY_GAP_MS       = 3_000;
const LOCATION_CACHE_TTL = 5 * 60 * 1000; // 5 minutes

// ── Helpers ──────────────────────────────────────────────────────────────────

function haversineKm(lat1, lng1, lat2, lng2) {
  const R     = 6371;
  const toRad = d => (d * Math.PI) / 180;
  const dLat  = toRad(lat2 - lat1);
  const dLng  = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function getNearestTechnicians(patientLat, patientLng, limit = 3) {
  const list = [];
  for (const [technicianId, tech] of onlineTechnicians) {
    if (tech.lat == null || tech.lng == null) continue;
    const dist = haversineKm(patientLat, patientLng, tech.lat, tech.lng);
    list.push({ technicianId, dist, ...tech });
  }
  list.sort((a, b) => a.dist - b.dist);
  return list.slice(0, limit);
}

// ── Dispatch engine ──────────────────────────────────────────────────────────

async function sendToTechnician(io, bookingId) {
  const state = dispatchQueues.get(bookingId);
  if (!state) return;

  const { queue, bookingData } = state;

  // All technicians exhausted → timeout
  if (state.techIdx >= queue.length) {
    const patientId = bookingRooms.get(bookingId);
    if (patientId) {
      const pid = patientSockets.get(patientId);
      if (pid) io.to(pid).emit('booking_timeout', { bookingId });
    }
    try {
      await BookingRequest.update(
        { request_status: 'expired' },
        { where: { booking_id: bookingId, request_status: 'pending' } }
      );
    } catch (err) {
      console.error('[dispatch] expire DB error:', err.message);
    }
    dispatchQueues.delete(bookingId);
    return;
  }

  // Current technician has used all attempts → advance
  if (state.attemptNum > MAX_ATTEMPTS) {
    state.techIdx++;
    state.attemptNum = 1;
    return sendToTechnician(io, bookingId);
  }

  const tech = queue[state.techIdx];

  // DB: insert row on first attempt, increment counter on retries
  try {
    if (state.attemptNum === 1) {
      await BookingRequest.create({
        booking_id:           bookingData.bookingId,
        technician_id:        tech.technicianId,
        technician_name:      tech.name,
        request_status:       'pending',
        total_attempts_count: 1,
        max_attempts:         MAX_ATTEMPTS,
        last_sent_at:         new Date(),
        created_at:           new Date(),
        updated_at:           new Date(),
      });
    } else {
      await BookingRequest.update(
        { total_attempts_count: state.attemptNum, last_sent_at: new Date(), updated_at: new Date() },
        { where: { booking_id: bookingData.bookingId, technician_id: tech.technicianId } }
      );
    }
  } catch (err) {
    console.error('[dispatch] booking_requests DB error:', err.message);
  }

  // Emit to technician
  io.to(tech.socketId).emit('booking_request', {
    bookingId:      bookingData.bookingId,
    patientId:      bookingData.patientId,
    patientName:    bookingData.patientName,
    patientMobile:  bookingData.patientMobile,
    patientAddress: bookingData.patientAddress,
    patientLat:     bookingData.patientLat,
    patientLng:     bookingData.patientLng,
    hospital:       bookingData.hospital,
    createdAt:      new Date(),
  });

  // Timeout → wait RETRY_GAP_MS → next attempt
  state.handle = setTimeout(() => {
    const current = dispatchQueues.get(bookingId);
    if (!current) return;

    current.handle = setTimeout(() => {
      const still = dispatchQueues.get(bookingId);
      if (!still) return;
      still.attemptNum++;
      sendToTechnician(io, bookingId);
    }, RETRY_GAP_MS);
  }, ATTEMPT_TIMEOUT_MS);
}

// ── Main export ──────────────────────────────────────────────────────────────

module.exports = function bookingSocket(io, socket) {

  // ── technician_online ──────────────────────────────────────────────────────
  socket.on('technician_online', async ({ technicianId, technicianName, sessionId, lat, lng }) => {
    onlineTechnicians.set(technicianId, {
      socketId: socket.id, lat, lng, name: technicianName, sessionId,
    });

    try {
      await TechnicianLiveLocation.upsert({
        technician_id: technicianId,
        socket_id:     socket.id,
        session_id:    sessionId,
        latitude:      lat,
        longitude:     lng,
        online_status: 'online',
        updated_at:    new Date(),
      });
    } catch (err) {
      console.error('[technician_online] DB error:', err.message);
    }
  });

  // ── technician_offline ─────────────────────────────────────────────────────
  socket.on('technician_offline', async ({ technicianId }) => {
    onlineTechnicians.delete(technicianId);

    try {
      await TechnicianLiveLocation.update(
        { online_status: 'offline', socket_id: null, updated_at: new Date() },
        { where: { technician_id: technicianId } }
      );
    } catch (err) {
      console.error('[technician_offline] DB error:', err.message);
    }
  });

  // ── update_technician_location ─────────────────────────────────────────────
  socket.on('update_technician_location', async ({
    technicianId, lat, lng, accuracy, speed, bearing, batteryLevel,
  }) => {
    const tech = onlineTechnicians.get(technicianId);
    if (tech) { tech.lat = lat; tech.lng = lng; }

    try {
      await TechnicianLiveLocation.update(
        {
          latitude:        lat,
          longitude:       lng,
          accuracy_meters: accuracy,
          speed_kmph:      speed,
          bearing_degrees: bearing,
          battery_level:   batteryLevel,
          last_ping_at:    new Date(),
          updated_at:      new Date(),
        },
        { where: { technician_id: technicianId } }
      );
    } catch (err) {
      console.error('[update_technician_location] DB error:', err.message);
    }
  });

  // ── register_patient_socket ────────────────────────────────────────────────
  socket.on('register_patient_socket', ({ patientId, bookingId }) => {
    patientSockets.set(patientId, socket.id);
    if (bookingId != null) bookingRooms.set(bookingId, patientId);
  });

  // ── join_tracking ──────────────────────────────────────────────────────────
  socket.on('join_tracking', ({ trackingId }) => {
    socket.join(`tracking:${trackingId}`);

    const cached = lastTechLocation.get(trackingId);
    if (cached && Date.now() - cached._cachedAt < LOCATION_CACHE_TTL) {
      const { _cachedAt, ...payload } = cached;
      socket.emit('location_update', payload);
    }
  });

  // ── booking_request (from patient) ─────────────────────────────────────────
  socket.on('booking_request', (data) => {
    const { bookingId, patientId, patientLat, patientLng } = data;

    if (dispatchQueues.has(bookingId)) return; // guard: no duplicate dispatch

    patientSockets.set(patientId, socket.id);
    bookingRooms.set(bookingId, patientId);

    const queue = getNearestTechnicians(patientLat, patientLng);

    if (queue.length === 0) {
      socket.emit('booking_timeout', { bookingId });
      return;
    }

    dispatchQueues.set(bookingId, {
      bookingData: data,
      queue,
      techIdx:    0,
      attemptNum: 1,
      handle:     null,
    });

    sendToTechnician(io, bookingId);
  });

  // ── booking_accepted (from technician) ────────────────────────────────────
  socket.on('booking_accepted', async ({ bookingId, technicianId, technicianName, sessionId, trackingId }) => {
    const state = dispatchQueues.get(bookingId);
    if (!state) return;

    if (state.handle) clearTimeout(state.handle);
    dispatchQueues.delete(bookingId);

    // Notify other queued technicians that booking is gone
    for (const tech of state.queue) {
      if (tech.technicianId !== technicianId && tech.socketId) {
        io.to(tech.socketId).emit('booking_already_taken', { bookingId });
      }
    }

    // Notify patient
    const patientId = bookingRooms.get(bookingId);
    if (patientId) {
      const pid = patientSockets.get(patientId);
      if (pid) {
        io.to(pid).emit('booking_accepted', { bookingId, technicianId, technicianName, trackingId });
      }
    }

    try {
      await BookingRequest.update(
        { request_status: 'accepted', responded_at: new Date(), updated_at: new Date() },
        { where: { booking_id: bookingId, technician_id: technicianId } }
      );
      await TechnicianCollectionBooking.update(
        {
          collection_status: 'assigned',
          assigned_at:       new Date(),
          technician_id:     technicianId,
          technician_name:   technicianName,
          updated_at:        new Date(),
        },
        { where: { booking_id: bookingId } }
      );
      await TechnicianLiveLocation.update(
        {
          current_booking_id: bookingId,
          task_status:        'assigned',
          online_status:      'busy',
          updated_at:         new Date(),
        },
        { where: { technician_id: technicianId } }
      );
    } catch (err) {
      console.error('[booking_accepted] DB error:', err.message);
    }
  });

  // ── booking_rejected (from technician) ────────────────────────────────────
  socket.on('booking_rejected', async ({ bookingId, technicianId }) => {
    const state = dispatchQueues.get(bookingId);
    if (!state) return;

    if (state.handle) clearTimeout(state.handle);

    try {
      await BookingRequest.update(
        { request_status: 'rejected', responded_at: new Date(), updated_at: new Date() },
        { where: { booking_id: bookingId, technician_id: technicianId } }
      );
    } catch (err) {
      console.error('[booking_rejected] DB error:', err.message);
    }

    // Skip immediately to next technician
    state.techIdx++;
    state.attemptNum = 1;
    sendToTechnician(io, bookingId);
  });

  // ── technician_en_route ────────────────────────────────────────────────────
  socket.on('technician_en_route', async ({ bookingId }) => {
    try {
      await TechnicianCollectionBooking.update(
        { collection_status: 'en_route', en_route_at: new Date(), updated_at: new Date() },
        { where: { booking_id: bookingId } }
      );
    } catch (err) {
      console.error('[technician_en_route] DB error:', err.message);
    }
  });

  // ── technician_arrived ─────────────────────────────────────────────────────
  socket.on('technician_arrived', async ({ bookingId }) => {
    try {
      await TechnicianCollectionBooking.update(
        { collection_status: 'arrived', arrived_at: new Date(), updated_at: new Date() },
        { where: { booking_id: bookingId } }
      );
    } catch (err) {
      console.error('[technician_arrived] DB error:', err.message);
    }

    const patientId = bookingRooms.get(bookingId);
    if (patientId) {
      const pid = patientSockets.get(patientId);
      if (pid) io.to(pid).emit('technician_arrived', { bookingId });
    }
  });

  // ── collection_completed ───────────────────────────────────────────────────
  socket.on('collection_completed', async ({ bookingId, technicianId }) => {
    const sessionId = onlineTechnicians.get(technicianId)?.sessionId;

    try {
      await TechnicianCollectionBooking.update(
        { collection_status: 'completed', completed_at: new Date(), updated_at: new Date() },
        { where: { booking_id: bookingId } }
      );
      await TechnicianLiveLocation.update(
        {
          current_booking_id: null,
          task_status:        'idle',
          online_status:      'online',
          updated_at:         new Date(),
        },
        { where: { technician_id: technicianId } }
      );
      if (sessionId) {
        await TechnicianSession.increment('total_bookings_completed', {
          where: { session_id: sessionId },
        });
      }
    } catch (err) {
      console.error('[collection_completed] DB error:', err.message);
    }

    const patientId = bookingRooms.get(bookingId);
    if (patientId) {
      const pid = patientSockets.get(patientId);
      if (pid) io.to(pid).emit('collection_completed', { bookingId });
    }

    bookingRooms.delete(bookingId);
  });

  // ── send_location (technician → tracking room) ─────────────────────────────
  socket.on('send_location', async ({
    trackingId, technicianId, sessionId, bookingId,
    lat, lng, accuracy, speed, bearing, batteryLevel, networkType, addressLabel,
  }) => {
    const payload = { trackingId, lat, lng, speed, bearing, addressLabel };

    lastTechLocation.set(trackingId, { ...payload, _cachedAt: Date.now() });
    io.to(`tracking:${trackingId}`).emit('location_update', payload);

    try {
      await Promise.all([
        TechnicianLocationLog.create({
          technician_id:    technicianId,
          session_id:       sessionId,
          booking_id:       bookingId,
          latitude:         lat,
          longitude:        lng,
          accuracy_meters:  accuracy,
          speed_kmph:       speed,
          bearing_degrees:  bearing,
          battery_level:    batteryLevel,
          network_type:     networkType,
          source:           'socket',
          created_at:       new Date(),
        }),

        TechnicianLiveLocation.update(
          {
            latitude:        lat,
            longitude:       lng,
            speed_kmph:      speed,
            bearing_degrees: bearing,
            address_label:   addressLabel,
            last_ping_at:    new Date(),
            updated_at:      new Date(),
          },
          { where: { technician_id: technicianId } }
        ),

        PatientTrackingData.create({
          booking_id:       bookingId,
          tracked_entity_id: technicianId,
          latitude:         lat,
          longitude:        lng,
          accuracy_meters:  accuracy,
          address_label:    addressLabel,
          source:           'socket',
          created_at:       new Date(),
        }),

        sessionId
          ? TechnicianSession.increment('total_pings', { where: { session_id: sessionId } })
          : Promise.resolve(),
      ]);
    } catch (err) {
      console.error('[send_location] DB error:', err.message);
    }
  });

  // ── disconnect ─────────────────────────────────────────────────────────────
  socket.on('disconnect', async () => {
    for (const [technicianId, tech] of onlineTechnicians) {
      if (tech.socketId !== socket.id) continue;

      onlineTechnicians.delete(technicianId);
      try {
        await TechnicianLiveLocation.update(
          { online_status: 'offline', socket_id: null, updated_at: new Date() },
          { where: { technician_id: technicianId } }
        );
      } catch (err) {
        console.error('[disconnect] DB error:', err.message);
      }
      break;
    }
  });
};
