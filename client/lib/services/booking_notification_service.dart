import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_constants.dart';
import 'socket_service.dart';

@pragma('vm:keep')
void onBackgroundNotificationAction(NotificationResponse response) {}

// ─── BookingNotificationService ───────────────────────────────────────────────

class BookingNotificationService {
  BookingNotificationService._();
  static final BookingNotificationService instance = BookingNotificationService._();

  static const _channelId     = 'booking_requests';
  static const _channelName   = 'Booking Requests';
  static const _actionAccept  = 'accept_booking';
  static const _actionDecline = 'decline_booking';

  // How close together two deliveries must be to count as a duplicate.
  // Socket.IO + FCM both fire for the same booking within ~1 second.
  // Server retries fire 43 seconds later — well outside this window.
  static const _dedupSeconds = 5;

  final _plugin = FlutterLocalNotificationsPlugin();

  // ── Overlay tracking ───────────────────────────────────────────────────────
  // bookingIds currently being displayed in the in-app overlay.
  // Prevents FCM from showing a notification while the overlay is already open.
  // Separate from notification dedup — overlay and notification are two
  // different UI paths and need independent guards.
  final _overlayIds = <int>{};

  // ── Notification dedup ─────────────────────────────────────────────────────
  // Timestamp of the last time we showed a notification for each bookingId.
  // Replaces the old permanent _activeIds Set — the key difference:
  //   OLD: once shown, NEVER shown again for the same bookingId
  //         → server retries (attempt 2, 3) were silently blocked ✗
  //   NEW: shown again if more than _dedupSeconds have passed
  //         → socket+FCM double delivery (~1s apart) blocked ✓
  //         → server retry (43s later) allowed through ✓
  final _lastShownAt = <int, DateTime>{};

  // ── Pending state ──────────────────────────────────────────────────────────
  SocketBooking? _pendingAccept;
  SocketBooking? _pendingBackgroundBooking;

  // ── booking_cancelled subscription ────────────────────────────────────────
  StreamSubscription<int>? _cancelSub;

  // ── Accept stream ──────────────────────────────────────────────────────────
  final _acceptedCtrl = StreamController<SocketBooking>.broadcast();
  Stream<SocketBooking> get onAccepted => _acceptedCtrl.stream;

  // ── Init ───────────────────────────────────────────────────────────────────
  // Called once from main() after NotificationService.initialize().
  // Subscribes to booking_cancelled so stale pending state is cleared
  // when the server exhausts all 3 attempts and moves to the next technician.
  void init() {
    _cancelSub?.cancel();
    _cancelSub = SocketService.instance.onBookingCancelled.listen(_onServerCancelled);
    _log('init() — listening to booking_cancelled');
  }

  // Server sent booking_cancelled for this bookingId — all 3 attempts exhausted
  // and the booking has been reassigned to the next technician.
  // Clear everything so the tech cannot accept a booking that is no longer theirs.
  void _onServerCancelled(int bookingId) {
    _log('booking_cancelled received — #$bookingId — clearing pending state');

    if (_pendingBackgroundBooking?.bookingId == bookingId) {
      _pendingBackgroundBooking = null;
    }
    _lastShownAt.remove(bookingId);
    _plugin.cancel(bookingId); // remove from notification drawer if still showing
  }

  // ── Overlay guards ─────────────────────────────────────────────────────────

  void markOverlayHandling(int bookingId) => _overlayIds.add(bookingId);

  void clearOverlayHandling(int bookingId) => _overlayIds.remove(bookingId);

  // ── Pending accept ─────────────────────────────────────────────────────────

  SocketBooking? consumePendingAccept() {
    final b = _pendingAccept;
    _pendingAccept = null;
    return b;
  }

  // ── Pending background booking ─────────────────────────────────────────────

  void setPendingBackgroundBooking(SocketBooking booking) {
    _pendingBackgroundBooking = booking;
  }

  SocketBooking? consumePendingBackgroundBooking() {
    final b = _pendingBackgroundBooking;
    _pendingBackgroundBooking = null;
    return b;
  }

  // Reads any booking saved by the FCM background isolate via SharedPreferences
  // and promotes it to _pendingBackgroundBooking so the main isolate can show it.
  // Call this on app resume / cold start before calling consumePendingBackgroundBooking.
  Future<void> checkAndSetFcmPendingBooking() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('pending_fcm_booking');
      if (raw == null || raw.isEmpty) return;
      await prefs.remove('pending_fcm_booking');
      final booking = SocketBooking.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      _pendingBackgroundBooking ??= booking;
      _log('FCM prefs booking promoted — #${booking.bookingId}');
    } catch (e) {
      _log('checkAndSetFcmPendingBooking error: $e');
    }
  }

  // ── Show notification ──────────────────────────────────────────────────────

  Future<void> showBookingNotification(SocketBooking booking) async {
    // 1. Block if the overlay is already showing this booking.
    if (_overlayIds.contains(booking.bookingId)) return;

    // 2. Short-term dedup: block if shown within the last _dedupSeconds.
    //    This stops socket + FCM delivering the same event twice within ~1s.
    //    Server retries arrive 43s later → NOT blocked → notification re-shows. ✓
    final last = _lastShownAt[booking.bookingId];
    if (last != null &&
        DateTime.now().difference(last).inSeconds < _dedupSeconds) {
      _log('Deduped (${DateTime.now().difference(last).inSeconds}s ago) — booking #${booking.bookingId}');
      return;
    }
    _lastShownAt[booking.bookingId] = DateTime.now();

    final name    = booking.patientName.isEmpty ? 'Patient' : booking.patientName;
    final address = booking.patientAddress.isEmpty ? 'Location pending' : booking.patientAddress;

    final payload = jsonEncode({
      'bookingId':      booking.bookingId,
      'patientId':      booking.patientId,
      'patientName':    booking.patientName,
      'patientMobile':  booking.patientMobile,
      'patientAddress': booking.patientAddress,
      'patientLat':     booking.patientLat,
      'patientLng':     booking.patientLng,
      'hospital':       booking.hospital,
      'bookingType':    booking.bookingType,
      'branchId':       booking.branchId,
      'branchName':     booking.branchName,
      'createdAt':      booking.createdAt.toIso8601String(),
    });

    await _plugin.show(
      booking.bookingId,
      'New Booking Request',
      '$name · #${booking.bookingId}',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          timeoutAfter: AppConstants.bookingRequestTimeoutSeconds * 1000,
          styleInformation: BigTextStyleInformation(
            '$name · Booking #${booking.bookingId}\n'
            '📍 $address\n'
            '🕐 ${formatBookingTime(booking.createdAt)}',
          ),
          actions: const [
            AndroidNotificationAction(
              _actionAccept,
              'Accept',
              showsUserInterface: true,
              cancelNotification: true,
            ),
            AndroidNotificationAction(
              _actionDecline,
              'Decline',
              showsUserInterface: true,
              cancelNotification: true,
            ),
          ],
        ),
      ),
      payload: payload,
    );
    _log('Shown — booking #${booking.bookingId}');
  }

  void cancelBookingNotification(int bookingId) {
    _lastShownAt.remove(bookingId);
    _plugin.cancel(bookingId);
  }

  // ── Handle notification action ─────────────────────────────────────────────

  void handleNotificationAction(NotificationResponse response) {
    final bookingId = response.id ?? 0;
    _log('Action — id=$bookingId  action=${response.actionId}');

    SocketBooking? booking;
    try {
      if (response.payload?.isNotEmpty == true) {
        booking = SocketBooking.fromJson(
          jsonDecode(response.payload!) as Map<String, dynamic>,
        );
      }
    } catch (e) {
      _log('Payload parse error: $e');
      return;
    }
    if (booking == null) return;

    if (response.actionId == _actionAccept) {
      // ── Accept button ─────────────────────────────────────────────────────
      if (_pendingBackgroundBooking?.bookingId == bookingId) {
        _pendingBackgroundBooking = null;
      }
      _lastShownAt.remove(bookingId);
      void doEmit() {
        SocketService.instance.emitBookingAccepted(
          bookingId:      booking!.bookingId,
          technicianId:   SocketService.instance.userId,
          technicianName: SocketService.instance.userName,
          sessionId:      SocketService.instance.sessionId,
        );
      }
      if (SocketService.instance.isConnected) {
        doEmit();
      } else {
        // Socket is down (common when app is backgrounded) — queue the emit
        // for when the socket reconnects so the server receives the accept.
        SocketService.instance.onConnected
            .where((connected) => connected)
            .take(1)
            .listen((_) => doEmit());
      }
      if (_acceptedCtrl.hasListener) {
        _acceptedCtrl.add(booking);
      } else {
        _pendingAccept = booking;
      }
    } else if (response.actionId == _actionDecline) {
      // ── Decline button ────────────────────────────────────────────────────
      if (_pendingBackgroundBooking?.bookingId == bookingId) {
        _pendingBackgroundBooking = null;
      }
      _lastShownAt.remove(bookingId);
      void doEmit() {
        SocketService.instance.emitBookingRejected(
          bookingId:    booking!.bookingId,
          technicianId: SocketService.instance.userId,
        );
      }
      if (SocketService.instance.isConnected) {
        doEmit();
      } else {
        // Socket is down (common when app is backgrounded) — queue the emit
        // for when the socket reconnects so the server actually receives the
        // decline. Without this, a decline tapped while disconnected is lost
        // silently: the server just times out and retries this same
        // technician instead of moving to the next one.
        SocketService.instance.onConnected
            .where((connected) => connected)
            .take(1)
            .listen((_) => doEmit());
      }
    } else {
      // ── Body tap — open app, show overlay, do not accept/decline ──────────
      _pendingBackgroundBooking ??= booking;
    }
  }

  static void _log(String msg) {
    if (kDebugMode) {
      debugPrint('${DateTime.now().toIso8601String().substring(11, 23)} [BNS] $msg');
    }
  }
}

// ─── Shared time formatter ────────────────────────────────────────────────────

String formatBookingTime(DateTime dt) {
  final hour = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
  final min  = dt.minute.toString().padLeft(2, '0');
  final ampm = dt.hour >= 12 ? 'PM' : 'AM';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${dt.day} ${months[dt.month - 1]}, $hour:$min $ampm';
}
