import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../constants/app_constants.dart';
import 'notification_service.dart';

// ═══════════════════════════════════════════════════════════════════════════════
//  DATA MODELS  — socket event payloads
// ═══════════════════════════════════════════════════════════════════════════════

class SocketBooking {
  final int bookingId;
  final int patientId;
  final String patientName;
  final String patientMobile;
  final String patientAddress;
  final double? patientLat;
  final double? patientLng;
  final String hospital;
  final String bookingType;
  final DateTime createdAt;
  final int?    branchId;
  final String? branchName;

  SocketBooking({
    required this.bookingId,
    required this.patientId,
    required this.patientName,
    required this.patientMobile,
    required this.patientAddress,
    this.patientLat,
    this.patientLng,
    required this.hospital,
    this.bookingType = 'lab',
    required this.createdAt,
    this.branchId,
    this.branchName,
  });

  factory SocketBooking.fromJson(Map<String, dynamic> j) => SocketBooking(
        bookingId:      _toInt(j['bookingId']),
        patientId:      _toInt(j['patientId']),
        patientName:    j['patientName']    as String? ?? '',
        patientMobile:  j['patientMobile']  as String? ?? '',
        patientAddress: j['patientAddress'] as String? ?? '',
        patientLat:     (j['patientLat']    as num?)?.toDouble(),
        patientLng:     (j['patientLng']    as num?)?.toDouble(),
        hospital:       j['hospital']       as String? ?? '',
        bookingType:    j['bookingType']    as String? ?? 'lab',
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ??
            DateTime.now(),
        branchId:   j['branchId']   != null ? _toInt(j['branchId'])  : null,
        branchName: j['branchName'] as String?,
      );

  static int _toInt(dynamic v) =>
      v is int ? v : int.tryParse(v?.toString() ?? '0') ?? 0;
}

class BookingAcceptedEvent {
  final int bookingId;
  final int technicianId;
  final String technicianName;
  final String trackingId;

  BookingAcceptedEvent({
    required this.bookingId,
    required this.technicianId,
    required this.technicianName,
    required this.trackingId,
  });

  factory BookingAcceptedEvent.fromJson(Map<String, dynamic> j) =>
      BookingAcceptedEvent(
        bookingId:      SocketBooking._toInt(j['bookingId']),
        technicianId:   SocketBooking._toInt(j['technicianId'] ?? j['driverId']),
        technicianName: j['technicianName'] as String? ??
                        j['driverName']     as String? ?? '',
        trackingId:     j['trackingId']     as String? ?? '',
      );
}

class LocationUpdate {
  final String trackingId;
  final double lat;
  final double lng;
  final double? speed;
  final double? bearing;
  final String? addressLabel;

  LocationUpdate({
    required this.trackingId,
    required this.lat,
    required this.lng,
    this.speed,
    this.bearing,
    this.addressLabel,
  });

  factory LocationUpdate.fromJson(Map<String, dynamic> j) => LocationUpdate(
        trackingId:   j['trackingId']   as String? ?? '',
        lat:          (j['lat']         as num).toDouble(),
        lng:          (j['lng']         as num).toDouble(),
        speed:        (j['speed']       as num?)?.toDouble(),
        bearing:      (j['bearing']     as num?)?.toDouble(),
        addressLabel: j['addressLabel'] as String?,
      );
}

class ReportReadyEvent {
  final int bookingId;
  final String? reportUrl;
  final int? reportId;

  ReportReadyEvent({
    required this.bookingId,
    this.reportUrl,
    this.reportId,
  });

  factory ReportReadyEvent.fromJson(Map<String, dynamic> j) => ReportReadyEvent(
        bookingId: SocketBooking._toInt(j['bookingId']),
        reportUrl: j['reportUrl'] as String?,
        reportId:  j['reportId']  != null
            ? SocketBooking._toInt(j['reportId'])
            : null,
      );
}

// ─── Active-booking state objects  (persisted in memory across navigations) ───

/// Holds the in-progress lab (technician-visit) booking so the customer
/// dashboard can show a "Track Technician" banner after navigation.
class ActiveLabBookingInfo {
  final int bookingId;
  final int patientId;
  final String trackingId;
  final int technicianId;
  final String technicianName;
  final double? patientLat;
  final double? patientLng;
  final String patientAddress;
  final bool enRoute;
  final bool arrived;
  final bool collected;

  const ActiveLabBookingInfo({
    required this.bookingId,
    required this.patientId,
    required this.trackingId,
    required this.technicianId,
    required this.technicianName,
    this.patientLat,
    this.patientLng,
    this.patientAddress = '',
    this.enRoute = false,
    this.arrived = false,
    this.collected = false,
  });

  ActiveLabBookingInfo copyWith({
    bool? enRoute,
    bool? arrived,
    bool? collected,
  }) =>
      ActiveLabBookingInfo(
        bookingId:      bookingId,
        patientId:      patientId,
        trackingId:     trackingId,
        technicianId:   technicianId,
        technicianName: technicianName,
        patientLat:     patientLat,
        patientLng:     patientLng,
        patientAddress: patientAddress,
        enRoute:        enRoute  ?? this.enRoute,
        arrived:        arrived  ?? this.arrived,
        collected:      collected ?? this.collected,
      );
}

/// Holds the in-progress transport ride so the dashboard can show a
/// "Track Driver" banner after the patient navigates away.
class ActiveRideInfo {
  final int bookingId;
  final int patientId;
  final String patientName;
  final String trackingId;
  final int driverId;
  final String driverName;
  final double? patientLat;
  final double? patientLng;
  final String patientAddress;
  final String hospital;

  const ActiveRideInfo({
    required this.bookingId,
    required this.patientId,
    required this.patientName,
    required this.trackingId,
    required this.driverId,
    required this.driverName,
    this.patientLat,
    this.patientLng,
    this.patientAddress = '',
    required this.hospital,
  });
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SOCKET SERVICE — singleton
// ═══════════════════════════════════════════════════════════════════════════════

class SocketService {
  SocketService._internal();
  static final SocketService instance = SocketService._internal();

  io.Socket? _socket;

  // ── Identity ───────────────────────────────────────────────────────────────
  int    userId   = 0;
  String userRole = ''; // 'technician' | 'customer' | 'driver'
  int?   sessionId;
  String userName   = '';
  int?   _branchId;

  // ── Technician availability state ──────────────────────────────────────────
  // _isAvailable: tech has toggled "Online" on the dashboard.
  // _isBusy:      tech currently has an active booking (accept → complete).
  //   Reconnect must NOT re-emit technician_online when busy, otherwise the
  //   server marks the tech available and may assign a second booking.
  bool _isAvailable    = false;
  bool _isBusy         = false;
  int? _activeBookingId;
  double? _lastLat;
  double? _lastLng;

  // ── FCM push token ─────────────────────────────────────────────────────────
  String? _fcmToken;

  // Called by NotificationService after getToken() or onTokenRefresh.
  void updateFcmToken(String token) {
    _fcmToken = token;
    // If already online, re-emit so the server stores the latest token.
    if (_isAvailable && isConnected) {
      _emitTechnicianOnline();
      _log('FCM', 'token updated — re-emitted technician_online');
    }
  }

  // ── Driver availability state ──────────────────────────────────────────────
  bool    _isDriverOnline = false;
  double? _driverLat;
  double? _driverLng;

  // ── Active-booking state (survives screen navigation) ─────────────────────
  final activeLabBooking = ValueNotifier<ActiveLabBookingInfo?>(null);
  final activeRide       = ValueNotifier<ActiveRideInfo?>(null);

  // ── Public getters ─────────────────────────────────────────────────────────
  bool  get isAvailable      => _isAvailable;
  bool  get isBusy           => _isBusy;
  bool  get hasActiveBooking => _isBusy;
  int?  get activeBookingId  => _activeBookingId;
  bool  get isDriverOnline   => _isDriverOnline;
  bool  get isConnected      => _socket?.connected ?? false;

  // ═══════════════════════════════════════════════════════════════════════════
  //  STREAMS
  // ═══════════════════════════════════════════════════════════════════════════

  // lab / shared
  final _bookingRequestCtrl      = StreamController<SocketBooking>.broadcast();
  final _bookingAcceptedCtrl     = StreamController<BookingAcceptedEvent>.broadcast();
  final _bookingCancelledCtrl    = StreamController<int>.broadcast();
  final _bookingTimeoutCtrl      = StreamController<int>.broadcast();
  final _locationUpdateCtrl      = StreamController<LocationUpdate>.broadcast();
  final _techEnRouteCtrl         = StreamController<int>.broadcast();
  final _techArrivedCtrl         = StreamController<int>.broadcast();
  final _collectionCompletedCtrl  = StreamController<int>.broadcast();
  final _collectionStartedCtrl    = StreamController<int>.broadcast();
  final _sampleCollectedCtrl      = StreamController<int>.broadcast();
  final _handedToLabCtrl          = StreamController<int>.broadcast();
  final _sampleReceivedCtrl       = StreamController<int>.broadcast();
  final _testInProgressCtrl       = StreamController<int>.broadcast();
  final _reportReadyCtrl         = StreamController<ReportReadyEvent>.broadcast();
  // transport
  final _driverArrivedCtrl       = StreamController<int>.broadcast();
  final _tripCompletedCtrl       = StreamController<int>.broadcast();
  // meta
  final _connectedCtrl           = StreamController<bool>.broadcast();
  // availability sync — dashboard listens to keep its toggle in sync
  final _availabilityCtrl        = StreamController<bool>.broadcast();

  Stream<SocketBooking>        get onBookingRequest       => _bookingRequestCtrl.stream;
  Stream<BookingAcceptedEvent> get onBookingAccepted      => _bookingAcceptedCtrl.stream;
  Stream<int>                  get onBookingCancelled     => _bookingCancelledCtrl.stream;
  Stream<int>                  get onBookingTimeout       => _bookingTimeoutCtrl.stream;
  Stream<LocationUpdate>       get onLocationUpdate       => _locationUpdateCtrl.stream;
  Stream<int>                  get onTechnicianEnRoute    => _techEnRouteCtrl.stream;
  Stream<int>                  get onTechnicianArrived    => _techArrivedCtrl.stream;
  Stream<int>                  get onCollectionCompleted  => _collectionCompletedCtrl.stream;
  Stream<int>                  get onCollectionStarted    => _collectionStartedCtrl.stream;
  Stream<int>                  get onSampleCollected      => _sampleCollectedCtrl.stream;
  Stream<int>                  get onHandedToLab          => _handedToLabCtrl.stream;
  Stream<int>                  get onSampleReceived       => _sampleReceivedCtrl.stream;
  Stream<int>                  get onTestInProgress       => _testInProgressCtrl.stream;
  Stream<ReportReadyEvent>     get onReportReady          => _reportReadyCtrl.stream;
  Stream<int>                  get onDriverArrived        => _driverArrivedCtrl.stream;
  Stream<int>                  get onTripCompleted        => _tripCompletedCtrl.stream;
  Stream<bool>                 get onConnected            => _connectedCtrl.stream;
  // Dashboard listens to stay in sync with booking accept/complete events.
  Stream<bool>                 get onAvailabilityChanged  => _availabilityCtrl.stream;

  // ═══════════════════════════════════════════════════════════════════════════
  //  LOGGING
  // ═══════════════════════════════════════════════════════════════════════════

  static void _log(String tag, String msg) {
    if (kDebugMode) {
      final ts = DateTime.now().toIso8601String().substring(11, 23);
      debugPrint('$ts [SocketService][$tag] $msg');
    }
  }

  // ── Helper: accept bookingId as int or String ──────────────────────────────
  static int _parseId(dynamic v) =>
      v is int ? v : int.tryParse(v?.toString() ?? '0') ?? 0;

  // ═══════════════════════════════════════════════════════════════════════════
  //  CONNECT
  // ═══════════════════════════════════════════════════════════════════════════

  /// Call once after login.  Technicians start OFFLINE — call [goOnline] from
  /// the dashboard to enter the dispatch pool.
  void connect({
    required int    userId,
    required String role,
    required String name,
    int?    sessionId,
    int?    branchId,
    double? lat,
    double? lng,
  }) {
    if (_socket != null && _socket!.connected) {
      _log('CONNECT', 'already connected — skipping');
      return;
    }

    this.userId    = userId;
    userRole       = role;
    this.sessionId = sessionId;
    userName       = name;
    _branchId      = branchId;

    _socket = io.io(
      AppConstants.socketUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .setReconnectionAttempts(10)
          .setReconnectionDelay(2000)
          .build(),
    );

    _socket!.onConnect((_) {
      _connectedCtrl.add(true);
      _log('CONNECT', 'socket connected  role=$role userId=$userId');

      if (role == 'technician') {
        _handleTechnicianReconnect();
      } else if (role == 'driver') {
        _handleDriverReconnect();
      }
    });

    _socket!.onDisconnect((_) {
      _connectedCtrl.add(false);
      _log('DISCONNECT', 'socket disconnected');
    });

    _socket!.onReconnect((_) => _log('RECONNECT', 'socket reconnected'));

    _registerEventHandlers();
    _socket!.connect();

    // Fetch FCM token once per login so it's ready before the first goOnline().
    if (role == 'technician') {
      NotificationService.instance.loadToken();
    }
  }

  // ── Reconnect helpers ──────────────────────────────────────────────────────

  void _handleTechnicianReconnect() {
    if (!_isAvailable) {
      _log('RECONNECT', 'tech OFFLINE — no emit');
      return;
    }
    if (_isBusy) {
      // Mid-booking reconnect: skip registration.
      // emitCollectionCompleted() re-registers after the booking ends.
      _log('RECONNECT', 'tech BUSY (booking=$_activeBookingId) — skipping technician_online');
      return;
    }
    _emitTechnicianOnline();
    _log('RECONNECT', 're-registered ONLINE (lat=$_lastLat, lng=$_lastLng)');
  }

  void _handleDriverReconnect() {
    if (!_isDriverOnline) {
      _log('RECONNECT', 'driver OFFLINE — no emit');
      return;
    }
    if (_isBusy) {
      _log('RECONNECT', 'driver BUSY (booking=$_activeBookingId) — skipping driver_online');
      return;
    }
    _emitDriverOnline();
    _log('RECONNECT', 'driver re-registered ONLINE');
  }

  // ── Internal emit helpers (single call-site for each event) ───────────────

  void _emitTechnicianOnline() {
    _socket?.emit('technician_online', {
      'technicianId':   userId,
      'technicianName': userName,
      'sessionId':      sessionId,
      'branchId':       _branchId,
      'lat':            _lastLat,
      'lng':            _lastLng,
      if (_fcmToken != null) 'fcmToken': _fcmToken,
    });
    _log('ONLINE', 'emitted technician_online  branch=$_branchId lat=$_lastLat lng=$_lastLng');
  }

  void _emitTechnicianOffline() {
    _socket?.emit('technician_offline', {'technicianId': userId});
    _log('OFFLINE', 'emitted technician_offline');
  }

  void _emitDriverOnline() {
    _socket?.emit('driver_online', {
      'driverId':   userId,
      'driverName': userName,
      'lat':        _driverLat,
      'lng':        _driverLng,
    });
    _log('ONLINE', 'emitted driver_online  lat=$_driverLat lng=$_driverLng');
  }

  // ── Register all server→client event handlers ─────────────────────────────
  void _registerEventHandlers() {
    _socket!.on('session_started', (data) {
      sessionId = _parseId((data as Map)['sessionId']);
      _log('SESSION', 'session started  id=$sessionId');
    });

    _socket!.on('booking_request', (data) {
      try {
        final b = SocketBooking.fromJson(Map<String, dynamic>.from(data as Map));
        _log('EVENT', 'booking_request  id=${b.bookingId}');
        _bookingRequestCtrl.add(b);
      } catch (e) { _log('ERROR', 'booking_request: $e'); }
    });

    _socket!.on('booking_accepted', (data) {
      try {
        final e = BookingAcceptedEvent.fromJson(
            Map<String, dynamic>.from(data as Map));
        _log('EVENT', 'booking_accepted  id=${e.bookingId} tech=${e.technicianName}');
        _bookingAcceptedCtrl.add(e);
      } catch (e) { _log('ERROR', 'booking_accepted: $e'); }
    });

    _socket!.on('booking_cancelled', (data) {
      final id = _parseId((data as Map)['bookingId']);
      _log('EVENT', 'booking_cancelled  id=$id');
      _bookingCancelledCtrl.add(id);
    });

    _socket!.on('booking_timeout', (data) {
      final id = _parseId((data as Map)['bookingId']);
      _log('EVENT', 'booking_timeout  id=$id');
      _bookingTimeoutCtrl.add(id);
    });

    _socket!.on('location_update', (data) {
      try {
        _locationUpdateCtrl.add(
            LocationUpdate.fromJson(Map<String, dynamic>.from(data as Map)));
      } catch (e) { _log('ERROR', 'location_update: $e'); }
    });

    _socket!.on('technician_en_route', (data) {
      final id = _parseId((data as Map)['bookingId']);
      _techEnRouteCtrl.add(id);
      // Keep in-memory lab booking state fresh
      final current = activeLabBooking.value;
      if (current != null && current.bookingId == id) {
        activeLabBooking.value = current.copyWith(enRoute: true);
      }
    });

    _socket!.on('technician_arrived', (data) {
      final id = _parseId((data as Map)['bookingId']);
      _log('EVENT', 'technician_arrived  id=$id');
      _techArrivedCtrl.add(id);
      final current = activeLabBooking.value;
      if (current != null && current.bookingId == id) {
        activeLabBooking.value = current.copyWith(arrived: true);
      }
    });

    _socket!.on('collection_completed', (data) {
      final id = _parseId((data as Map)['bookingId']);
      _log('EVENT', 'collection_completed  id=$id');
      _collectionCompletedCtrl.add(id);
      final current = activeLabBooking.value;
      if (current != null && current.bookingId == id) {
        activeLabBooking.value = current.copyWith(collected: true);
      }
    });

    _socket!.on('collection_started', (data) {
      final id = _parseId((data as Map)['bookingId']);
      _log('EVENT', 'collection_started  id=$id');
      _collectionStartedCtrl.add(id);
    });

    _socket!.on('sample_collected', (data) {
      final id = _parseId((data as Map)['bookingId']);
      _log('EVENT', 'sample_collected  id=$id');
      _sampleCollectedCtrl.add(id);
    });

    _socket!.on('handed_to_lab', (data) {
      final id = _parseId((data as Map)['bookingId']);
      _log('EVENT', 'handed_to_lab  id=$id');
      _handedToLabCtrl.add(id);
      final current = activeLabBooking.value;
      if (current != null && current.bookingId == id) {
        activeLabBooking.value = current.copyWith(collected: true);
      }
    });

    _socket!.on('sample_received_at_lab', (data) {
      final id = _parseId((data as Map)['bookingId']);
      _sampleReceivedCtrl.add(id);
    });

    _socket!.on('test_in_progress', (data) {
      final id = _parseId((data as Map)['bookingId']);
      _testInProgressCtrl.add(id);
    });

    _socket!.on('report_ready', (data) {
      try {
        final e = ReportReadyEvent.fromJson(
            Map<String, dynamic>.from(data as Map));
        _log('EVENT', 'report_ready  id=${e.bookingId}');
        _reportReadyCtrl.add(e);
      } catch (e) { _log('ERROR', 'report_ready: $e'); }
    });

    _socket!.on('driver_arrived', (data) {
      final id = _parseId((data as Map)['bookingId']);
      _log('EVENT', 'driver_arrived  id=$id');
      _driverArrivedCtrl.add(id);
    });

    _socket!.on('trip_completed', (data) {
      final id = _parseId((data as Map)['bookingId']);
      _log('EVENT', 'trip_completed  id=$id');
      _tripCompletedCtrl.add(id);
      // Clear active ride once the trip is done
      if (activeRide.value?.bookingId == id) clearActiveRide();
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  ACTIVE BOOKING STATE  (in-memory persistence across navigations)
  // ═══════════════════════════════════════════════════════════════════════════

  void setActiveLabBooking(ActiveLabBookingInfo info) {
    activeLabBooking.value = info;
    _log('STATE', 'activeLabBooking set  id=${info.bookingId}');
  }

  void clearActiveLabBooking() {
    activeLabBooking.value = null;
    _log('STATE', 'activeLabBooking cleared');
  }

  void setActiveRide(ActiveRideInfo info) {
    activeRide.value = info;
    _log('STATE', 'activeRide set  id=${info.bookingId}');
  }

  void clearActiveRide() {
    activeRide.value = null;
    _log('STATE', 'activeRide cleared');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  TECHNICIAN AVAILABILITY  (Online / Offline toggle)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Toggle technician Online.  Idempotent — repeated taps are ignored.
  void goOnline({required double lat, required double lng}) {
    if (_isAvailable) {
      _log('ONLINE', 'already online — duplicate tap ignored');
      return;
    }
    _isAvailable = true;
    _lastLat     = lat;
    _lastLng     = lng;
    _availabilityCtrl.add(true);
    _log('AVAILABILITY', 'state → ONLINE  lat=$lat lng=$lng');

    if (!isConnected) {
      _log('ONLINE', 'socket not connected — state queued, will emit on connect');
      return;
    }
    _emitTechnicianOnline();
  }

  /// Toggle technician Offline.  Idempotent — repeated taps are ignored.
  void goOffline() {
    if (!_isAvailable) {
      _log('OFFLINE', 'already offline — duplicate tap ignored');
      return;
    }
    _isAvailable = false;
    _availabilityCtrl.add(false);
    _log('AVAILABILITY', 'state → OFFLINE');

    if (!isConnected) {
      _log('OFFLINE', 'socket not connected — state updated locally');
      return;
    }
    _emitTechnicianOffline();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  DRIVER AVAILABILITY
  // ═══════════════════════════════════════════════════════════════════════════

  /// Toggle driver Online.  Idempotent — repeated taps are ignored.
  void goDriverOnline({required double lat, required double lng}) {
    if (_isDriverOnline) {
      _log('ONLINE', 'driver already online — duplicate tap ignored');
      return;
    }
    _isDriverOnline = true;
    _driverLat      = lat;
    _driverLng      = lng;
    _log('AVAILABILITY', 'driver state → ONLINE  lat=$lat lng=$lng');
    if (!isConnected) {
      _log('ONLINE', 'socket not connected — driver state queued');
      return;
    }
    _emitDriverOnline();
  }

  /// Toggle driver Offline.  Idempotent — repeated taps are ignored.
  void goDriverOffline() {
    if (!_isDriverOnline) {
      _log('OFFLINE', 'driver already offline — duplicate tap ignored');
      return;
    }
    _isDriverOnline = false;
    _log('AVAILABILITY', 'driver state → OFFLINE');
    if (!isConnected) return;
    _socket?.emit('driver_offline', {'driverId': userId});
    _log('OFFLINE', 'emitted driver_offline');
  }

  // ── Backward-compatible aliases (driver_request_screen uses these names) ───
  void emitDriverOnline({required double lat, required double lng}) =>
      goDriverOnline(lat: lat, lng: lng);

  void emitDriverOffline() => goDriverOffline();

  void emitDriverIdleLocation({
    required double lat,
    required double lng,
    double? speed,
    double? bearing,
  }) {
    _driverLat = lat;
    _driverLng = lng;
    _socket?.emit('update_driver_location', {
      'driverId': userId,
      'lat':      lat,
      'lng':      lng,
      'speed':    speed,
      'bearing':  bearing,
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  DISCONNECT  (logout)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Check [hasActiveBooking] before calling — warn user if a booking is live.
  void disconnect() {
    if (_socket == null) return;

    if (_isBusy) {
      _log('DISCONNECT', 'WARNING — active booking=$_activeBookingId at logout');
    }
    if (userRole == 'technician' && _isAvailable && isConnected) {
      _emitTechnicianOffline();
    } else if (userRole == 'driver' && _isDriverOnline && isConnected) {
      _socket?.emit('driver_offline', {'driverId': userId});
      _log('OFFLINE', 'emitted driver_offline on disconnect');
    }

    _socket!.disconnect();
    _socket!.dispose();
    _socket = null;

    _isAvailable     = false;
    _isBusy          = false;
    _activeBookingId = null;
    _lastLat         = null;
    _lastLng         = null;
    _branchId        = null;
    _isDriverOnline  = false;
    _driverLat       = null;
    _driverLng       = null;

    _log('DISCONNECT', 'socket disposed and state reset');
  }

  /// Call only at app shutdown.  Closes all streams permanently.
  void dispose() {
    disconnect();
    _bookingRequestCtrl.close();
    _bookingAcceptedCtrl.close();
    _bookingCancelledCtrl.close();
    _bookingTimeoutCtrl.close();
    _locationUpdateCtrl.close();
    _techEnRouteCtrl.close();
    _techArrivedCtrl.close();
    _collectionCompletedCtrl.close();
    _collectionStartedCtrl.close();
    _sampleCollectedCtrl.close();
    _handedToLabCtrl.close();
    _sampleReceivedCtrl.close();
    _testInProgressCtrl.close();
    _reportReadyCtrl.close();
    _driverArrivedCtrl.close();
    _tripCompletedCtrl.close();
    _connectedCtrl.close();
    _availabilityCtrl.close();
    _log('DISPOSE', 'all StreamControllers closed');
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  CUSTOMER / PATIENT  emits
  // ═══════════════════════════════════════════════════════════════════════════

  void emitBookingRequest({
    required int    bookingId,
    required int    patientId,
    required String patientName,
    String  patientMobile  = '',
    String  patientAddress = '',
    double? patientLat,
    double? patientLng,
    required String hospital,
    String  bookingType = 'lab',
    int?    branchId,
    String? branchName,
  }) {
    _socket?.emit('booking_request', {
      'bookingId':      bookingId,
      'patientId':      patientId,
      'patientName':    patientName,
      'patientMobile':  patientMobile,
      'patientAddress': patientAddress,
      'patientLat':     patientLat,
      'patientLng':     patientLng,
      'hospital':       hospital,
      'bookingType':    bookingType,
      if (branchId   != null) 'branchId':   branchId,
      if (branchName != null) 'branchName': branchName,
    });
    _log('EMIT', 'booking_request  id=$bookingId type=$bookingType branch=$branchId ($branchName)');
  }

  /// Transport booking request — [bookingId] may be a String or int.
  void emitRideBookingRequest({
    required dynamic bookingId,
    required int     patientId,
    required String  patientName,
    String  patientMobile  = '',
    String  patientAddress = '',
    double? patientLat,
    double? patientLng,
    required String hospital,
  }) {
    final id = _parseId(bookingId);
    _socket?.emit('booking_request', {
      'bookingId':      id,
      'patientId':      patientId,
      'patientName':    patientName,
      'patientMobile':  patientMobile,
      'patientAddress': patientAddress,
      'patientLat':     patientLat,
      'patientLng':     patientLng,
      'hospital':       hospital,
      'bookingType':    'transport',
    });
    _log('EMIT', 'emitRideBookingRequest  id=$id');
  }

  void registerPatientSocket({required int patientId, required int bookingId}) {
    _socket?.emit('register_patient_socket', {
      'patientId': patientId,
      'bookingId': bookingId,
    });
  }

  void joinTracking(String trackingId) {
    _socket?.emit('join_tracking', {'trackingId': trackingId});
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  TECHNICIAN  emits
  // ═══════════════════════════════════════════════════════════════════════════

  /// Accept a booking.  Sets [_isBusy]=true so reconnect logic and the logout
  /// guard both know an active booking exists.
  void emitBookingAccepted({
    required int    bookingId,
    required int    technicianId,
    required String technicianName,
    int? sessionId,
  }) {
    _isBusy          = true;
    _activeBookingId = bookingId;
    _log('BOOKING_ACCEPTED', 'id=$bookingId — marked BUSY');

    _socket?.emit('booking_accepted', {
      'bookingId':      bookingId,
      'technicianId':   technicianId,
      'technicianName': technicianName,
      'sessionId':      sessionId,
      'trackingId':     bookingId.toString(),
    });
  }

  /// Reject a booking (active decline — tech saw the request and said no).
  void emitBookingRejected({required int bookingId, required int technicianId}) {
    _socket?.emit('booking_rejected', {
      'bookingId':    bookingId,
      'technicianId': technicianId,
    });
    _log('EMIT', 'booking_rejected  id=$bookingId');
  }

  void emitEnRoute({required int bookingId}) {
    _socket?.emit('technician_en_route', {
      'bookingId':    bookingId,
      'technicianId': userId,
    });
  }

  void emitArrived({required int bookingId}) {
    _socket?.emit('technician_arrived', {
      'bookingId':    bookingId,
      'technicianId': userId,
    });
  }

  /// Complete a booking (legacy — kept for backward compatibility with old app builds).
  void emitCollectionCompleted({required int bookingId}) {
    _isBusy          = false;
    _activeBookingId = null;
    _log('BOOKING_COMPLETED', 'id=$bookingId — marked AVAILABLE');

    _socket?.emit('collection_completed', {
      'bookingId':    bookingId,
      'technicianId': userId,
    });

    if (_isAvailable && isConnected && _lastLat != null) {
      _emitTechnicianOnline();
      _log('BOOKING_COMPLETED', 're-emitted technician_online');
    }
    _availabilityCtrl.add(_isAvailable);
  }

  void emitCollectionStarted({required int bookingId}) {
    _socket?.emit('collection_started', {
      'bookingId':    bookingId,
      'technicianId': userId,
    });
    _log('EMIT', 'collection_started  id=$bookingId');
  }

  void emitSampleCollected({required int bookingId}) {
    _socket?.emit('sample_collected', {
      'bookingId':    bookingId,
      'technicianId': userId,
    });
    _log('EMIT', 'sample_collected  id=$bookingId');
  }

  /// Final technician step.  Stores [completed_at] in DB, frees the technician.
  void emitHandedToLab({required int bookingId}) {
    _isBusy          = false;
    _activeBookingId = null;
    _log('HANDED_TO_LAB', 'id=$bookingId — marked AVAILABLE');

    _socket?.emit('handed_to_lab', {
      'bookingId':    bookingId,
      'technicianId': userId,
    });

    if (_isAvailable && isConnected && _lastLat != null) {
      _emitTechnicianOnline();
      _log('HANDED_TO_LAB', 're-emitted technician_online');
    }
    _availabilityCtrl.add(_isAvailable);
  }

  /// Location relay during active tracking (technician → patient).
  void emitLocation({
    required String trackingId,
    required int    bookingId,
    required double lat,
    required double lng,
    double? accuracy,
    double? speed,
    double? bearing,
    int?    batteryLevel,
    String? networkType,
    String? addressLabel,
  }) {
    _lastLat = lat;
    _lastLng = lng;
    _socket?.emit('send_location', {
      'trackingId':   trackingId,
      'technicianId': userId,
      'sessionId':    sessionId,
      'bookingId':    bookingId,
      'lat':          lat,
      'lng':          lng,
      'accuracy':     accuracy,
      'speed':        speed,
      'bearing':      bearing,
      'batteryLevel': batteryLevel,
      'networkType':  networkType,
      'addressLabel': addressLabel,
    });
  }

  /// Idle location ping (30 s interval while Online but not on a job).
  void emitIdleLocation({
    required double lat,
    required double lng,
    double? accuracy,
    double? speed,
    double? bearing,
    int?    batteryLevel,
    String? networkType,
  }) {
    _lastLat = lat;
    _lastLng = lng;
    _socket?.emit('update_technician_location', {
      'technicianId': userId,
      'sessionId':    sessionId,
      'lat':          lat,
      'lng':          lng,
      'accuracy':     accuracy,
      'speed':        speed,
      'bearing':      bearing,
      'batteryLevel': batteryLevel,
      'networkType':  networkType,
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  DRIVER  emits
  // ═══════════════════════════════════════════════════════════════════════════

  /// Active decline — driver dismissed the request with the Decline button.
  /// [bookingId] accepts both int and String.
  void emitBookingDeclined({required dynamic bookingId, int? driverId}) {
    _socket?.emit('booking_declined', {
      'bookingId': _parseId(bookingId),
      'driverId':  driverId ?? userId,
    });
    _log('EMIT', 'booking_declined  id=$bookingId');
  }

  /// Accept a transport booking.
  /// [bookingId] accepts both int and String.
  void emitRideBookingAccepted({
    required dynamic bookingId,
    required int     driverId,
    required String  driverName,
  }) {
    final id = _parseId(bookingId);
    _isBusy          = true;
    _activeBookingId = id;
    _log('BOOKING_ACCEPTED', 'driver id=$id — marked BUSY');

    _socket?.emit('booking_accepted', {
      'bookingId':  id,
      'driverId':   driverId,
      'driverName': driverName,
      'trackingId': id.toString(),
    });
  }

  // Alias kept for compatibility with older callers.
  void emitDriverBookingAccepted({
    required dynamic bookingId,
    required int     driverId,
    required String  driverName,
  }) => emitRideBookingAccepted(
        bookingId:  bookingId,
        driverId:   driverId,
        driverName: driverName,
      );

  /// [bookingId] accepts both int and String.
  void emitDriverArrived({required dynamic bookingId, int? driverId}) {
    _socket?.emit('driver_arrived', {
      'bookingId': _parseId(bookingId),
      'driverId':  driverId ?? userId,
    });
  }

  /// Complete a transport trip.
  /// Clears [_isBusy] and re-emits [driver_online] if still toggled Online.
  /// [bookingId] accepts both int and String.
  void emitTripCompleted({required dynamic bookingId, int? driverId}) {
    final id = _parseId(bookingId);
    _isBusy          = false;
    _activeBookingId = null;
    _log('BOOKING_COMPLETED', 'driver id=$id — marked AVAILABLE');

    _socket?.emit('trip_completed', {
      'bookingId': id,
      'driverId':  driverId ?? userId,
    });

    if (_isDriverOnline && isConnected) {
      _emitDriverOnline();
      _log('BOOKING_COMPLETED', 're-emitted driver_online after trip');
    }
  }

  /// Location relay during active ride (driver → patient).
  /// [trackingId] and [bookingId] accept both int and String.
  void emitDriverLocation({
    required dynamic trackingId,
    required dynamic bookingId,
    required double  lat,
    required double  lng,
    double? speed,
    double? bearing,
    double? accuracy,
    int?    driverId,
  }) {
    _driverLat = lat;
    _driverLng = lng;
    _socket?.emit('send_location', {
      'trackingId': trackingId.toString(),
      'driverId':   driverId ?? userId,
      'bookingId':  _parseId(bookingId),
      'lat':        lat,
      'lng':        lng,
      'speed':      speed,
      'bearing':    bearing,
      'accuracy':   accuracy,
      'isPatient':  false,
    });
  }
}
