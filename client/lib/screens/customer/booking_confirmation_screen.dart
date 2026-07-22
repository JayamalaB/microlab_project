import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/constants/app_constants.dart';
import 'tracking_map_screen.dart';

class BookingConfirmationScreen extends StatefulWidget {
  final int bookingId;
  final int patientId;
  final String patientName;
  final String patientMobile;
  final String patientAddress;
  final double? patientLat;
  final double? patientLng;
  final String  hospital;
  final int?    branchId;
  final String? branchName;
  final int?    slotId;
  final String? slotLabel;
  final String? appointmentTime;       // "06:30" — exact time within slot
  final String? appointmentTimeLabel;  // "6:30 AM" — display

  const BookingConfirmationScreen({
    super.key,
    required this.bookingId,
    required this.patientId,
    required this.patientName,
    required this.patientMobile,
    required this.patientAddress,
    this.patientLat,
    this.patientLng,
    required this.hospital,
    this.branchId,
    this.branchName,
    this.slotId,
    this.slotLabel,
    this.appointmentTime,
    this.appointmentTimeLabel,
  });

  @override
  State<BookingConfirmationScreen> createState() =>
      _BookingConfirmationScreenState();
}

class _BookingConfirmationScreenState
    extends State<BookingConfirmationScreen> with TickerProviderStateMixin {
  late final AnimationController _dotCtrl;
  late final AnimationController _pulseCtrl;

  StreamSubscription<BookingAcceptedEvent>? _acceptedSub;
  StreamSubscription<int>?                  _timeoutSub;
  StreamSubscription<SlotNoAvailability>?   _slotNoAvailSub;

  Timer? _searchTimer;
  int  _secondsSearched = 0;
  bool _timedOut        = false;
  bool _accepted        = false;

  // Mutable slot/time — updated when the patient re-selects after slot_no_availability.
  int?    _currentSlotId;
  String? _currentSlotLabel;
  String? _currentAppointmentTime;
  String? _currentAppointmentTimeLabel;

  // Slot/time re-selection state
  bool                      _slotNoAvail        = false;
  String                    _slotNoAvailMessage = '';
  List<AppointmentTimeOption> _altTimeIntervals = [];
  List<SlotOption>            _altSlots         = [];
  AppointmentTimeOption?      _pickedAltTime;
  SlotOption?                 _pickedAltSlot;

  @override
  void initState() {
    super.initState();

    _dotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    _currentSlotId               = widget.slotId;
    _currentSlotLabel            = widget.slotLabel;
    _currentAppointmentTime      = widget.appointmentTime;
    _currentAppointmentTimeLabel = widget.appointmentTimeLabel;

    debugPrint('\n🔵 [BOOKING CONFIRMATION] bookingId=${widget.bookingId} patientId=${widget.patientId}');
    debugPrint('   Registering patient socket and emitting booking_request...');

    // Register patient socket and emit booking request
    SocketService.instance.registerPatientSocket(
      patientId: widget.patientId,
      bookingId: widget.bookingId,
    );
    SocketService.instance.emitBookingRequest(
      bookingId:       widget.bookingId,
      patientId:       widget.patientId,
      patientName:     widget.patientName,
      patientMobile:   widget.patientMobile,
      patientAddress:  widget.patientAddress,
      patientLat:      widget.patientLat,
      patientLng:      widget.patientLng,
      hospital:        widget.hospital,
      branchId:        widget.branchId,
      branchName:      widget.branchName,
      slotId:          widget.slotId,
      slotLabel:       widget.slotLabel,
      appointmentTime: widget.appointmentTime,
    );
    debugPrint('   branchId: ${widget.branchId ?? 'none'}  branchName: ${widget.branchName ?? '—'}  slot: ${widget.slotId} (${widget.slotLabel ?? '—'})  time: ${widget.appointmentTime ?? '—'}');

    _acceptedSub = SocketService.instance.onBookingAccepted.listen((event) {
      if (event.bookingId != widget.bookingId || !mounted) return;
      debugPrint('✅ [BOOKING CONFIRMATION] booking_accepted received!');
      debugPrint('   technicianId=${event.technicianId} technicianName=${event.technicianName} trackingId=${event.trackingId}');
      _onAccepted(event);
    });

    _timeoutSub = SocketService.instance.onBookingTimeout.listen((id) {
      if (id != widget.bookingId || !mounted) return;
      debugPrint('⏰ [BOOKING CONFIRMATION] booking_timeout for bookingId=$id');
      if (mounted) setState(() => _timedOut = true);
    });

    _slotNoAvailSub = SocketService.instance.onSlotNoAvailability.listen((e) {
      if (e.bookingId != widget.bookingId || !mounted) return;
      debugPrint('⚠️ [BOOKING CONFIRMATION] slot_no_availability  times=${e.timeIntervals.length} slots=${e.slots.length}');
      _searchTimer?.cancel();
      setState(() {
        _slotNoAvail        = true;
        _slotNoAvailMessage = e.message;
        _altTimeIntervals   = e.timeIntervals;
        _altSlots           = e.slots;
        _pickedAltTime      = null;
        _pickedAltSlot      = null;
      });
    });

    _searchTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _secondsSearched++);
      if (_secondsSearched >= AppConstants.bookingSearchTimeoutSeconds) {
        _searchTimer?.cancel();
        if (mounted) setState(() => _timedOut = true);
      }
    });
  }

  @override
  void dispose() {
    _dotCtrl.dispose();
    _pulseCtrl.dispose();
    _acceptedSub?.cancel();
    _timeoutSub?.cancel();
    _slotNoAvailSub?.cancel();
    _searchTimer?.cancel();
    super.dispose();
  }

  void _onAccepted(BookingAcceptedEvent event) {
    if (_accepted) return;
    setState(() => _accepted = true);
    _searchTimer?.cancel();
    HapticFeedback.mediumImpact();

    // Persist active lab booking so patient can reopen tracking from dashboard
    SocketService.instance.setActiveLabBooking(ActiveLabBookingInfo(
      bookingId:     widget.bookingId,
      patientId:     widget.patientId,
      trackingId:    event.trackingId,
      technicianId:  event.technicianId,
      technicianName: event.technicianName,
      patientLat:    widget.patientLat,
      patientLng:    widget.patientLng,
      patientAddress: widget.patientAddress,
    ));

    Future.delayed(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (_, anim, __) => TrackingMapScreen(
            bookingId:      widget.bookingId,
            patientId:      widget.patientId,
            trackingId:     event.trackingId,
            technicianId:   event.technicianId,
            technicianName: event.technicianName,
            patientLat:     widget.patientLat,
            patientLng:     widget.patientLng,
            patientAddress: widget.patientAddress,
          ),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    });
  }

  void _restartSearch() {
    _searchTimer?.cancel();
    _searchTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _secondsSearched++);
      if (_secondsSearched >= AppConstants.bookingSearchTimeoutSeconds) {
        _searchTimer?.cancel();
        if (mounted) setState(() => _timedOut = true);
      }
    });
  }

  // Re-dispatch with a different master slot (clears appointment time)
  void _retryWithNewSlot(SlotOption slot) {
    setState(() {
      _currentSlotId               = slot.slotId;
      _currentSlotLabel            = slot.label;
      _currentAppointmentTime      = null;
      _currentAppointmentTimeLabel = null;
      _slotNoAvail                 = false;
      _slotNoAvailMessage          = '';
      _altTimeIntervals            = [];
      _altSlots                    = [];
      _pickedAltTime               = null;
      _pickedAltSlot               = null;
      _timedOut                    = false;
      _secondsSearched             = 0;
    });
    SocketService.instance.emitBookingRequest(
      bookingId:      widget.bookingId,
      patientId:      widget.patientId,
      patientName:    widget.patientName,
      patientMobile:  widget.patientMobile,
      patientAddress: widget.patientAddress,
      patientLat:     widget.patientLat,
      patientLng:     widget.patientLng,
      hospital:       widget.hospital,
      branchId:       widget.branchId,
      branchName:     widget.branchName,
      slotId:         _currentSlotId,
      slotLabel:      _currentSlotLabel,
      // no appointmentTime — new slot, no time selected yet
    );
    _restartSearch();
  }

  // Re-dispatch with a different appointment time in the same slot
  void _retryWithNewTime(AppointmentTimeOption t) {
    setState(() {
      _currentAppointmentTime      = t.time;
      _currentAppointmentTimeLabel = t.label;
      _slotNoAvail                 = false;
      _slotNoAvailMessage          = '';
      _altTimeIntervals            = [];
      _altSlots                    = [];
      _pickedAltTime               = null;
      _pickedAltSlot               = null;
      _timedOut                    = false;
      _secondsSearched             = 0;
    });
    SocketService.instance.emitBookingRequest(
      bookingId:       widget.bookingId,
      patientId:       widget.patientId,
      patientName:     widget.patientName,
      patientMobile:   widget.patientMobile,
      patientAddress:  widget.patientAddress,
      patientLat:      widget.patientLat,
      patientLng:      widget.patientLng,
      hospital:        widget.hospital,
      branchId:        widget.branchId,
      branchName:      widget.branchName,
      slotId:          _currentSlotId,
      slotLabel:       _currentSlotLabel,
      appointmentTime: _currentAppointmentTime,
    );
    _restartSearch();
  }

  void _cancel() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Cancel Search?',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        content: const Text(
          'Stop looking for a technician and go back?',
          style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('No',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () {
              SocketService.instance.emitCancelSearch(
                bookingId: widget.bookingId,
                patientId: widget.patientId,
              );
              Navigator.pop(context);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD32F2F),
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Yes, Cancel',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark
          .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: AppColors.white,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 16),

                // Back / cancel
                Row(
                  children: [
                    GestureDetector(
                      onTap: _cancel,
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          border: Border.all(color: AppColors.divider),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.close_rounded,
                            size: 18, color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),

                const Spacer(),

                // ── Accepted state ────────────────────────────────────────
                if (_accepted) ...[
                  Container(
                    width: 80,
                    height: 80,
                    decoration: const BoxDecoration(
                        color: AppColors.brandGreenSurface,
                        shape: BoxShape.circle),
                    child: const Icon(Icons.check_circle_rounded,
                        color: AppColors.brandGreen, size: 44),
                  ),
                  const SizedBox(height: 24),
                  const Text('Technician Found!',
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 8),
                  const Text('Opening tracking map…',
                      style: TextStyle(
                          fontSize: 14, color: AppColors.textSecondary)),
                ]

                // ── Slot no-availability state ────────────────────────────
                else if (_slotNoAvail) ...[
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF8E1),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: const Color(0xFFF9A825).withValues(alpha: 0.3)),
                    ),
                    child: const Icon(Icons.schedule_outlined,
                        color: Color(0xFFF9A825), size: 40),
                  ),
                  const SizedBox(height: 20),
                  const Text('Slot Unavailable',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 10),
                  Text(
                    _slotNoAvailMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                        height: 1.5),
                  ),
                  // ── Alternate appointment times (same slot) ───────────
                  if (_altTimeIntervals.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Other available times:',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _altTimeIntervals.map((t) {
                        final picked = _pickedAltTime?.time == t.time;
                        return ChoiceChip(
                          label: Text(t.label,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: picked ? Colors.white : AppColors.textPrimary)),
                          selected: picked,
                          selectedColor: AppColors.brandGreen,
                          backgroundColor: AppColors.background,
                          side: BorderSide(
                              color: picked ? AppColors.brandGreen : AppColors.divider),
                          onSelected: (_) => setState(() {
                            _pickedAltTime = t;
                            _pickedAltSlot = null; // mutually exclusive
                          }),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _pickedAltTime != null
                            ? () => _retryWithNewTime(_pickedAltTime!)
                            : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.brandGreen,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor:
                              AppColors.brandGreen.withValues(alpha: 0.4),
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        child: const Text('Try at this time',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],

                  // ── Alternate slots ───────────────────────────────────
                  if (_altSlots.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _altTimeIntervals.isNotEmpty ? 'Or choose another slot:' : 'Available slots:',
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary)),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _altSlots.map((s) {
                        final picked = _pickedAltSlot?.slotId == s.slotId;
                        return ChoiceChip(
                          label: Text(s.label,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: picked ? Colors.white : AppColors.textPrimary)),
                          selected: picked,
                          selectedColor: AppColors.brandGreen,
                          backgroundColor: AppColors.background,
                          side: BorderSide(
                              color: picked ? AppColors.brandGreen : AppColors.divider),
                          onSelected: (_) => setState(() {
                            _pickedAltSlot = s;
                            _pickedAltTime = null; // mutually exclusive
                          }),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _pickedAltSlot != null
                            ? () => _retryWithNewSlot(_pickedAltSlot!)
                            : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.brandGreen,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor:
                              AppColors.brandGreen.withValues(alpha: 0.4),
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        child: const Text('Try with this slot',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textSecondary,
                        side: const BorderSide(color: AppColors.divider),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text('Go Back',
                          style: TextStyle(fontSize: 15)),
                    ),
                  ),
                ]

                // ── Timeout state ─────────────────────────────────────────
                else if (_timedOut) ...[
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: const Color(0xFFD32F2F).withValues(alpha: 0.2))),
                    child: const Icon(Icons.person_off_outlined,
                        color: Color(0xFFD32F2F), size: 40),
                  ),
                  const SizedBox(height: 24),
                  const Text('No Technician Available',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 8),
                  const Text(
                    'All nearby technicians are busy.\nPlease try again later.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 14, color: AppColors.textSecondary,
                        height: 1.5),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.brandGreen,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text('Go Back',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  ),
                ]

                // ── Searching state ───────────────────────────────────────
                else ...[
                  // Pulsing ring
                  AnimatedBuilder(
                    animation: _pulseCtrl,
                    builder: (_, __) => Container(
                      width: 120 + 20 * _pulseCtrl.value,
                      height: 120 + 20 * _pulseCtrl.value,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.brandGreen
                            .withValues(alpha: 0.05 * (1 - _pulseCtrl.value)),
                      ),
                      child: Center(
                        child: Container(
                          width: 100,
                          height: 100,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.brandGreenSurface,
                          ),
                          child: const Icon(Icons.search_rounded,
                              color: AppColors.brandGreen, size: 44),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 32),

                  const Text('Finding Technician…',
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary)),

                  const SizedBox(height: 10),

                  // Animated dots subtitle
                  AnimatedBuilder(
                    animation: _dotCtrl,
                    builder: (_, __) {
                      final dots = '.' * ((_dotCtrl.value * 3).floor() + 1);
                      return Text(
                        'Searching nearby technicians$dots',
                        style: const TextStyle(
                            fontSize: 14, color: AppColors.textSecondary),
                      );
                    },
                  ),

                  const SizedBox(height: 32),

                  // 3 pulsing indicator dots
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(3, (i) {
                      final delay = i / 3;
                      return AnimatedBuilder(
                        animation: _dotCtrl,
                        builder: (_, __) {
                          final v = ((_dotCtrl.value + delay) % 1.0);
                          final scale = 0.6 + 0.4 * (v < 0.5 ? v * 2 : (1 - v) * 2);
                          return Container(
                            margin: const EdgeInsets.symmetric(horizontal: 6),
                            width: 12 * scale,
                            height: 12 * scale,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.brandGreen
                                  .withValues(alpha: 0.3 + 0.7 * scale),
                            ),
                          );
                        },
                      );
                    }),
                  ),

                  const SizedBox(height: 40),

                  // Booking details summary card
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.divider),
                    ),
                    child: Column(
                      children: [
                        _SummaryRow(Icons.tag_rounded,
                            'Booking ID', '#${widget.bookingId}'),
                        const SizedBox(height: 8),
                        _SummaryRow(Icons.home_outlined,
                            'Pickup', widget.patientAddress),
                        const SizedBox(height: 8),
                        _SummaryRow(Icons.local_hospital_outlined,
                            'Destination', widget.hospital),
                        if (_currentSlotLabel != null) ...[
                          const SizedBox(height: 8),
                          _SummaryRow(Icons.schedule_outlined,
                              'Slot', _currentSlotLabel!),
                        ],
                        if (_currentAppointmentTimeLabel != null) ...[
                          const SizedBox(height: 8),
                          _SummaryRow(Icons.access_time_outlined,
                              'Time', _currentAppointmentTimeLabel!),
                        ],
                      ],
                    ),
                  ),
                ],

                const Spacer(),

                // Cancel button (only during active search)
                if (!_accepted && !_timedOut && !_slotNoAvail) ...[
                  TextButton(
                    onPressed: _cancel,
                    child: const Text('Cancel Search',
                        style: TextStyle(
                            color: AppColors.textSecondary, fontSize: 13)),
                  ),
                  const SizedBox(height: 16),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _SummaryRow(this.icon, this.label, this.value);

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: AppColors.brandGreen),
          const SizedBox(width: 8),
          SizedBox(
            width: 80,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary)),
          ),
        ],
      );
}
