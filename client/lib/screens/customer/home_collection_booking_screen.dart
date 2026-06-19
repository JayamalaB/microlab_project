// home_collection_booking_screen.dart
//
// Flow:
//  1. Patient sees their own profile info (pre-filled, read-only).
//  2. Picks collection location (home address or GPS pin).
//  3. Selects target lab / hospital where samples will be sent.
//  4. Reviews tests summary from their cart.
//  5. Taps "Book Collection" → emits booking_request via SocketService.
//  6. Waiting screen: pulse ring + "Finding technician…"
//  7. On booking_accepted → auto-pushes to TrackingMapScreen.
//  8. No response / declined → shows retry option.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/models.dart';
import 'tracking_map_screen.dart';

// ── Screen ─────────────────────────────────────────────────────────────────────

class HomeCollectionBookingScreen extends StatefulWidget {
  final MemberModel member;
  final List<TestModel> cart;
  final int patientId;

  /// Textual address from the location sheet (typed or detected via pincode).
  final String? manualAddress;

  /// Geocoded / GPS coordinates — null when only a text address was entered.
  final double? patientLat;
  final double? patientLng;

  const HomeCollectionBookingScreen({
    super.key,
    required this.member,
    required this.cart,
    required this.patientId,
    this.manualAddress,
    this.patientLat,
    this.patientLng,
  });

  @override
  State<HomeCollectionBookingScreen> createState() =>
      _HomeCollectionBookingScreenState();
}

enum _Phase { form, waiting, accepted, declined }

class _HomeCollectionBookingScreenState
    extends State<HomeCollectionBookingScreen> {
  // ── Socket subscriptions ───────────────────────────────────────────────────
  StreamSubscription<BookingAcceptedEvent>? _acceptedSub;
  StreamSubscription<int>? _timeoutSub;

  // ── State ──────────────────────────────────────────────────────────────────
  _Phase _phase = _Phase.form;
  int? _bookingId;
  String? _technicianName;

  // 'home' = member's saved address, 'gps' = GPS / geocoded coordinates
  String _locationChoice = 'home';

  String? _selectedLab;
  final TextEditingController _labCtrl = TextEditingController();

  Timer? _searchTimer;
  int _secondsSearched = 0;

  static const List<String> _labs = [
    'Apollo Diagnostics',
    'Thyrocare',
    'SRL Diagnostics',
    'Lal PathLabs',
    'Dr. Lal Clinical Lab',
    'Metropolis Healthcare',
    'Other (type below)',
  ];

  // ── Init ───────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    // Default to GPS mode when coordinates are available
    if (widget.patientLat != null) _locationChoice = 'gps';

    _acceptedSub = SocketService.instance.onBookingAccepted.listen((event) {
      if (_bookingId == null || event.bookingId != _bookingId || !mounted) {
        return;
      }
      _onAccepted(event);
    });

    _timeoutSub = SocketService.instance.onBookingTimeout.listen((id) {
      if (_bookingId == null || id != _bookingId || !mounted) return;
      _searchTimer?.cancel();
      setState(() => _phase = _Phase.declined);
    });
  }

  @override
  void dispose() {
    _acceptedSub?.cancel();
    _timeoutSub?.cancel();
    _searchTimer?.cancel();
    _labCtrl.dispose();
    super.dispose();
  }

  // ── Computed helpers ────────────────────────────────────────────────────────
  bool get _useGps =>
      _locationChoice == 'gps' && widget.patientLat != null;

  String get _collectionAddress {
    if (_useGps) {
      final addr = widget.manualAddress;
      if (addr != null && addr.isNotEmpty) return addr;
      return 'GPS: ${widget.patientLat!.toStringAsFixed(5)}, '
          '${widget.patientLng!.toStringAsFixed(5)}';
    }
    return widget.member.address.isNotEmpty
        ? widget.member.address
        : (widget.manualAddress ?? '');
  }

  double? get _collectionLat => _useGps ? widget.patientLat : null;
  double? get _collectionLng => _useGps ? widget.patientLng : null;

  double get _testsTotal =>
      widget.cart.fold(0.0, (s, t) => s + t.finalPrice);

  String _gpsSubtitle() {
    if (widget.patientLat == null) return 'No GPS location available';
    final addr = widget.manualAddress;
    if (addr != null && addr.isNotEmpty) {
      final coordsOnly = RegExp(r'^-?\d+\.\d+\s*,\s*-?\d+\.\d+$');
      if (!coordsOnly.hasMatch(addr.trim())) return addr;
    }
    return 'GPS: ${widget.patientLat!.toStringAsFixed(5)}, '
        '${widget.patientLng!.toStringAsFixed(5)}';
  }

  // ── Book collection ─────────────────────────────────────────────────────────
  void _bookCollection() {
    final lab = _selectedLab == 'Other (type below)'
        ? _labCtrl.text.trim()
        : (_selectedLab ?? '');

    if (lab.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Please select the target lab / hospital')),
      );
      return;
    }
    if (_collectionAddress.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Please set a valid collection address')),
      );
      return;
    }

    final id = DateTime.now().millisecondsSinceEpoch % 1000000;
    _bookingId = id;

    SocketService.instance.registerPatientSocket(
      patientId: widget.patientId,
      bookingId: id,
    );
    SocketService.instance.emitBookingRequest(
      bookingId:      id,
      patientId:      widget.patientId,
      patientName:    widget.member.name,
      patientMobile:  widget.member.mobile,
      patientAddress: _collectionAddress,
      patientLat:     _collectionLat,
      patientLng:     _collectionLng,
      hospital:       lab,
    );

    _secondsSearched = 0;
    _searchTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _secondsSearched++);
      if (_secondsSearched >= AppConstants.bookingSearchTimeoutSeconds) {
        t.cancel();
        if (mounted) setState(() => _phase = _Phase.declined);
      }
    });

    HapticFeedback.mediumImpact();
    setState(() => _phase = _Phase.waiting);
  }

  // ── Accepted handler ────────────────────────────────────────────────────────
  void _onAccepted(BookingAcceptedEvent event) {
    _searchTimer?.cancel();
    HapticFeedback.mediumImpact();

    setState(() {
      _technicianName = event.technicianName;
      _phase = _Phase.accepted;
    });

    // Persist so patient can reopen tracking from dashboard
    SocketService.instance.setActiveLabBooking(ActiveLabBookingInfo(
      bookingId:      _bookingId!,
      patientId:      widget.patientId,
      trackingId:     event.trackingId,
      technicianId:   event.technicianId,
      technicianName: event.technicianName,
      patientLat:     _collectionLat,
      patientLng:     _collectionLng,
      patientAddress: _collectionAddress,
    ));

    Future.delayed(const Duration(milliseconds: 1800), () {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        _slideRoute(TrackingMapScreen(
          bookingId:      _bookingId!,
          patientId:      widget.patientId,
          trackingId:     event.trackingId,
          technicianId:   event.technicianId,
          technicianName: event.technicianName,
          patientLat:     _collectionLat,
          patientLng:     _collectionLng,
          patientAddress: _collectionAddress,
        )),
      );
    });
  }

  // ── Retry ───────────────────────────────────────────────────────────────────
  void _retry() {
    _searchTimer?.cancel();
    setState(() {
      _phase = _Phase.form;
      _secondsSearched = 0;
      _bookingId = null;
    });
  }

  // ── Build ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark
          .copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: Colors.white,
          foregroundColor: AppColors.textPrimary,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          title: const Text(
            'Book Sample Collection',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: AppColors.divider),
          ),
        ),
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: switch (_phase) {
            _Phase.form     => _buildForm(),
            _Phase.waiting  => _buildWaiting(),
            _Phase.accepted => _buildAccepted(),
            _Phase.declined => _buildDeclined(),
          },
        ),
      ),
    );
  }

  // ── Form phase ─────────────────────────────────────────────────────────────
  Widget _buildForm() {
    final m = widget.member;
    final hasGps = widget.patientLat != null;
    final hasHome = m.address.isNotEmpty || widget.manualAddress != null;

    return SingleChildScrollView(
      key: const ValueKey('form'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── Patient info card ──────────────────────────────────────────
          _card(
            child: Row(children: [
              _avatar(m.name),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                            color: AppColors.textPrimary)),
                    const SizedBox(height: 2),
                    if (m.mobile.isNotEmpty)
                      _infoRow(Icons.phone_outlined, m.mobile),
                    if (m.age != null || m.gender.isNotEmpty)
                      Row(children: [
                        if (m.age != null) ...[
                          _infoRow(Icons.cake_outlined, '${m.age} yrs'),
                          const SizedBox(width: 10),
                        ],
                        if (m.gender.isNotEmpty)
                          _infoRow(Icons.person_outline, m.gender),
                      ]),
                  ],
                ),
              ),
              _badge('Patient', AppColors.brandGreen,
                  AppColors.brandGreenSurface),
            ]),
          ),

          const SizedBox(height: 16),

          // ── Collection location card ───────────────────────────────────
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionHeader(
                  Icons.home_work_rounded,
                  AppColors.brandGreen,
                  'Collection Location',
                  'Where should the technician come?',
                ),
                const SizedBox(height: 14),

                // Home address option
                _locationOption(
                  value: 'home',
                  icon: Icons.home_rounded,
                  iconColor: const Color(0xFF7C3AED),
                  title: 'Home Address',
                  subtitle: m.address.isNotEmpty
                      ? m.address
                      : (widget.manualAddress ?? 'No home address saved'),
                  enabled: hasHome,
                ),
                const SizedBox(height: 8),

                // GPS option
                _locationOption(
                  value: 'gps',
                  icon: Icons.my_location_rounded,
                  iconColor: AppColors.brandGreen,
                  title: 'GPS Location',
                  subtitle: _gpsSubtitle(),
                  enabled: hasGps,
                  badge: 'GPS',
                  badgeColor: AppColors.brandGreen,
                ),

                const SizedBox(height: 12),

                // Contextual hint
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _useGps
                      ? _hintRow(
                          Icons.navigation_rounded,
                          AppColors.brandGreen,
                          'Technician will use GPS to navigate directly '
                          'to your pinned location.',
                          key: const ValueKey('hint_gps'),
                        )
                      : _hintRow(
                          Icons.info_outline_rounded,
                          const Color(0xFFF57C00),
                          'Address-only pickup — technician navigates '
                          'by text, no GPS route.',
                          key: const ValueKey('hint_home'),
                        ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Tests summary card ─────────────────────────────────────────
          if (widget.cart.isNotEmpty) ...[
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader(
                    Icons.science_rounded,
                    const Color(0xFF3949AB),
                    '${widget.cart.length} '
                    'Test${widget.cart.length == 1 ? '' : 's'} Selected',
                    'Total: ₹${_testsTotal.toStringAsFixed(0)}',
                  ),
                  const SizedBox(height: 12),
                  const Divider(height: 1, color: AppColors.divider),
                  const SizedBox(height: 10),
                  ...widget.cart.take(4).map(
                    (t) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                              color: AppColors.brandGreen,
                              shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(t.name,
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textPrimary)),
                        ),
                        Text(
                          '₹${t.finalPrice.toStringAsFixed(0)}',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary),
                        ),
                      ]),
                    ),
                  ),
                  if (widget.cart.length > 4)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '+${widget.cart.length - 4} more tests',
                        style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // ── Target lab card ────────────────────────────────────────────
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionHeader(
                  Icons.local_hospital_rounded,
                  const Color(0xFF0288D1),
                  'Target Lab / Hospital',
                  'Where will the samples be delivered?',
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: _selectedLab,
                  hint: const Text('Select lab or hospital',
                      style: TextStyle(fontSize: 14)),
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            const BorderSide(color: AppColors.divider)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide:
                            const BorderSide(color: AppColors.divider)),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(
                          color: AppColors.brandGreen, width: 2),
                    ),
                    prefixIcon: const Icon(Icons.search_rounded,
                        color: AppColors.brandGreen, size: 20),
                    contentPadding: const EdgeInsets.symmetric(
                        vertical: 14, horizontal: 12),
                  ),
                  items: _labs
                      .map((l) =>
                          DropdownMenuItem(value: l, child: Text(l)))
                      .toList(),
                  onChanged: (v) => setState(() => _selectedLab = v),
                ),
                if (_selectedLab == 'Other (type below)') ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _labCtrl,
                    decoration: InputDecoration(
                      labelText: 'Lab / hospital name',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: AppColors.brandGreen, width: 2),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 28),

          // ── Book button ────────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _bookCollection,
              icon: const Icon(Icons.science_rounded, size: 20),
              label: const Text(
                'Book Collection Now',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brandGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Waiting phase ──────────────────────────────────────────────────────────
  Widget _buildWaiting() {
    return Center(
      key: const ValueKey('waiting'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const _PulseRing(color: AppColors.brandGreen),
            const SizedBox(height: 32),
            const Text(
              'Finding a Technician…',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary),
            ),
            const SizedBox(height: 10),
            Text(
              'Booking #${_bookingId ?? '—'}',
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textHint),
            ),
            const SizedBox(height: 8),
            const Text(
              'Checking nearby technicians — this may take a moment…',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: 200,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: const LinearProgressIndicator(
                  minHeight: 4,
                  backgroundColor: AppColors.divider,
                  color: AppColors.brandGreen,
                ),
              ),
            ),
            const SizedBox(height: 32),
            TextButton(
              onPressed: _retry,
              child: const Text(
                'Cancel request',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Accepted phase ─────────────────────────────────────────────────────────
  Widget _buildAccepted() {
    return Center(
      key: const ValueKey('accepted'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                color: AppColors.brandGreenSurface,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_rounded,
                  color: AppColors.brandGreen, size: 48),
            ),
            const SizedBox(height: 24),
            const Text(
              'Technician Found!',
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary),
            ),
            const SizedBox(height: 8),
            if (_technicianName != null)
              Text(
                '$_technicianName is on the way',
                style: const TextStyle(
                    fontSize: 15, color: AppColors.textSecondary),
              ),
            const SizedBox(height: 24),
            const CircularProgressIndicator(color: AppColors.brandGreen),
            const SizedBox(height: 16),
            const Text(
              'Opening tracking map…',
              style: TextStyle(
                  fontSize: 13, color: AppColors.textHint),
            ),
          ],
        ),
      ),
    );
  }

  // ── Declined / timeout phase ───────────────────────────────────────────────
  Widget _buildDeclined() {
    return Center(
      key: const ValueKey('declined'),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFFFEF2F2),
                shape: BoxShape.circle,
                border: Border.all(
                    color: const Color(0xFFD32F2F)
                        .withValues(alpha: 0.2)),
              ),
              child: const Icon(Icons.person_off_rounded,
                  color: Color(0xFFD32F2F), size: 44),
            ),
            const SizedBox(height: 24),
            const Text(
              'No Technician Available',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary),
            ),
            const SizedBox(height: 8),
            const Text(
              'All nearby technicians are busy right now.\n'
              'Please try again in a few minutes.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textSecondary,
                  height: 1.5),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text(
                  'Try Again',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.brandGreen,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(vertical: 14),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text(
                'Go back',
                style: TextStyle(
                    color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Shared widget helpers ──────────────────────────────────────────────────

  Widget _locationOption({
    required String value,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required bool enabled,
    String? badge,
    Color? badgeColor,
  }) {
    final selected = _locationChoice == value;
    return GestureDetector(
      onTap: enabled ? () => setState(() => _locationChoice = value) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.brandGreen.withValues(alpha: 0.06)
              : Colors.grey.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.brandGreen : AppColors.divider,
            width: selected ? 1.8 : 1,
          ),
        ),
        child: Row(children: [
          Icon(icon,
              size: 20,
              color: enabled ? iconColor : AppColors.textHint),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(title,
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: enabled
                              ? AppColors.textPrimary
                              : AppColors.textHint)),
                  if (badge != null && enabled) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: (badgeColor ?? AppColors.brandGreen)
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(badge,
                          style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: badgeColor ??
                                  AppColors.brandGreen)),
                    ),
                  ],
                ]),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      color: enabled
                          ? AppColors.textSecondary
                          : AppColors.textHint),
                ),
              ],
            ),
          ),
          if (selected)
            const Icon(Icons.check_circle_rounded,
                color: AppColors.brandGreen, size: 20)
          else
            Icon(Icons.radio_button_unchecked_rounded,
                color: enabled
                    ? AppColors.textHint
                    : AppColors.divider,
                size: 20),
        ]),
      ),
    );
  }

  Widget _hintRow(IconData icon, Color color, String text,
          {Key? key}) =>
      Container(
        key: key,
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 11,
                    color: color,
                    fontWeight: FontWeight.w500)),
          ),
        ]),
      );

  Widget _sectionHeader(
          IconData icon, Color color, String title, String subtitle) =>
      Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: AppColors.textPrimary)),
              Text(subtitle,
                  style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textHint)),
            ],
          ),
        ),
      ]);

  Widget _card({required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: child,
      );

  Widget _avatar(String name) {
    final parts = name.trim().split(' ');
    final initials = parts.length >= 2
        ? '${parts[0][0]}${parts[1][0]}'.toUpperCase()
        : (name.isNotEmpty ? name[0].toUpperCase() : '?');
    return Container(
      width: 48,
      height: 48,
      decoration: const BoxDecoration(
          color: Color(0xFF1A2340), shape: BoxShape.circle),
      child: Center(
        child: Text(initials,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 16)),
      ),
    );
  }

  Widget _badge(String text, Color fg, Color bg) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
          border:
              Border.all(color: fg.withValues(alpha: 0.3)),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 11,
                color: fg,
                fontWeight: FontWeight.w600)),
      );

  Widget _infoRow(IconData icon, String text) => Row(children: [
        Icon(icon, size: 12, color: AppColors.textHint),
        const SizedBox(width: 4),
        Text(text,
            style: const TextStyle(
                fontSize: 12, color: AppColors.textSecondary)),
      ]);

  Route _slideRoute(Widget page) => PageRouteBuilder(
        pageBuilder: (_, a, __) => page,
        transitionsBuilder: (_, a, __, child) => SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(
              CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child,
        ),
      );
}

// ── Animated pulse ring ─────────────────────────────────────────────────────

class _PulseRing extends StatefulWidget {
  final Color color;
  const _PulseRing({required this.color});

  @override
  State<_PulseRing> createState() => _PulseRingState();
}

class _PulseRingState extends State<_PulseRing>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat();
    _scale = Tween<double>(begin: 0.6, end: 1.4).animate(_ctrl);
    _opacity = Tween<double>(begin: 0.8, end: 0.0).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 100,
        height: 100,
        child: Stack(alignment: Alignment.center, children: [
          AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => Opacity(
              opacity: _opacity.value,
              child: Transform.scale(
                scale: _scale.value,
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: widget.color.withValues(alpha: 0.5),
                        width: 2),
                  ),
                ),
              ),
            ),
          ),
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color.withValues(alpha: 0.15),
            ),
            child: Icon(Icons.science_rounded,
                color: widget.color, size: 28),
          ),
        ]),
      );
}
