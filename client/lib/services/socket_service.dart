import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '../constants/app_constants.dart';

// ─── Data models for socket events ────────────────────────────────────────────

class SocketBooking {
  final int bookingId;
  final int patientId;
  final String patientName;
  final String patientMobile;
  final String patientAddress;
  final double? patientLat;
  final double? patientLng;
  final String hospital;
  final DateTime createdAt;

  SocketBooking({
    required this.bookingId,
    required this.patientId,
    required this.patientName,
    required this.patientMobile,
    required this.patientAddress,
    this.patientLat,
    this.patientLng,
    required this.hospital,
    required this.createdAt,
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
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ??
            DateTime.now(),
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
        technicianId:   SocketBooking._toInt(j['technicianId']),
        technicianName: j['technicianName'] as String? ?? '',
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

// ─── SocketService singleton ───────────────────────────────────────────────────

class SocketService {
  SocketService._internal();
  static final SocketService instance = SocketService._internal();

  io.Socket? _socket;

  // Current user — set on connect
  int userId = 0;
  String userRole = ''; // 'technician' | 'customer'
  int? sessionId;
  String userName = '';

  // ── Event streams ──────────────────────────────────────────────────────────
  final _bookingRequestCtrl     = StreamController<SocketBooking>.broadcast();
  final _bookingAcceptedCtrl    = StreamController<BookingAcceptedEvent>.broadcast();
  final _bookingCancelledCtrl   = StreamController<int>.broadcast();
  final _bookingTimeoutCtrl     = StreamController<int>.broadcast();
  final _locationUpdateCtrl     = StreamController<LocationUpdate>.broadcast();
  final _techArrivedCtrl        = StreamController<int>.broadcast();
  final _collectionCompletedCtrl= StreamController<int>.broadcast();
  final _connectedCtrl          = StreamController<bool>.broadcast();

  Stream<SocketBooking>        get onBookingRequest      => _bookingRequestCtrl.stream;
  Stream<BookingAcceptedEvent> get onBookingAccepted     => _bookingAcceptedCtrl.stream;
  Stream<int>                  get onBookingCancelled    => _bookingCancelledCtrl.stream;
  Stream<int>                  get onBookingTimeout      => _bookingTimeoutCtrl.stream;
  Stream<LocationUpdate>       get onLocationUpdate      => _locationUpdateCtrl.stream;
  Stream<int>                  get onTechnicianArrived   => _techArrivedCtrl.stream;
  Stream<int>                  get onCollectionCompleted => _collectionCompletedCtrl.stream;
  Stream<bool>                 get onConnected           => _connectedCtrl.stream;

  bool get isConnected => _socket?.connected ?? false;

  // ── Connect ────────────────────────────────────────────────────────────────
  void connect({
    required int userId,
    required String role,
    required String name,
    int? sessionId,
    double? lat,
    double? lng,
  }) {
    if (_socket != null && _socket!.connected) return; // already connected

    this.userId    = userId;
    this.userRole  = role;
    this.sessionId = sessionId;
    this.userName  = name;

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
      if (role == 'technician') {
        _socket!.emit('technician_online', {
          'technicianId': userId,
          'technicianName': name,
          'sessionId': sessionId,
          'lat': lat,
          'lng': lng,
        });
      }
    });

    _socket!.onDisconnect((_) => _connectedCtrl.add(false));

    _socket!.on('booking_request', (data) {
      try {
        _bookingRequestCtrl
            .add(SocketBooking.fromJson(Map<String, dynamic>.from(data as Map)));
      } catch (_) {}
    });

    _socket!.on('booking_accepted', (data) {
      try {
        _bookingAcceptedCtrl.add(
            BookingAcceptedEvent.fromJson(Map<String, dynamic>.from(data as Map)));
      } catch (_) {}
    });

    _socket!.on('booking_cancelled', (data) {
      final id = SocketBooking._toInt((data as Map)['bookingId']);
      _bookingCancelledCtrl.add(id);
    });

    _socket!.on('booking_timeout', (data) {
      final id = SocketBooking._toInt((data as Map)['bookingId']);
      _bookingTimeoutCtrl.add(id);
    });

    _socket!.on('location_update', (data) {
      try {
        _locationUpdateCtrl
            .add(LocationUpdate.fromJson(Map<String, dynamic>.from(data as Map)));
      } catch (_) {}
    });

    _socket!.on('technician_arrived', (data) {
      final id = SocketBooking._toInt((data as Map)['bookingId']);
      _techArrivedCtrl.add(id);
    });

    _socket!.on('collection_completed', (data) {
      final id = SocketBooking._toInt((data as Map)['bookingId']);
      _collectionCompletedCtrl.add(id);
    });

    _socket!.connect();
  }

  // ── Disconnect ─────────────────────────────────────────────────────────────
  void disconnect() {
    if (_socket == null) return;
    if (userRole == 'technician') {
      _socket!.emit('technician_offline', {'technicianId': userId});
    }
    _socket!.disconnect();
    _socket!.dispose();
    _socket = null;
  }

  // ── Customer emits ─────────────────────────────────────────────────────────

  void emitBookingRequest({
    required int bookingId,
    required int patientId,
    required String patientName,
    String patientMobile = '',
    String patientAddress = '',
    double? patientLat,
    double? patientLng,
    required String hospital,
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
    });
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

  // ── Technician emits ───────────────────────────────────────────────────────

  void emitBookingAccepted({
    required int bookingId,
    required int technicianId,
    required String technicianName,
    int? sessionId,
  }) {
    _socket?.emit('booking_accepted', {
      'bookingId':      bookingId,
      'technicianId':   technicianId,
      'technicianName': technicianName,
      'sessionId':      sessionId,
      'trackingId':     bookingId.toString(),
    });
  }

  void emitBookingRejected({required int bookingId, required int technicianId}) {
    _socket?.emit('booking_rejected', {
      'bookingId':    bookingId,
      'technicianId': technicianId,
    });
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

  void emitCollectionCompleted({required int bookingId}) {
    _socket?.emit('collection_completed', {
      'bookingId':    bookingId,
      'technicianId': userId,
    });
  }

  void emitLocation({
    required String trackingId,
    required int bookingId,
    required double lat,
    required double lng,
    double? accuracy,
    double? speed,
    double? bearing,
    int? batteryLevel,
    String? networkType,
    String? addressLabel,
  }) {
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

  void emitIdleLocation({
    required double lat,
    required double lng,
    double? accuracy,
    double? speed,
    double? bearing,
    int? batteryLevel,
    String? networkType,
  }) {
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
}
