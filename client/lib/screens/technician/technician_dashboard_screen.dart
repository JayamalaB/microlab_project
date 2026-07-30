import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/services/auth_service.dart';
import 'package:microlab/services/battery_service.dart';
import 'package:microlab/services/foreground_service.dart';
import 'package:microlab/models/technician_booking.dart';
import 'technician_booking_detail_screen.dart';
import 'technician_history_screen.dart';
import 'technician_slot_screen.dart';
import 'technician_profile_screen.dart';
import 'booking_request_overlay.dart';
import 'package:microlab/services/booking_notification_service.dart';
import 'technician_active_job_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/screens/shared/onboarding_screen.dart';
import 'package:url_launcher/url_launcher.dart';

// ─── Technician Dashboard Screen ──────────────────────────────────────────────

class TechnicianDashboardScreen extends StatefulWidget {
  final String mobile;
  const TechnicianDashboardScreen({super.key, required this.mobile});

  @override
  State<TechnicianDashboardScreen> createState() =>
      _TechnicianDashboardScreenState();
}

class _TechnicianDashboardScreenState extends State<TechnicianDashboardScreen>
    with WidgetsBindingObserver {
  int _selectedIndex = 0;

  // Mock bookings — replace with GET /api/technician/bookings
  late List<TechnicianBooking> _bookings;

  StreamSubscription<SocketBooking>? _bookingRequestSub;
  StreamSubscription<SocketBooking>? _bookingNotifAcceptSub;
  bool _overlayOpen = false;
  int  _sessionRequestCount = 0;

  // Availability — technician starts Offline after login
  bool _isOnline = false;
  bool _isTogglingOnline = false;
  bool _isRefreshing = false;
  StreamSubscription<Position>? _locationSub;
  Timer? _refreshTimer;

  // ✅ FIXED: Cache pending bookings to avoid rebuilding on every access
  List<TechnicianBooking>? _cachedPending;

  @override
  void initState() {
    super.initState();
    _loadMockData();
    // Sync local flag from the singleton so that if this widget is recreated
    // (hot-reload, navigation stack rebuild) while the tech is already online,
    // incoming booking_request events are not silently dropped by the
    // !_isOnline guard in _listenToSocket.
    _isOnline = SocketService.instance.isAvailable;
    if (_isOnline) _startLocationStream();
    _listenToSocket();
    _checkNotificationPendingAccept();
    WidgetsBinding.instance.addObserver(this);
    // If the app was killed while the tech was online, restore their online
    // state silently — same as Uber/Rapido auto-reconnect on cold start.
    if (!_isOnline) _checkAndRestoreOnlineState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;

    debugPrint('[LIFECYCLE] App resumed from background');

    // 1. Reconnect socket if it dropped while suspended.
    //    socket.io has its own backoff retry, but triggering reconnect
    //    immediately gives a faster recovery after the screen unlocks.
    if (!SocketService.instance.isConnected) {
      debugPrint('[LIFECYCLE] Socket disconnected — reconnecting immediately');
      SocketService.instance.reconnect();
    } else {
      debugPrint('[LIFECYCLE] Socket Connected ✓');
    }

    // 2. If the technician was online but OEM battery management killed the
    //    foreground service while the screen was off, restart it silently.
    //    The technician's online status is still stored in SocketService,
    //    so the socket reconnect above will re-emit technician_online.
    if (_isOnline && !kIsWeb) {
      ForegroundService.instance.isRunning.then((running) {
        if (!running && mounted) {
          debugPrint('[LIFECYCLE] Foreground Service Stopped by OEM — restarting...');
          ForegroundService.instance.start().then((ok) {
            debugPrint('[LIFECYCLE] Service restart: ${ok ? "Success ✓" : "Failed ❌"}');
          });
        } else {
          debugPrint('[LIFECYCLE] Service Running ✓');
        }
      });
    }

    // 3. If a booking arrived while the screen was off, a notification was shown
    //    but the overlay never appeared. Now that the tech is back in the app
    //    (via app icon, not the notification), show the overlay so they can
    //    still Accept or Decline within the 40-second server window.
    //    First drain any booking the FCM background isolate persisted to
    //    SharedPreferences — that isolate cannot write to main-isolate memory.
    BookingNotificationService.instance
        .checkAndSetFcmPendingBooking()
        .then((_) => _showPendingBackgroundBooking());
  }

  void _showPendingBackgroundBooking() {
    if (!mounted || _overlayOpen || !_isOnline) return;
    final booking =
        BookingNotificationService.instance.consumePendingBackgroundBooking();
    if (booking == null) return;

    // The booking may have already timed out or been accepted by another
    // technician while this device was offline/killed — booking_cancelled only
    // reaches a live socket, so a killed app never received it. Verify with the
    // server before resurfacing a possibly-stale request.
    _verifyAndShowPendingBooking(booking);
  }

  Future<void> _verifyAndShowPendingBooking(SocketBooking booking) async {
    final stillPending = await SocketService.instance.checkPendingBooking(
      bookingId:    booking.bookingId,
      technicianId: SocketService.instance.userId,
    );
    if (!mounted || _overlayOpen || !_isOnline) return;
    if (!stillPending) {
      debugPrint('[LIFECYCLE] Pending booking #${booking.bookingId} — stale (already resolved), discarding');
      BookingNotificationService.instance.cancelBookingNotification(booking.bookingId);
      return;
    }

    debugPrint('[LIFECYCLE] Pending booking #${booking.bookingId} — showing overlay');
    // Dismiss the notification since the overlay now takes over as the primary UI.
    BookingNotificationService.instance
        .cancelBookingNotification(booking.bookingId);

    _overlayOpen = true;
    _sessionRequestCount++;
    ForegroundService.instance.updateText('New booking request');
    BookingNotificationService.instance.markOverlayHandling(booking.bookingId);
    showBookingRequestOverlay(context, booking, _sessionRequestCount)
        .then((accepted) {
      _overlayOpen = false;
      BookingNotificationService.instance
          .clearOverlayHandling(booking.bookingId);
      if (!mounted) return;
      if (!accepted) {
        ForegroundService.instance.updateText('Ready for booking requests');
        return;
      }
      _onBookingAccepted(booking);
    });
  }

  // ── Online state restore (cold start) ────────────────────────────────────
  // Called from initState when the app was killed while the tech was online.
  // Reads the persisted flag and silently restores their online state —
  // same pattern Uber/Rapido use to reconnect automatically on cold start.
  Future<void> _checkAndRestoreOnlineState() async {
    final prefs     = await SharedPreferences.getInstance();
    final wasOnline = prefs.getBool('tech_is_online') ?? false;
    if (!wasOnline || !mounted) return;
    debugPrint('[RESTORE] was online before kill — auto-restoring');
    await _autoRestoreOnlineState();
  }

  Future<void> _autoRestoreOnlineState() async {
    if (!mounted) return;

    // Reconnect socket immediately; _handleTechnicianReconnect will re-emit
    // technician_online once connected because _isAvailable is still false
    // at this point — we call goOnline() below which sets it first.
    if (!SocketService.instance.isConnected) {
      SocketService.instance.reconnect();
    }

    if (!kIsWeb) {
      final running = await ForegroundService.instance.isRunning;
      if (!running) await ForegroundService.instance.start();
    }

    // Last-known position is instant (no GPS warm-up needed).
    // Falls back to a fresh low-accuracy fix with a 5 s timeout.
    Position? pos;
    try {
      pos = await Geolocator.getLastKnownPosition();
      pos ??= await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
        ),
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}

    if (!mounted) return;

    final lat = pos?.latitude  ?? 0.0;
    final lng = pos?.longitude ?? 0.0;

    SocketService.instance.goOnline(lat: lat, lng: lng);
    setState(() => _isOnline = true);
    _startLocationStream();
    debugPrint('[RESTORE] online restored  lat=$lat lng=$lng');
    // Retry pending background booking now that _isOnline is true.
    // addPostFrameCallback in _checkNotificationPendingAccept() ran earlier
    // while _isOnline was still false — this is the second attempt.
    _showPendingBackgroundBooking();
  }

  void _listenToSocket() {
    _bookingRequestSub =
        SocketService.instance.onBookingRequest.listen((booking) {
      if (!mounted || !_isOnline) return;

      // Screen off / app backgrounded: show notification only (no overlay UI).
      // Also store the booking so if the tech opens the app via the app icon
      // (not the notification), didChangeAppLifecycleState can show the overlay.
      final isBackground =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused;
      if (isBackground) {
        BookingNotificationService.instance.setPendingBackgroundBooking(booking);
        BookingNotificationService.instance.showBookingNotification(booking);
        return;
      }

      // Foreground: show the in-app overlay for richer UX.
      if (_overlayOpen) return;
      _overlayOpen = true;
      _sessionRequestCount++;
      ForegroundService.instance.updateText('New booking request');
      // Prevent FCM onForeground from showing a duplicate notification
      // for the same booking while the overlay is open.
      BookingNotificationService.instance.markOverlayHandling(booking.bookingId);
      showBookingRequestOverlay(context, booking, _sessionRequestCount)
          .then((accepted) {
        _overlayOpen = false;
        BookingNotificationService.instance
            .clearOverlayHandling(booking.bookingId);
        if (!mounted) return;
        if (!accepted) {
          ForegroundService.instance.updateText('Ready for booking requests');
          return;
        }
        _onBookingAccepted(booking);
      });
    });

    // Accept events from notification taps (background / locked / killed states).
    _bookingNotifAcceptSub =
        BookingNotificationService.instance.onAccepted.listen((booking) {
      if (!mounted) return;
      _onBookingAccepted(booking);
    });

    // booking_cancelled is handled inside BookingRequestOverlay itself.
  }

  // Shared handler for a booking the technician just accepted — via overlay
  // OR via notification action button.
  void _onBookingAccepted(SocketBooking booking) {
    ForegroundService.instance.updateText('Booking assigned — en route');
    final alreadyLoaded =
        _bookings.any((b) => b.id == booking.bookingId.toString());
    if (!alreadyLoaded) {
      setState(() {
        _bookings.insert(
          0,
          TechnicianBooking(
            id: booking.bookingId.toString(),
            patientId: booking.patientId,
            customerName: booking.patientName,
            customerPhone: booking.patientMobile,
            address: booking.patientAddress,
            city: '',
            pincode: '',
            date: DateTime.now(),
            timeSlot: 'ASAP',
            testNames: const ['Home Collection'],
            mode: 'Home Collection',
            status: 'Confirmed',
            isVip: false,
            docRequired: false,
            docVerified: false,
            serviceChargePaid: 0,
            testsTotal: 0,
            assignedAt: DateTime.now(),
            patientLat: booking.patientLat,
            patientLng: booking.patientLng,
            hospital: booking.hospital,
          ),
        );
        _cachedPending = null;
      });
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Booking #${booking.bookingId} accepted — start when ready'),
      backgroundColor: AppColors.brandGreen,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      duration: const Duration(seconds: 3),
    ));
  }

  // Called in initState() to handle any notification action that fired during
  // main() — before runApp() — while the dashboard widget wasn't built yet.
  //
  // Two cases handled here:
  //   1. Accept button tapped on a killed-app notification → _onBookingAccepted
  //   2. Body tapped on a killed-app notification → show overlay (same as
  //      _showPendingBackgroundBooking but scheduled via addPostFrameCallback
  //      because the widget tree isn't ready yet in initState)
  void _checkNotificationPendingAccept() {
    // Case 1 — Accept button tapped on a killed-app notification.
    // Socket is not connected yet — defer and emit booking_accepted once
    // the socket is ready, then update the dashboard UI.
    final pendingAccept =
        BookingNotificationService.instance.consumePendingAccept();
    if (pendingAccept != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _emitAcceptThenHandle(pendingAccept);
      });
    }

    // Case 2 — Body tap (or background booking pending from a previous session).
    // addPostFrameCallback defers until after the first frame so context and
    // Navigator are ready for showBookingRequestOverlay().
    // Drain FCM-isolate prefs first — background isolate writes there, not to
    // main-isolate memory, so we must promote it before showing the overlay.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await BookingNotificationService.instance.checkAndSetFcmPendingBooking();
      if (mounted) _showPendingBackgroundBooking();
    });
  }

  // Emit booking_accepted to the server then update the dashboard UI.
  // Called when the tech tapped Accept on a killed-app FCM notification.
  // The socket may not be connected yet — waits for it if needed.
  void _emitAcceptThenHandle(SocketBooking booking) {
    void emit() {
      SocketService.instance.emitBookingAccepted(
        bookingId:          booking.bookingId,
        technicianId:       SocketService.instance.userId,
        technicianName:     SocketService.instance.userName,
        sessionId:          SocketService.instance.sessionId,
        isAppointmentBased: booking.appointmentTime != null,
      );
    }

    if (SocketService.instance.isConnected) {
      emit();
      _onBookingAccepted(booking);
    } else {
      // Socket still connecting — emit as soon as it is ready.
      SocketService.instance.onConnected
          .where((connected) => connected)
          .take(1)
          .listen((_) {
        if (!mounted) return;
        emit();
        _onBookingAccepted(booking);
      });
    }
  }

  void _loadMockData() {
    _bookings = [];
    _loadActiveBookings();
    _refreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted && !_isRefreshing) _loadActiveBookings();
    });
  }

  Future<void> _loadActiveBookings() async {
    debugPrint('\n🔵 [ACTIVE-BOOKINGS] ── starting load ──');
    try {
      final prefs  = await SharedPreferences.getInstance();
      final techId = prefs.getInt('user_id') ?? 0;
      final token  = prefs.getString('auth_token') ?? '';
      debugPrint('   techId=$techId  token=${token.isEmpty ? "EMPTY" : token.substring(0, token.length.clamp(0, 12))}...');

      if (techId == 0) {
        debugPrint('🔴 [ACTIVE-BOOKINGS] techId=0 — session missing, aborting');
        return;
      }

      final baseUrl = AppConstants.serverUrl.endsWith('/')
          ? AppConstants.serverUrl.substring(0, AppConstants.serverUrl.length - 1)
          : AppConstants.serverUrl;
      final url = '$baseUrl/api/technicians/$techId/active-bookings';
      debugPrint('   GET $url');

      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));

      debugPrint('   status=${res.statusCode}  bodyLen=${res.body.length}');
      debugPrint('   body=${res.body.substring(0, res.body.length.clamp(0, 400))}');

      if (!mounted) {
        debugPrint('🔴 [ACTIVE-BOOKINGS] widget unmounted — skipping setState');
        return;
      }
      if (res.statusCode != 200) {
        debugPrint('🔴 [ACTIVE-BOOKINGS] non-200 status=${res.statusCode} — route may not exist on VPS yet');
        return;
      }

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final rows = body['data'] as List<dynamic>? ?? [];
      debugPrint('   parsed rows=${rows.length}');

      if (rows.isEmpty) {
        debugPrint('   ℹ️  0 active bookings in DB for techId=$techId');
        return;
      }

      setState(() {
        _bookings = rows.map((r) {
          final map = r as Map<String, dynamic>;
          final dateStr = map['collection_date'] as String?;
          final date = dateStr != null
              ? (DateTime.tryParse(dateStr)?.toLocal() ?? DateTime.now())
              : DateTime.now();
          final cs = map['collection_status'] as String? ?? '';
          final status = cs == 'en_route'             ? 'Journey Started'
              : cs == 'arrived'             ? 'Destination Reached'
              : cs == 'collection_started'  ? 'Collection Started'
              : cs == 'collected'           ? 'Sample Collected'
              : cs == 'sample_collected'    ? 'Sample Collected'
              : cs == 'otp_verified'        ? 'OTP Verified'
              : 'Confirmed';
          debugPrint('   → booking_id=${map['booking_id']} status=$cs → $status  patient=${map['patient_name']}');
          return TechnicianBooking(
            id:                map['booking_id']?.toString() ?? '',
            bookingRef:        map['booking_ref']        as String?,
            patientId:         int.tryParse(map['patient_id']?.toString() ?? ''),
            customerName:      map['patient_name']       as String? ?? 'Patient',
            customerPhone:     map['patient_mobile']     as String? ?? '',
            address:           map['collection_address'] as String? ?? '',
            city:              map['city']               as String? ?? '',
            pincode:           map['postal_code']        as String? ?? '',
            date:              date,
            timeSlot:          (map['slot_time_formatted'] as String?) ??
                               (map['slot_label']         as String?) ?? '—',
            testNames:         const ['Home Collection'],
            mode:              'Home Collection',
            status:            status,
            docRequired:       map['doc_required'] == 1,
            docVerified:       map['doc_verified'] == 1,
            serviceChargePaid: 0,
            testsTotal:        double.tryParse(map['amount_paid']?.toString() ?? '') ?? 0,
            amountPaid:        double.tryParse(map['booking_amount_paid']?.toString() ?? '') ?? 0.0,
            paymentStatus:     map['payment_status'] as String? ?? 'pending',
            assignedAt:        date,
            visitGroupId:      map['visit_group_id'] as String?,
            patientLat:        double.tryParse(map['patient_lat']?.toString() ?? ''),
            patientLng:        double.tryParse(map['patient_lng']?.toString() ?? ''),
          );
        }).toList();
        _cachedPending = null;
      });
      debugPrint('✅ [ACTIVE-BOOKINGS] _bookings=${_bookings.length}  _pending=${_pending.length}');
    } catch (e, st) {
      debugPrint('🔴 [ACTIVE-BOOKINGS] EXCEPTION type=${e.runtimeType}  msg=$e');
      debugPrint('   stacktrace: ${st.toString().split('\n').take(4).join(' | ')}');
    }
  }

  Future<void> _manualRefresh() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    await _loadActiveBookings();
    if (mounted) setState(() => _isRefreshing = false);
  }

  // ── Online / Offline toggle ────────────────────────────────────────────────

  Future<void> _toggleAvailability() async {
    if (_isTogglingOnline) return;
    setState(() => _isTogglingOnline = true);

    try {
      if (_isOnline) {
        _stopLocationStream();
        SocketService.instance.goOffline();
        // Stop the foreground service — Android can now manage the process normally.
        await ForegroundService.instance.stop();
        if (mounted) setState(() => _isOnline = false);
      } else {
        // ── PERMISSION ORDER IS CRITICAL ─────────────────────────────────
        //
        // Android 12+ throws ForegroundServiceStartNotAllowedException if
        // startForegroundService() is called while the app is in the background.
        // Samsung's BBA2 component also blocks service starts for ~4 seconds
        // after the activity returns from any OS Settings page.
        //
        // Two types of permission UX:
        //   IN-APP DIALOG  — system overlay, Activity stays in foreground → safe BEFORE start()
        //   SETTINGS PAGE  — Activity goes to background → MUST be AFTER start()
        //
        // CORRECT ORDER (matches Uber Driver / Rapido Captain architecture):
        //   1. Foreground location permission   — in-app dialog ✓
        //   2. Notification permission          — in-app dialog ✓
        //   3. Standard battery exemption       — in-app popup ✓ (once per denial)
        //   4. OEM battery guide                — in-app sheet ✓ (once per install)
        //   5. Get GPS position                 — no dialog ✓
        //   6. startWithRetry()                 — service FIRST, up to 3 attempts ✓
        //        └── if all fail: stay OFFLINE, show error dialog with Retry/Settings
        //   7. goOnline() + setState            — ONLY after service confirmed RUNNING ✓
        //   8. _startLocationStream()
        //   9. Background location              — opens Settings, service already running ✓

        // ── Step 1: Foreground location permission ────────────────────────
        debugPrint('[TOGGLE] checking foreground location permission');
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          debugPrint('[TOGGLE] location denied — cannot go online');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: const Text('Location permission is required to go online'),
              backgroundColor: const Color(0xFFD32F2F),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ));
          }
          return;
        }

        // ── Step 2: Notification permission (Android 13+) ─────────────────
        // Shows an in-app overlay dialog — does NOT open Settings, so the
        // activity stays in the foreground the whole time. Safe to do before start().
        if (!kIsWeb) {
          debugPrint('[TOGGLE] checking notification permission');
          var notifStatus = await Permission.notification.status;
          debugPrint('[TOGGLE] notification status=$notifStatus');
          if (notifStatus.isDenied) {
            notifStatus = await Permission.notification.request();
            debugPrint('[TOGGLE] notification after request=$notifStatus');
          }
          if (notifStatus.isPermanentlyDenied && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: const Text(
                'Enable notifications in Settings → Apps → MicroLab → Notifications.',
              ),
              action: const SnackBarAction(
                label: 'Open Settings',
                onPressed: openAppSettings,
              ),
              duration: const Duration(seconds: 8),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ));
          }
        }

        // ── Step 3: Standard Android battery exemption ───────────────────
        // Shows "Stop optimising battery?" system popup (in-app overlay,
        // Activity stays in foreground). Shown only if not already granted.
        // MUST be before start() — Samsung kills the service within 5s
        // if the app is not in the battery exemption list.
        if (!kIsWeb) {
          await BatteryService.instance.ensureStandardExemption();
        }

        // ── Step 4: OEM battery guide (Samsung / Xiaomi / Oppo etc.) ─────
        // Shown ONCE per install. Instructs the technician to add MicroLab
        // to "Never sleeping apps" in their phone's battery settings.
        // This covers manufacturer restrictions that the standard Android
        // battery API cannot reach programmatically.
        if (!kIsWeb && mounted) {
          await BatteryService.instance.showOemGuideIfNeeded(context);
        }

        // ── Step 5: Get current GPS position ─────────────────────────────
        debugPrint('[TOGGLE] fetching GPS position');
        Position? pos;
        try {
          pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
          ).timeout(const Duration(seconds: 10));
          debugPrint('[TOGGLE] position: lat=${pos.latitude} lng=${pos.longitude}');
        } catch (_) {
          try {
            pos = await Geolocator.getLastKnownPosition();
            debugPrint('[TOGGLE] using last-known position: lat=${pos?.latitude} lng=${pos?.longitude}');
          } catch (_) {
            debugPrint('[TOGGLE] could not get position — proceeding with 0,0');
          }
        }

        // ── Step 6: Start foreground service ─────────────────────────────
        //
        // CRITICAL: Service MUST start successfully BEFORE the technician is
        // marked Online. If started after, a service failure leaves the tech
        // Online with no persistent notification and no protection against
        // the process being killed.
        //
        // startWithRetry() attempts up to 3 times (each up to 5s) before
        // giving up. Battery exemption is already granted in Steps 3-4 so
        // Samsung should allow the service to run.
        debugPrint('[TOGGLE] Foreground Service Starting...');
        final fgsStarted = await ForegroundService.instance.startWithRetry();

        if (!fgsStarted) {
          // All 3 attempts failed — technician stays OFFLINE.
          // Show a non-blocking dialog so the finally block can immediately
          // reset _isTogglingOnline (the dialog does not block the function).
          debugPrint('[TOGGLE] ❌ Service Failed — Technician stays OFFLINE');
          if (mounted) {
            showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (ctx) => AlertDialog(
                icon: const Icon(
                  Icons.error_outline_rounded,
                  color: Colors.orange,
                  size: 48,
                ),
                title: const Text('Cannot Go Online'),
                content: const Text(
                  'The background service failed to start after 3 attempts.\n\n'
                  'Your phone\'s battery settings may be restricting MicroLab '
                  'from running in the background.\n\n'
                  'Open Battery Settings, find MicroLab, and set it to '
                  '"Unrestricted", then try again.',
                ),
                actionsAlignment: MainAxisAlignment.spaceEvenly,
                actions: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.settings_outlined, size: 16),
                    label: const Text('Battery Settings'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      ForegroundService.instance.openBatterySettings();
                    },
                  ),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Retry'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1565C0),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      // _isTogglingOnline is already false when this fires
                      // (the dialog is non-blocking — finally ran before the
                      // user had a chance to tap this button).
                      if (mounted) _toggleAvailability();
                    },
                  ),
                ],
              ),
            );
          }
          return; // ← stay OFFLINE, finally block resets _isTogglingOnline
        }

        // ── Step 7: Mark Online ────────────────────────────────────────────
        // Service is confirmed RUNNING. Now it is safe to go online.
        // The socket emits technician_online. UI switches to green.
        debugPrint('[TOGGLE] Foreground Notification Displayed ✓');
        SocketService.instance.goOnline(
          lat: pos?.latitude ?? 0.0,
          lng: pos?.longitude ?? 0.0,
        );
        if (mounted) setState(() => _isOnline = true);
        debugPrint('[TOGGLE] Socket Connected ✓ — Technician Online');

        // ── Step 8: Start GPS stream ──────────────────────────────────────
        _startLocationStream();
        debugPrint('[TOGGLE] Location Updates Started ✓');

        // ── Step 9: Background location permission ───────────────────────
        // Opens OS Settings on Android 11+ — app goes to background briefly.
        // Safe now because the service is RUNNING (confirmed in Step 6).
        if (!kIsWeb) {
          final bgStatus = await Permission.locationAlways.status;
          debugPrint('[TOGGLE] background location status=$bgStatus');
          if (!bgStatus.isGranted) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: const Text(
                  'Set location to "Allow all the time" for live tracking '
                  'when the screen is off.',
                ),
                backgroundColor: const Color(0xFF1565C0),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 4),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ));
            }
            await Permission.locationAlways.request();
            debugPrint('[TOGGLE] background location after request='
                '${await Permission.locationAlways.status}');
          }
        }

      }
    } finally {
      if (mounted) setState(() => _isTogglingOnline = false);
    }
  }

  // Continuous GPS stream — fires automatically whenever the device moves 10+ metres.
  // Unlike a timer, this stream keeps delivering positions even when the screen is
  // locked, because the foreground service (Feature 1) keeps the Dart isolate alive.
  void _startLocationStream() {
    _locationSub?.cancel();
    _locationSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        // Only emit when the technician has actually moved 10 metres —
        // avoids spamming the server with duplicate coordinates while stationary.
        distanceFilter: 10,
      ),
    ).listen(
      (pos) {
        if (!mounted || !_isOnline) return;
        SocketService.instance.emitIdleLocation(
          lat: pos.latitude,
          lng: pos.longitude,
        );
      },
      onError: (_) {}, // silently ignore location errors (GPS unavailable etc.)
    );
  }

  void _stopLocationStream() {
    _locationSub?.cancel();
    _locationSub = null;
  }

  Future<void> _handleLogout() async {
    // 1. Stop location, disconnect socket (emits technician_offline internally),
    //    and stop foreground service.
    _stopLocationStream();
    SocketService.instance.disconnect();
    await ForegroundService.instance.stop();

    // 2. Read IDs before clearing prefs
    final prefs  = await SharedPreferences.getInstance();
    final techId = prefs.getInt('user_id')      ?? 0;
    final token  = prefs.getString('auth_token') ?? '';

    // 3. Call logout API — closes session + clears DB token
    if (techId > 0) {
      try {
        // ✅ FIXED: Ensure no double slash in URL
        final baseUrl = AppConstants.serverUrl.endsWith('/') 
            ? AppConstants.serverUrl.substring(0, AppConstants.serverUrl.length - 1)
            : AppConstants.serverUrl;
        
        await http.post(
          Uri.parse('$baseUrl/api/technicians/$techId/logout'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        ).timeout(const Duration(seconds: 5));
      } catch (_) {}
    }

    // 4. Clear SharedPreferences
    await AuthService.logout();

    // 5. Navigate to login — dashboard is root so popUntil does nothing; replace instead
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const OnboardingScreen()),
        (route) => false,
      );
    }
  }

  void _startJourney(TechnicianBooking booking) {
    final bookingId = int.tryParse(booking.id) ?? 0;

    // Immediately notify customer that tech is on the way, before the screen
    // opens and GPS warms up — otherwise customer sees "Connecting..." forever.
    if (bookingId > 0) {
      SocketService.instance.emitEnRoute(bookingId: bookingId);
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TechnicianActiveJobScreen(
          bookingId: bookingId,
          patientName: booking.customerName,
          patientMobile: booking.customerPhone,
          patientAddress: booking.address,
          patientLat: booking.patientLat,
          patientLng: booking.patientLng,
          hospital: booking.hospital,
          startInEnRoute: true, // Skip the redundant internal "Start Journey" button
        ),
      ),
    ).then((wasCompleted) {
      if (!mounted) return;
      if (wasCompleted == true) {
        // OTP verified → collection complete → remove card from dashboard
        setState(() {
          _bookings.removeWhere((b) => b.id == booking.id);
          _cachedPending = null; // ✅ Invalidate cache
        });
        return;
      }
      // Tech exited mid-journey — keep card visible as "Journey Started"
      final idx = _bookings.indexWhere((b) => b.id == booking.id);
      if (idx != -1 && _bookings[idx].status == 'Confirmed') {
        setState(() {
          _bookings[idx] = TechnicianBooking(
            id: booking.id,
            customerName: booking.customerName,
            customerPhone: booking.customerPhone,
            address: booking.address,
            city: booking.city,
            pincode: booking.pincode,
            date: booking.date,
            timeSlot: booking.timeSlot,
            testNames: booking.testNames,
            mode: booking.mode,
            status: 'Journey Started',
            isVip: booking.isVip,
            docRequired: booking.docRequired,
            docVerified: booking.docVerified,
            serviceChargePaid: booking.serviceChargePaid,
            testsTotal: booking.testsTotal,
            amountPaid: booking.amountPaid,
            assignedAt: booking.assignedAt,
            patientLat: booking.patientLat,
            patientLng: booking.patientLng,
            hospital: booking.hospital,
          );
          _cachedPending = null; // ✅ Invalidate cache
        });
      }
    });
  }

  // Re-opens the active job screen for a booking already in progress.
  // Does NOT re-emit emitEnRoute — customer already received it.
  void _resumeJourney(TechnicianBooking booking) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TechnicianActiveJobScreen(
          bookingId: int.tryParse(booking.id) ?? 0,
          patientName: booking.customerName,
          patientMobile: booking.customerPhone,
          patientAddress: booking.address,
          patientLat: booking.patientLat,
          patientLng: booking.patientLng,
          hospital: booking.hospital,
          startInEnRoute: true,
        ),
      ),
    ).then((wasCompleted) {
      if (wasCompleted == true && mounted) {
        setState(() {
          _bookings.removeWhere((b) => b.id == booking.id);
          _cachedPending = null; // ✅ Invalidate cache
        });
      }
    });
  }

  // ✅ FIXED: Cached getter to avoid rebuilding list on every access
  List<TechnicianBooking> get _pending {
    if (_cachedPending != null) return _cachedPending!;
    _cachedPending = _bookings
        .where((b) => !['Completed','Cancelled'].contains(b.status))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    return _cachedPending!;
  }

  void _callCustomer(String phone) {
    launchUrl(Uri.parse('tel:+91$phone'));
  }

  void _onNavTap(int index) => setState(() => _selectedIndex = index);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bookingRequestSub?.cancel();
    _bookingNotifAcceptSub?.cancel();
    _refreshTimer?.cancel();
    _stopLocationStream();
    if (_isOnline) {
      SocketService.instance.goOffline();
      // BUG FIX: stop() was missing here. If this widget is disposed without
      // the process dying (e.g. navigation stack fully popped), the foreground
      // notification would linger with no code behind it.
      // dispose() cannot be async so we fire-and-forget — acceptable because
      // if the process is also dying the service goes with it anyway.
      ForegroundService.instance.stop();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: _selectedIndex == 0
            ? AppBar(
                backgroundColor: AppColors.brandGreen,
                elevation: 0,
                automaticallyImplyLeading: false,
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('MicroLab',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    Text('Technician · +91 ${widget.mobile}',
                        // ✅ FIXED: withValues → withOpacity
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.75), fontSize: 11)),
                  ],
                ),
                actions: [
                  IconButton(
                    icon: _isRefreshing
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.refresh_rounded, color: Colors.white70),
                    onPressed: _isRefreshing ? null : _manualRefresh,
                    tooltip: 'Refresh bookings',
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _isTogglingOnline
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 400),
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: _isOnline
                                      ? Colors.greenAccent
                                      : Colors.white38,
                                ),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                _isOnline ? 'Online' : 'Offline',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: _isOnline
                                      ? Colors.greenAccent
                                      : Colors.white60,
                                ),
                              ),
                              Transform.scale(
                                scale: 0.78,
                                child: Switch(
                                  value: _isOnline,
                                  onChanged: _isTogglingOnline
                                      ? null
                                      : (_) => _toggleAvailability(),
                                  activeThumbColor: Colors.greenAccent,
                                  // ✅ FIXED: withValues → withOpacity
                                  activeTrackColor:
                                      Colors.greenAccent.withOpacity(0.35),
                                  inactiveThumbColor: Colors.white54,
                                  inactiveTrackColor: Colors.white24,
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              )
            : null,
        body: Stack(
          children: [
            IndexedStack(
              index: _selectedIndex,
              children: [
                // Show offline wall only when there are no pending jobs.
              // If the technician has pre-assigned bookings, show them with a
              // slim banner — new requests are still blocked while offline.
              !_isOnline && _pending.isEmpty
                    ? _offlineState()
                    : Column(
                        children: [
                          if (!_isOnline) _offlineBanner(),
                          Expanded(
                            child: _pending.isEmpty
                                ? _emptyState('No pending bookings', Icons.calendar_today_outlined)
                                : RefreshIndicator(
                                    onRefresh: _loadActiveBookings,
                                    color: AppColors.brandGreen,
                                    child: ListView.builder(
                                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                                      itemCount: _pending.length,
                                      itemBuilder: (_, i) => _PendingBookingCard(
                                        booking: _pending[i],
                                        onCall: () => _callCustomer(_pending[i].customerPhone),
                                        onStartCollection: () => _startJourney(_pending[i]),
                                        onResume: () => _resumeJourney(_pending[i]),
                                        onManage: () {
                                          final b = _pending[i];
                                          Navigator.push(context, MaterialPageRoute(
                                            builder: (_) => TechnicianBookingDetailScreen(
                                              booking: b,
                                              onNewBooking: (newBooking) {
                                                setState(() {
                                                  _bookings.insert(0, newBooking);
                                                  _cachedPending = null;
                                                });
                                                // Pull fresh list from server so the
                                                // 60-second timer doesn't wipe the injection
                                                _loadActiveBookings();
                                              },
                                            ),
                                          )).then((wasCompleted) {
                                            if (wasCompleted == true && mounted) {
                                              setState(() {
                                                _bookings.removeWhere((bk) => bk.id == b.id);
                                                _cachedPending = null;
                                              });
                                            }
                                          });
                                        },
                                      ),
                                    ),
                                  ),
                          ),
                        ],
                      ),
                SafeArea(
                    top: false,
                    bottom: false,
                    child: TechnicianSlotScreen(embedded: true, mobile: widget.mobile)),
                SafeArea(
                    top: false,
                    bottom: false,
                    child: TechnicianHistoryScreen(embedded: true, mobile: widget.mobile)),
                SafeArea(
                    top: false,
                    bottom: false,
                    child: TechnicianProfileScreen(
                      embedded: true,
                      mobile: widget.mobile,
                      onLogout: () => _handleLogout(),
                    )),
              ],
            ),
          ],
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _selectedIndex,
          onTap: _onNavTap,
          type: BottomNavigationBarType.fixed,
          selectedItemColor: AppColors.brandGreen,
          unselectedItemColor: AppColors.textSecondary,
          backgroundColor: Colors.white,
          selectedLabelStyle:
              const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          unselectedLabelStyle: const TextStyle(fontSize: 11),
          elevation: 8,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_outlined),
              activeIcon: Icon(Icons.dashboard),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.calendar_month_outlined),
              activeIcon: Icon(Icons.calendar_month),
              label: 'Schedule',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.history_outlined),
              activeIcon: Icon(Icons.history),
              label: 'History',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person_outline_rounded),
              activeIcon: Icon(Icons.person_rounded),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }

  Widget _offlineState() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: Color(0xFFF3F4F6),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.wifi_off_rounded,
                  size: 32, color: Color(0xFF9CA3AF)),
            ),
            const SizedBox(height: 16),
            const Text(
              'You are Offline',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary),
            ),
            const SizedBox(height: 6),
            const Text(
              'Toggle Online to start receiving bookings',
              style:
                  TextStyle(fontSize: 13, color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            _isTogglingOnline
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.brandGreen))
                : ElevatedButton.icon(
                    onPressed: _toggleAvailability,
                    icon: const Icon(Icons.power_settings_new_rounded,
                        size: 18),
                    label: const Text('Go Online',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brandGreen,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
          ],
        ),
      );

  Widget _emptyState(String msg, IconData icon) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72, height: 72,
              decoration: const BoxDecoration(
                  color: AppColors.brandGreenSurface, shape: BoxShape.circle),
              child: Icon(icon, size: 32, color: AppColors.brandGreen),
            ),
            const SizedBox(height: 16),
            Text(msg,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
          ],
        ),
      );

  Widget _offlineBanner() => Container(
        width: double.infinity,
        color: const Color(0xFFFFF3CD),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            const Icon(Icons.wifi_off_rounded, size: 15, color: Color(0xFF856404)),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'You are offline — new bookings paused. Toggle Online to receive requests.',
                style: TextStyle(fontSize: 12, color: Color(0xFF856404)),
              ),
            ),
            GestureDetector(
              onTap: _toggleAvailability,
              child: const Text('Go Online',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF856404))),
            ),
          ],
        ),
      );
}

// ─── Pending Booking Card ─────────────────────────────────────────────────────

class _PendingBookingCard extends StatelessWidget {
  final TechnicianBooking booking;
  final VoidCallback onCall;
  final VoidCallback onStartCollection;
  final VoidCallback onResume;
  final VoidCallback onManage;

  const _PendingBookingCard({
    required this.booking,
    required this.onCall,
    required this.onStartCollection,
    required this.onResume,
    required this.onManage,
  });

  Color get _statusColor {
    switch (booking.status) {
      case 'Confirmed':            return AppColors.brandGreen;
      case 'En Route':             return const Color(0xFF1565C0);
      case 'Journey Started':      return const Color(0xFF1565C0);
      case 'Arrived':              return const Color(0xFF6A1B9A);
      case 'Destination Reached':  return const Color(0xFF6A1B9A);
      case 'Collection Started':   return const Color(0xFFE65100);
      case 'Completed':            return AppColors.brandGreen;
      default:                     return const Color(0xFFE65100);
    }
  }

  IconData get _statusIcon {
    switch (booking.status) {
      case 'Confirmed':            return Icons.check_circle_outline;
      case 'En Route':             return Icons.directions_bike_rounded;
      case 'Journey Started':      return Icons.directions_bike_rounded;
      case 'Arrived':              return Icons.location_on_rounded;
      case 'Destination Reached':  return Icons.location_on_rounded;
      case 'Collection Started':   return Icons.science_outlined;
      default:                     return Icons.hourglass_top_rounded;
    }
  }

  String _formatDate(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(d.year, d.month, d.day);
    final diff = date.difference(today).inDays;
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    if (diff == -1) return 'Yesterday';
    return '${d.day} ${months[d.month]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    // Determine if booking is in progress (journey started but not completed)
    final isInProgress = booking.status == 'En Route' ||
                         booking.status == 'Journey Started' ||
                         booking.status == 'Arrived' ||
                         booking.status == 'Destination Reached' ||
                         booking.status == 'Collection Started';
    
    // Determine if booking is confirmed (ready to start)
    final isConfirmed = booking.status == 'Confirmed';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          // ✅ FIXED: withValues → withOpacity
          color: isInProgress
              ? const Color(0xFF1565C0).withOpacity(0.4)
              : AppColors.divider,
          width: isInProgress ? 1.5 : 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Column(
          children: [
            // Status strip
            Container(
              // ✅ FIXED: withValues → withOpacity
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: _statusColor.withOpacity(0.08),
              child: Row(
                children: [
                  Icon(_statusIcon, size: 13, color: _statusColor),
                  const SizedBox(width: 6),
                  Text(booking.status,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _statusColor)),
                  const Spacer(),
                  if (booking.isVip)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFB300),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.star_rounded, size: 9, color: Colors.white),
                        SizedBox(width: 3),
                        Text('VIP', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Colors.white)),
                      ]),
                    ),
                  if (booking.isVip) const SizedBox(width: 8),
                  Text(booking.bookingRef ?? '#${booking.id}',
                      style: const TextStyle(fontSize: 11, color: AppColors.textHint)),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Customer name + call
                  Row(
                    children: [
                      Expanded(
                        child: Text(booking.customerName,
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary)),
                      ),
                      GestureDetector(
                        onTap: onCall,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 7),
                          decoration: BoxDecoration(
                            color: AppColors.brandGreenSurface,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: AppColors.brandGreenLight),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.phone_outlined,
                                size: 14, color: AppColors.brandGreen),
                            const SizedBox(width: 5),
                            Text(booking.customerPhone,
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.brandGreen,
                                    fontWeight: FontWeight.w500)),
                          ]),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),

                  // Date + time
                  _InfoRow(Icons.event_outlined,
                      '${_formatDate(booking.date)}  ·  ${booking.timeSlot}'),
                  const SizedBox(height: 5),

                  // Location
                  _InfoRow(
                    booking.mode == 'Home Collection'
                        ? Icons.home_outlined
                        : Icons.local_hospital_outlined,
                    [booking.address, booking.city, booking.pincode]
                        .where((s) => s.isNotEmpty)
                        .join(', '),
                  ),
                  const SizedBox(height: 5),

                  // Tests
                  _InfoRow(Icons.science_outlined,
                      booking.testNames.join(', ')),

                  if (booking.docRequired) ...[
                    const SizedBox(height: 5),
                    const Row(children: [
                      Icon(Icons.description_outlined,
                          size: 13, color: Color(0xFFE65100)),
                      SizedBox(width: 6),
                      Text('Prescription required',
                          style: TextStyle(
                              fontSize: 12,
                              color: Color(0xFFE65100),
                              fontWeight: FontWeight.w500)),
                    ]),
                  ],

                  const SizedBox(height: 12),

                  // Action buttons
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: onManage,
                          icon: const Icon(Icons.edit_note_rounded, size: 16),
                          label: const Text('Manage', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.brandGreen,
                            side: const BorderSide(color: AppColors.brandGreen),
                            padding: const EdgeInsets.symmetric(vertical: 9),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (isConfirmed) ...[
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: onStartCollection,
                            icon: const Icon(Icons.directions_bike_rounded, size: 16),
                            label: const Text('Start Journey',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1565C0),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                      ] else if (isInProgress) ...[
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: onResume,
                            icon: const Icon(Icons.directions_bike_rounded, size: 16),
                            label: const Text('Continue Journey',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1565C0),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoRow(this.icon, this.text);

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: AppColors.textHint),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
          ),
        ],
      );
}