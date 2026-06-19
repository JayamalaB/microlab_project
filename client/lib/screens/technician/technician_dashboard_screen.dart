import 'dart:async';
import 'technician_booking_detail_screen.dart';
import 'technician_history_screen.dart';
import 'technician_slot_screen.dart';
import 'technician_profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/screens/customer/support_chatbot.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/screens/shared/onboarding_screen.dart';

// ─── Technician Booking Model ─────────────────────────────────────────────────

class TechnicianBooking {
  final String id;
  final String customerName;
  final String customerPhone;
  final String address;
  final String city;
  final String pincode;
  final DateTime date;
  final String timeSlot;
  final List<String> testNames;
  final String mode; // 'Home Collection' | 'Lab Test'
  final String status; // 'Pending'|'Confirmed'|'Journey Started'|'Destination Reached'|'Collection Started'|'Completed'|'Cancelled'
  final bool isVip;
  final bool docRequired;
  final bool docVerified;
  final double serviceChargePaid; // already collected at booking
  final double testsTotal;       // amount due at collection
  final DateTime? assignedAt;

  TechnicianBooking({
    required this.id,
    required this.customerName,
    required this.customerPhone,
    required this.address,
    required this.city,
    required this.pincode,
    required this.date,
    required this.timeSlot,
    required this.testNames,
    required this.mode,
    required this.status,
    this.isVip = false,
    this.docRequired = false,
    this.docVerified = false,
    this.serviceChargePaid = 99.0,
    this.testsTotal = 0.0,
    this.assignedAt,
  });
}

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

  // Simulated incoming new request (replace with WebSocket / FCM push)
  Timer? _newRequestTimer;

  @override
  void initState() {
    super.initState();
    _loadMockData();
    _simulateIncomingRequest();
  }

  void _loadMockData() {
    _bookings = [
      TechnicianBooking(
        id: 'BK00123456',
        customerName: 'Ravi Kumar',
        customerPhone: '9876543210',
        address: '12, Gandhi Street, T Nagar',
        city: 'Chennai',
        pincode: '600017',
        date: DateTime.now().add(const Duration(hours: 3)),
        timeSlot: '10:00 AM',
        testNames: ['HbA1c', 'CBC'],
        mode: 'Home Collection',
        status: 'Confirmed',
        serviceChargePaid: 99.0,
        testsTotal: 890.0,
        isVip: false,
        assignedAt: DateTime.now().subtract(const Duration(hours: 1)),
      ),
      TechnicianBooking(
        id: 'BK00123789',
        customerName: 'Priya Kumar',
        customerPhone: '9876543211',
        address: '8, Anna Salai, Adyar',
        city: 'Chennai',
        pincode: '600020',
        date: DateTime.now().add(const Duration(hours: 5)),
        timeSlot: '1:00 PM',
        testNames: ['Diabetes Care Package'],
        mode: 'Home Collection',
        status: 'Journey Started',
        serviceChargePaid: 99.0,
        testsTotal: 1440.0,
        isVip: true,
        assignedAt: DateTime.now().subtract(const Duration(minutes: 30)),
      ),
      // Completed bookings are shown in History screen via GET /api/technician/bookings?status=completed
    ];
  }

  // Simulate a new request arriving after 4 seconds
  void _simulateIncomingRequest() {
    _newRequestTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      final newBooking = TechnicianBooking(
        id: 'BK00124000',
        customerName: 'Anitha Raj',
        customerPhone: '9876543220',
        address: '5, Besant Nagar, 2nd Street',
        city: 'Chennai',
        pincode: '600090',
        date: DateTime.now().add(const Duration(days: 1)),
        timeSlot: '12:00 PM',
        testNames: ['Thyroid Profile', 'Vitamin Panel'],
        mode: 'Home Collection',
        status: 'Pending',
        isVip: true,
        assignedAt: DateTime.now(),
      );
      _showNewRequestDialog(newBooking);
    });
  }

  void _showNewRequestDialog(TechnicianBooking booking) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _NewRequestDialog(
        booking: booking,
        onConfirm: () {
          setState(() {
            _bookings.insert(0, TechnicianBooking(
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
              status: 'Confirmed',
              isVip: booking.isVip,
              assignedAt: DateTime.now(),
            ));
          });
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: const Text('Booking confirmed and added to your schedule'),
            backgroundColor: AppColors.brandGreen,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ));
        },
        onCancel: () => Navigator.pop(context),
      ),
    );
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
    _newRequestTimer?.cancel();
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
              actions: const [],
            )
          : null,
      body: Stack(
        children: [
          IndexedStack(
            index: _selectedIndex,
            children: [
              _pending.isEmpty
                  ? _emptyState('No pending bookings', Icons.calendar_today_outlined)
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                      itemCount: _pending.length,
                      itemBuilder: (_, i) => _PendingBookingCard(
                        booking: _pending[i],
                        onCall: () => _callCustomer(_pending[i].customerPhone),
                        onStartCollection: () => _markInProgress(_pending[i]),
                        onComplete: () => _markCompleted(_pending[i]),
                        onManage: () => Navigator.push(context, MaterialPageRoute(
                          builder: (_) => TechnicianBookingDetailScreen(
                            booking: _pending[i],
                            onNewBooking: (newBooking) {
                              setState(() => _bookings.insert(0, newBooking));
                            },
                          ))),
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
    ), // Scaffold
    ); // AnnotatedRegion
  }

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
  final VoidCallback onComplete;
  final VoidCallback onManage;

  const _PendingBookingCard({
    required this.booking,
    required this.onCall,
    required this.onStartCollection,
    required this.onComplete,
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
    final diff = d.difference(DateTime(now.year, now.month, now.day)).inDays;
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    return '${d.day} ${months[d.month]}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: booking.status == 'In Progress'
              ? const Color(0xFF1565C0).withValues(alpha: 0.4)
              : AppColors.divider,
          width: booking.status == 'In Progress' ? 1.5 : 1,
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
                    '${booking.address}, ${booking.city} – ${booking.pincode}',
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
                      if (booking.status == 'Confirmed') ...[
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


// ─── New Request Dialog ───────────────────────────────────────────────────────

class _NewRequestDialog extends StatelessWidget {
  final TechnicianBooking booking;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const _NewRequestDialog({
    required this.booking,
    required this.onConfirm,
    required this.onCancel,
  });

  String _formatDate(DateTime d) {
    const months = ['','Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[d.weekday - 1]}, ${d.day} ${months[d.month]} ${d.year}';
  }

  void _callCustomer(BuildContext context) {
    // TODO: url_launcher → launch('tel:+91${booking.customerPhone}')
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Calling +91 ${booking.customerPhone}…'),
      backgroundColor: AppColors.brandGreen,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header — pulsing green + call button
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
            decoration: const BoxDecoration(
              color: AppColors.brandGreen,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Row(
              children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.notification_important_outlined,
                      color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('New Booking Request',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700)),
                      Text('Confirm to add to your schedule',
                          style: TextStyle(
                              color: Colors.white70, fontSize: 11)),
                    ],
                  ),
                ),
                // Call button in header
                GestureDetector(
                  onTap: () => _callCustomer(context),
                  child: Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.1),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.phone_rounded,
                        color: AppColors.brandGreen, size: 20),
                  ),
                ),
              ],
            ),
          ),

          // Body — booking details
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Customer name + VIP badge
                Row(
                  children: [
                    Expanded(
                      child: Text(booking.customerName,
                          style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary)),
                    ),
                    if (booking.isVip)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFB300),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.star_rounded, size: 11, color: Colors.white),
                          SizedBox(width: 4),
                          Text('VIP', style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
                        ]),
                      ),
                  ],
                ),
                const SizedBox(height: 16),

                // Details
                _DialogRow(Icons.event_outlined, 'Date',
                    _formatDate(booking.date)),
                const SizedBox(height: 10),
                _DialogRow(Icons.schedule_outlined, 'Time',
                    booking.timeSlot),
                const SizedBox(height: 10),
                _DialogRow(
                  booking.mode == 'Home Collection'
                      ? Icons.home_outlined
                      : Icons.local_hospital_outlined,
                  'Location',
                  '${booking.address}\n${booking.city} – ${booking.pincode}',
                ),
                const SizedBox(height: 10),
                _DialogRow(Icons.science_outlined, 'Tests',
                    booking.testNames.join(', ')),

                if (booking.docRequired) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF3E0),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: const Color(0xFFFFCC02).withValues(alpha: 0.4)),
                    ),
                    child: const Row(children: [
                      Icon(Icons.description_outlined,
                          size: 14, color: Color(0xFFE65100)),
                      SizedBox(width: 6),
                      Expanded(child: Text('Prescription required — verify on arrival',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFFE65100)))),
                    ]),
                  ),
                ],

                const SizedBox(height: 20),

                // Action buttons
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onCancel,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFD32F2F),
                          side: const BorderSide(color: Color(0xFFD32F2F)),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Decline',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: onConfirm,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.brandGreen,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Confirm',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DialogRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _DialogRow(this.icon, this.label, this.value);

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.brandGreen),
          const SizedBox(width: 10),
          SizedBox(
            width: 64,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary)),
          ),
        ],
      );
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

