import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/models/technician_booking.dart';
import 'technician_booking_detail_screen.dart';
import 'technician_history_screen.dart';
import 'technician_slot_screen.dart';
import 'technician_profile_screen.dart';
import 'booking_request_overlay.dart';
import 'technician_active_job_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/screens/customer/support_chatbot.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/screens/shared/onboarding_screen.dart';

// ─── Technician Dashboard Screen ──────────────────────────────────────────────

class TechnicianDashboardScreen extends StatefulWidget {
  final String mobile;
  const TechnicianDashboardScreen({super.key, required this.mobile});

  @override
  State<TechnicianDashboardScreen> createState() =>
      _TechnicianDashboardScreenState();
}

class _TechnicianDashboardScreenState extends State<TechnicianDashboardScreen> {
  int _selectedIndex = 0;

  // Mock bookings — replace with GET /api/technician/bookings
  late List<TechnicianBooking> _bookings;

  StreamSubscription<SocketBooking>? _bookingRequestSub;
  bool _overlayOpen = false;

  // Availability — technician starts Offline after login
  bool _isOnline = false;
  bool _isTogglingOnline = false;
  Timer? _idlePingTimer;

  @override
  void initState() {
    super.initState();
    _loadMockData();
    // Sync local flag from the singleton so that if this widget is recreated
    // (hot-reload, navigation stack rebuild) while the tech is already online,
    // incoming booking_request events are not silently dropped by the
    // !_isOnline guard in _listenToSocket.
    _isOnline = SocketService.instance.isAvailable;
    if (_isOnline) _startIdlePing();
    _listenToSocket();
  }

  void _listenToSocket() {
    _bookingRequestSub =
        SocketService.instance.onBookingRequest.listen((booking) {
      if (!mounted || _overlayOpen || !_isOnline) return;
      _overlayOpen = true;
      showBookingRequestOverlay(context, booking).then((accepted) {
        _overlayOpen = false;
        if (!accepted || !mounted) return;
        // Add to dashboard as a pending task — technician starts when ready
        setState(() {
          _bookings.insert(0, TechnicianBooking(
            id: booking.bookingId.toString(),
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
          ));
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Booking #${booking.bookingId} added — start when ready'),
          backgroundColor: AppColors.brandGreen,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 3),
        ));
      });
    });

    // booking_cancelled is handled inside BookingRequestOverlay itself.
    // The overlay subscribes to onBookingCancelled with a bookingId filter and
    // calls Navigator.pop(false) on its own context — a single, safe dismiss path.
  }

  void _loadMockData() {
    _bookings = []; // Real bookings arrive via socket (booking_request events)
  }

  // ── Online / Offline toggle ────────────────────────────────────────────────

  Future<void> _toggleAvailability() async {
    if (_isTogglingOnline) return;
    setState(() => _isTogglingOnline = true);

    try {
      if (_isOnline) {
        _stopIdlePing();
        SocketService.instance.goOffline();
        if (mounted) setState(() => _isOnline = false);
      } else {
        // Ensure location permission is granted before going Online
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
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

        // Fetch position — fall back to last-known on timeout
        Position? pos;
        try {
          pos = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
          ).timeout(const Duration(seconds: 10));
        } catch (_) {
          pos = await Geolocator.getLastKnownPosition();
        }

        SocketService.instance.goOnline(
          lat: pos?.latitude ?? 0.0,
          lng: pos?.longitude ?? 0.0,
        );
        if (mounted) setState(() => _isOnline = true);
        _startIdlePing();
      }
    } finally {
      if (mounted) setState(() => _isTogglingOnline = false);
    }
  }

  void _startIdlePing() {
    _idlePingTimer?.cancel();
    _idlePingTimer = Timer.periodic(
      Duration(seconds: AppConstants.idlePingSeconds),
      (_) async {
        if (!mounted || !_isOnline) return;
        try {
          final pos = await Geolocator.getLastKnownPosition();
          if (pos != null) {
            SocketService.instance.emitIdleLocation(
              lat: pos.latitude,
              lng: pos.longitude,
            );
          }
        } catch (_) {}
      },
    );
  }

  void _stopIdlePing() {
    _idlePingTimer?.cancel();
    _idlePingTimer = null;
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
        setState(() => _bookings.removeWhere((b) => b.id == booking.id));
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
            assignedAt: booking.assignedAt,
            patientLat: booking.patientLat,
            patientLng: booking.patientLng,
            hospital: booking.hospital,
          );
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
        setState(() => _bookings.removeWhere((b) => b.id == booking.id));
      }
    });
  }

  List<TechnicianBooking> get _pending => _bookings
      .where((b) => !['Completed','Cancelled'].contains(b.status))
      .toList()
    ..sort((a, b) => a.date.compareTo(b.date));

  void _callCustomer(String phone) {
    // TODO: url_launcher → launch('tel:+91$phone')
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Calling +91 $phone…'),
      backgroundColor: AppColors.brandGreen,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  void _markInProgress(TechnicianBooking booking) {
    setState(() {
      final idx = _bookings.indexWhere((b) => b.id == booking.id);
      if (idx != -1) {
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
          assignedAt: booking.assignedAt,
        );
      }
    });
  }

  void _markCompleted(TechnicianBooking booking) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Mark as Completed?',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        content: Text(
          'Confirm that you have collected samples from ${booking.customerName}.',
          style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                final idx = _bookings.indexWhere((b) => b.id == booking.id);
                if (idx != -1) {
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
                    status: 'Completed',
                    isVip: booking.isVip,
                    docRequired: booking.docRequired,
                    assignedAt: booking.assignedAt,
                  );
                }
              });
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.brandGreen,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Confirm', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Logout?',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        content: const Text('Are you sure you want to logout?',
            style: TextStyle(fontSize: 14, color: AppColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD32F2F),
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Logout',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final token = await ApiService.getToken();
    if (token != null) await ApiService.logout(token);
    await ApiService.clearToken();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const OnboardingScreen()),
      (_) => false,
    );
  }

  void _onNavTap(int index) => setState(() => _selectedIndex = index);

  @override
  void dispose() {
    _bookingRequestSub?.cancel();
    _stopIdlePing();
    if (_isOnline) SocketService.instance.goOffline();
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
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75), fontSize: 11)),
                  ],
                ),
                actions: [
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
                                  activeTrackColor:
                                      Colors.greenAccent.withValues(alpha: 0.35),
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
                !_isOnline
                    ? _offlineState()
                    : _pending.isEmpty
                        ? _emptyState('No pending bookings', Icons.calendar_today_outlined)
                        : ListView.builder(
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
                                  setState(() => _bookings.insert(0, newBooking));
                                },
                              ),
                            )).then((wasCompleted) {
                              if (wasCompleted == true && mounted) {
                                setState(() => _bookings.removeWhere((bk) => bk.id == b.id));
                              }
                            });
                          },
                        ),
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
                      onLogout: _logout,
                    )),
              ],
            ),
            const Positioned(
              right: 16,
              bottom: 88,
              child: SupportChatbotButton(),
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
      case 'Journey Started':      return const Color(0xFF1565C0);
      case 'Destination Reached':  return const Color(0xFF6A1B9A);
      case 'Collection Started':   return const Color(0xFFE65100);
      case 'Completed':            return AppColors.brandGreen;
      default:                     return const Color(0xFFE65100);
    }
  }

  IconData get _statusIcon {
    switch (booking.status) {
      case 'Confirmed':            return Icons.check_circle_outline;
      case 'Journey Started':      return Icons.directions_bike_rounded;
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
    final isInProgress = booking.status == 'Journey Started' || 
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
          color: isInProgress
              ? const Color(0xFF1565C0).withValues(alpha: 0.4)
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
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: _statusColor.withValues(alpha: 0.08),
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
                  Text(booking.id,
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