import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/auth_service.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/screens/shared/onboarding_screen.dart';
import 'add_member_screen.dart';
import 'my_bookings_screen.dart';
import 'customer_dashboard_screen.dart';
import 'package:microlab/models.dart';
import 'reports_screen.dart';
import 'profile_screen.dart';
import 'support_chatbot.dart';
import 'package:microlab/widgets/skeleton_loader.dart';


// ─── Screen ───────────────────────────────────────────────────────────────────

class CustomerHomeScreen extends StatefulWidget {
  final String mobile;
  final bool isVip;
  const CustomerHomeScreen({
    super.key,
    required this.mobile,
    this.isVip = false,
  });

  @override
  State<CustomerHomeScreen> createState() => _CustomerHomeScreenState();
}

class _CustomerHomeScreenState extends State<CustomerHomeScreen> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _selectedIndex = 0;
  MemberModel? _activeMember;
  List<MemberModel> _members = [];
  bool _loadingPatients = true;
  final _bookingsRefresh = ValueNotifier<int>(0);
  final _reportsRefresh  = ValueNotifier<int>(0);

  // Home: who "Book Test" books for (header "Booking for: … ▾"), remembered
  // on this phone; null = Self. Falls back to Self when that member is gone.
  static const _bookingForKey = 'home_booking_for_member_id';
  String? _bookingForId;
  // Home "Your Recent Bookings": the latest booking of anyone on the account.
  Map<String, dynamic>? _recentBooking;
  bool _loadingRecent = true;

  @override
  void initState() {
    super.initState();
    _loadPatients();
    _loadBookingFor();
    _loadRecentBooking();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadPatients();
      _loadRecentBooking();
    }
  }

  Future<void> _loadBookingFor() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(_bookingForKey);
      if (mounted && id != null) setState(() => _bookingForId = id);
    } catch (_) {}
  }

  void _setBookingFor(MemberModel m) {
    setState(() => _bookingForId = m.id);
    SharedPreferences.getInstance()
        .then((p) => p.setString(_bookingForKey, m.id))
        .catchError((_) => false);
  }

  // The selected member, else Self, else the first member.
  MemberModel? get _bookingFor {
    for (final m in _members) {
      if (m.id == _bookingForId) return m;
    }
    return _selfMember ?? (_members.isNotEmpty ? _members.first : null);
  }

  Future<void> _loadRecentBooking() async {
    try {
      final list = await ApiService.getMyBookings(); // newest first
      if (!mounted) return;
      setState(() {
        _recentBooking = list.isNotEmpty ? list.first : null;
        _loadingRecent = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingRecent = false);
    }
  }

  // "Book Test" / "Book your next test": opens the usual booking screen for
  // the selected member. No members yet → add one first, then book for them.
  Future<void> _startBooking() async {
    final m = _bookingFor;
    if (m != null) {
      setState(() => _activeMember = m);
      return;
    }
    final added = await _openAddMember(select: true);
    if (added != null && mounted) setState(() => _activeMember = added);
  }

  void _pickBookingFor() {
    if (_loadingPatients) return;
    final current = _bookingFor;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 14),
                decoration: BoxDecoration(
                    color: AppColors.divider, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Who is this test for?',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final m in [
                    if (_selfMember != null) _selfMember!,
                    ..._members.where((m) => m.id != _selfMember?.id),
                  ])
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: AppColors.brandGreenSurface,
                        child: Text(m.name.isNotEmpty ? m.name[0].toUpperCase() : '?',
                            style: const TextStyle(
                                color: AppColors.brandGreen, fontWeight: FontWeight.w700)),
                      ),
                      title: Text(m.name,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      subtitle: m.relation != null
                          ? Text(m.relation!, style: const TextStyle(fontSize: 12))
                          : null,
                      trailing: m.id == current?.id
                          ? const Icon(Icons.check_circle_rounded, color: AppColors.brandGreen)
                          : null,
                      onTap: () {
                        Navigator.pop(ctx);
                        _setBookingFor(m);
                      },
                    ),
                  ListTile(
                    leading: const CircleAvatar(
                      backgroundColor: AppColors.brandGreenSurface,
                      child: Icon(Icons.person_add_alt_1_rounded,
                          color: AppColors.brandGreen, size: 20),
                    ),
                    title: const Text('Add member',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.brandGreen)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _openAddMember(select: true);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _loadPatients() async {
    try {
      final patients = await ApiService.getPatients();
      if (!mounted) return;
      setState(() {
        _members = patients.map(_patientToMember).toList();
        _loadingPatients = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingPatients = false);
    }
  }

  // The primary/self profile is the row with patient_relation = 'Self' (same
  // convention the server uses — see patientsController.js's ORDER BY and its
  // `rawPatients.find(p => p.relation === 'Self')`). Falls back to a mobile match,
  // then null — the chatbot's own inline login form covers "not loaded yet".
  String? get _selfPatientId {
    for (final m in _members) {
      if (m.relation?.toLowerCase() == 'self') return m.id;
    }
    for (final m in _members) {
      if (m.mobile == widget.mobile) return m.id;
    }
    return null;
  }

  // Same lookup as _selfPatientId, but returns the member itself — used by the
  // welcome header to show the logged-in customer's own first name.
  MemberModel? get _selfMember {
    for (final m in _members) {
      if (m.relation?.toLowerCase() == 'self') return m;
    }
    for (final m in _members) {
      if (m.mobile == widget.mobile) return m;
    }
    return null;
  }

  static String? _firstName(String? full) {
    if (full == null || full.trim().isEmpty) return null;
    return full.trim().split(RegExp(r'\s+')).first;
  }

  static DateTime? _parseDob(String? s) {
    if (s == null || s.isEmpty) return null;
    final parts = s.split('-');
    if (parts.length != 3) return null;
    try {
      if (parts[0].length == 4) {
        return DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
      }
      return DateTime(int.parse(parts[2]), int.parse(parts[1]), int.parse(parts[0]));
    } catch (_) { return null; }
  }

  MemberModel _patientToMember(PatientModel p) => MemberModel(
    id:              p.patientId.toString(),
    name:            p.name,
    mobile:          (p.mobile != null && p.mobile!.isNotEmpty) ? p.mobile! : widget.mobile,
    gender:          p.gender,
    location:        p.location,
    address:         p.address,
    email:           p.email,
    dob:             _parseDob(p.dateOfBirth),
    relation:        p.relation,
    healthCondition: p.healthCondition,
    photoBytes:      null,
    photoUrl:        (p.photo != null && p.photo!.isNotEmpty) ? p.photo : null,
    patientIdRef:    p.patientIdRef,
    isReadOnly:      p.patientIdRef != null,
  );

  Future<void> _logout() async {
    SocketService.instance.disconnect();

    // Release the server-side session so the single-active-session lock
    // frees up for another device — AuthService.logout() below only clears
    // this device's local state, it never talks to the server. Best-effort:
    // navigation must never get stuck waiting on the network, and if this
    // fails the number stays locked until the token's natural 30-day expiry
    // rather than trapping the user on this screen.
    final token = await AuthService.getToken();
    if (token != null && token.isNotEmpty) {
      try {
        await ApiService.logout(token);
      } catch (e) {
        debugPrint('[_logout] server logout failed: $e');
      }
    }

    await AuthService.logout();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const OnboardingScreen()),
        (route) => false,
      );
    }
  }

  // select: the new member becomes "Booking for" (added from the Home
  // dropdown or before a first booking).
  Future<MemberModel?> _openAddMember({bool select = false}) async {
    final result = await Navigator.push<MemberModel>(
      context,
      MaterialPageRoute(builder: (_) => const AddMemberScreen()),
    );
    if (result != null && mounted) {
      setState(() => _members.add(result));
      if (select) _setBookingFor(result);
    }
    return result;
  }

  void _openEditMember(MemberModel member) async {
    final result = await Navigator.push<MemberModel>(
      context,
      MaterialPageRoute(
          builder: (_) => AddMemberScreen(existingMember: member)),
    );
    if (result != null) {
      setState(() {
        final idx = _members.indexWhere((m) => m.id == result.id);
        if (idx != -1) _members[idx] = result;
      });
    }
  }

  void _viewMember(MemberModel member) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MemberDetailSheet(member: member),
    );
  }

  void _confirmDelete(String id, String name) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove customer?',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        content: Text(
          '$name will be removed from your account.',
          style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await ApiService.deletePatient(id);
                if (mounted) setState(() => _members.removeWhere((m) => m.id == id));
              } catch (_) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Could not remove customer. Please try again.'),
                    backgroundColor: Color(0xFFD32F2F),
                  ));
                }
              }
            },
            child: const Text('Remove',
                style: TextStyle(
                    color: Color(0xFFD32F2F), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bookingsRefresh.dispose();
    _reportsRefresh.dispose();
    super.dispose();
  }

  void _onNavTap(int index) {
    setState(() {
      _selectedIndex = index;
      if (index != 0) _activeMember = null;
    });
    if (index == 1) _bookingsRefresh.value++;
    if (index == 2) _reportsRefresh.value++;
  }

  bool get _inDashboard => _selectedIndex == 0 && _activeMember != null;
  int get _stackIndex => _selectedIndex == 0
      ? (_activeMember != null ? 1 : 0)
      : _selectedIndex + 1;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (!_inDashboard && _selectedIndex == 0)
          ? SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent)
          : SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent),
      child: PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_activeMember != null) {
          setState(() => _activeMember = null);
          _loadRecentBooking();
        }
      },
      child: Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppColors.background,
      appBar: (!_inDashboard && _selectedIndex == 0)
          ? PreferredSize(
              preferredSize: const Size.fromHeight(142),
              child: Container(
                color: AppColors.brandGreen,
                child: SafeArea(
                  bottom: false,
                  child: Stack(
                    children: [
                      Positioned(
                        right: -8,
                        top: 30,
                        child: Icon(Icons.science_outlined,
                            size: 110, color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 6, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Logo row + call
                            Row(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.asset('assets/icon/app_icon.png',
                                      width: 32, height: 32, fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const Icon(
                                          Icons.biotech_rounded, color: Colors.white, size: 28)),
                                ),
                                const SizedBox(width: 10),
                                const Expanded(
                                  child: Text('MicroLab',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 20,
                                          fontWeight: FontWeight.w700)),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.phone_outlined,
                                      color: Colors.white, size: 22),
                                  tooltip: 'Call us',
                                  onPressed: () async {
                                    final uri = Uri(scheme: 'tel', path: '7339535472');
                                    if (await canLaunchUrl(uri)) launchUrl(uri);
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            // Greeting = the account holder; "Booking for" =
                            // who Book Test books for.
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 24,
                                  backgroundColor: Colors.white,
                                  child: Text(
                                    (_firstName(_selfMember?.name) ?? 'U')[0].toUpperCase(),
                                    style: const TextStyle(
                                        color: AppColors.brandGreen,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 18),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Welcome, ${_firstName(_selfMember?.name) ?? 'there'}!',
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 19,
                                            fontWeight: FontWeight.w700),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 6),
                                      GestureDetector(
                                        onTap: _pickBookingFor,
                                        child: Container(
                                          padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
                                          decoration: BoxDecoration(
                                            color: Colors.white.withValues(alpha: 0.16),
                                            borderRadius: BorderRadius.circular(20),
                                            border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  _loadingPatients
                                                      ? 'Booking for: …'
                                                      : 'Booking for: ${_bookingFor == null ? 'Add member' : _bookingFor!.id == _selfMember?.id ? 'Self' : _firstName(_bookingFor!.name)}',
                                                  style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 12.5,
                                                      fontWeight: FontWeight.w600),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                              const Icon(Icons.keyboard_arrow_down_rounded,
                                                  color: Colors.white, size: 18),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : null,
      body: Stack(
        children: [
          IndexedStack(
            index: _stackIndex,
            children: [
              _homeBody(),
              // Slot 1: embedded dashboard
              if (_activeMember != null)
                SafeArea(
                  top: false,
                  bottom: false,
                  child: CustomerDashboardScreen(
                    key: ValueKey(_activeMember!.id),
                    member: _activeMember!,
                    isVip: widget.isVip,
                    embedded: true,
                    onBack: () {
                      setState(() => _activeMember = null);
                      _loadRecentBooking(); // a booking may have just been made
                    },
                  ),
                )
              else
                const SizedBox.shrink(),
              SafeArea(top: false, bottom: false, child: MyBookingsScreen(embedded: true, refreshTrigger: _bookingsRefresh)),
              SafeArea(top: false, bottom: false, child: ReportsScreen(embedded: true, refreshTrigger: _reportsRefresh)),
              // Slot 4: profile
              SafeArea(
                top: false,
                bottom: false,
                child: ProfileScreen(
                  mobile: widget.mobile,
                  isVip: widget.isVip,
                  members: _members,
                  embedded: true,
                  onAddMember: _openAddMember,
                  onEditMember: _openEditMember,
                  // Moved here from the old Customers tab.
                  onViewMember: _viewMember,
                  onRemoveMember: (m) => _confirmDelete(m.id, m.name),
                  onLogout: _logout,
                ),
              ),
            ],
          ),
          // Chatbot FAB — patientId is the logged-in customer's own self profile;
          // null (not loaded yet / no self record) falls back to the inline login form.
          Positioned(
            right: 16,
            bottom: 110,
            child: SupportChatbotButton(patientId: _selfPatientId),
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
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.calendar_month_outlined),
            activeIcon: Icon(Icons.calendar_month),
            label: 'Bookings',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.receipt_long_outlined),
            activeIcon: Icon(Icons.receipt_long),
            label: 'Reports',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_outline_rounded),
            activeIcon: Icon(Icons.person_rounded),
            label: 'Profile',
          ),
        ],
      ),
    ), // Scaffold
    ), // PopScope
    ); // AnnotatedRegion
  }


  // ── Home tab ───────────────────────────────────────────────────────────────
  Widget _homeBody() {
    return RefreshIndicator(
      color: AppColors.brandGreen,
      onRefresh: () => Future.wait([_loadPatients(), _loadRecentBooking()]),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
        children: [
          // Book your next test
          _HomeCard(
            color: AppColors.brandGreenSurface,
            onTap: _startBooking,
            child: Row(children: [
              Container(
                width: 48, height: 48,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                child: const Icon(Icons.water_drop_rounded, color: AppColors.brandGreen, size: 24),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Book your next test',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  SizedBox(height: 3),
                  Text('Quick  •  Safe  •  Reliable',
                      style: TextStyle(fontSize: 12.5, color: AppColors.brandGreen, fontWeight: FontWeight.w500)),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
            ]),
          ),
          const SizedBox(height: 22),

          // Your Recent Bookings — latest booking of anyone on the account
          Row(children: [
            const Expanded(
              child: Text('Your Recent Bookings',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
            ),
            GestureDetector(
              onTap: () => _onNavTap(1),
              child: const Row(children: [
                Text('View All',
                    style: TextStyle(fontSize: 13, color: AppColors.brandGreen, fontWeight: FontWeight.w600)),
                Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.brandGreen),
              ]),
            ),
          ]),
          const SizedBox(height: 10),
          _recentBookingCard(),
          const SizedBox(height: 22),

          // Quick Actions
          const Text('Quick Actions',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
          const SizedBox(height: 10),
          Row(children: [
            _QuickAction(icon: Icons.event_available_rounded, label: 'Book Test',
                color: AppColors.brandGreen, onTap: _startBooking),
            const SizedBox(width: 10),
            _QuickAction(icon: Icons.calendar_month_rounded, label: 'View Bookings',
                color: const Color(0xFF1565C0), onTap: () => _onNavTap(1)),
            const SizedBox(width: 10),
            _QuickAction(icon: Icons.description_rounded, label: 'Reports',
                color: const Color(0xFF6A4BC4), onTap: () => _onNavTap(2)),
            const SizedBox(width: 10),
            _QuickAction(icon: Icons.person_outline_rounded, label: 'Profile',
                color: const Color(0xFFE07B39), onTap: () => _onNavTap(3)),
          ]),
          const SizedBox(height: 22),

          // Trusted Diagnostics — information only
          const _HomeCard(
            color: AppColors.brandGreenSurface,
            child: Row(children: [
              Icon(Icons.verified_user_rounded, color: AppColors.brandGreen, size: 34),
              SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Trusted Diagnostics',
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  SizedBox(height: 3),
                  Text('Accurate results for a healthier you',
                      style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                ]),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  // Latest booking (getMyBookings is newest first). Tap → Bookings tab.
  Widget _recentBookingCard() {
    if (_loadingRecent) {
      return SkeletonShimmer(
        child: SkeletonBox(height: 92, borderRadius: BorderRadius.circular(14)),
      );
    }
    final b = _recentBooking;
    if (b == null) {
      return _HomeCard(
        onTap: _startBooking,
        child: const Row(children: [
          Icon(Icons.event_note_outlined, color: AppColors.textHint, size: 28),
          SizedBox(width: 12),
          Expanded(
            child: Text('No bookings yet — book your first test',
                style: TextStyle(fontSize: 13.5, color: AppColors.textSecondary)),
          ),
          Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
        ]),
      );
    }

    // test_items: "id:::name:::price:::type:::instructions|||…"
    final names = (b['test_items'] as String? ?? '')
        .split('|||')
        .map((t) => t.split(':::'))
        .where((p) => p.length > 1 && p[1].trim().isNotEmpty)
        .map((p) => p[1].trim())
        .toList();
    final title = names.isEmpty
        ? 'Blood Test'
        : names.length == 1 ? names.first : '${names.first} +${names.length - 1} more';
    final date  = DateTime.tryParse(b['collection_date']?.toString() ?? '');
    final time  = b['slot_time_formatted'] as String?;
    final place = b['booking_type'] == 'home_collection'
        ? (b['collection_city'] as String?)
        : (b['branch_name'] as String?);
    final patient = b['patient_name'] as String?;
    final status  = _statusLabel(b['booking_status'] as String? ?? '');
    final (Color fg, Color bg) = switch (b['booking_status']) {
      'cancelled' => (const Color(0xFFD32F2F), const Color(0xFFFFEBEE)),
      'completed' => (AppColors.brandGreen, AppColors.brandGreenSurface),
      _           => (const Color(0xFF1565C0), const Color(0xFFE3F2FD)),
    };

    return _HomeCard(
      onTap: () => _onNavTap(1),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 48, height: 48,
          decoration: const BoxDecoration(color: AppColors.brandGreenSurface, shape: BoxShape.circle),
          child: const Icon(Icons.science_outlined, color: AppColors.brandGreen, size: 24),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
                child: Text(status, style: TextStyle(fontSize: 11, color: fg, fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 5),
            Text(
              [
                if (date != null) _fmtDate(date),
                if (time != null && time.isNotEmpty) time,
              ].join('  •  '),
              style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
            ),
            if ((place ?? '').isNotEmpty || (patient ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(children: [
                const Icon(Icons.location_on_outlined, size: 13, color: AppColors.textHint),
                const SizedBox(width: 3),
                Expanded(
                  child: Text(
                    [if ((place ?? '').isNotEmpty) place!, if ((patient ?? '').isNotEmpty) 'For ${_firstName(patient)}']
                        .join('  •  '),
                    style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ]),
            ],
          ]),
        ),
        const Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
      ]),
    );
  }

  // Same labels as My Bookings.
  static String _statusLabel(String raw) => switch (raw) {
        'pending'               => 'Pending',
        'scheduled'             => 'Scheduled',
        'confirmed'             => 'Confirmed',
        'assigned'              => 'Technician Allocated',
        'arrived'               => 'Technician Arrived',
        'collected'             => 'Sample Collected',
        'submitted'             => 'Handed to Lab',
        'handed_to_lab_pending' => 'Handed to Lab',
        'completed'             => 'Completed',
        'cancelled'             => 'Cancelled',
        _ => raw.isNotEmpty ? raw[0].toUpperCase() + raw.substring(1) : 'Unknown',
      };

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  static String _fmtDate(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';
}

// ─── Home building blocks ─────────────────────────────────────────────────────

class _HomeCard extends StatelessWidget {
  final Widget child;
  final Color color;
  final VoidCallback? onTap;
  const _HomeCard({required this.child, this.color = Colors.white, this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: color,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.divider),
            ),
            child: child,
          ),
        ),
      );
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _QuickAction({required this.icon, required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Material(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 4),
              child: Column(children: [
                Icon(icon, color: color, size: 28),
                const SizedBox(height: 8),
                Text(label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppColors.textPrimary)),
              ]),
            ),
          ),
        ),
      );
}

// ─── Reusable photo-aware avatar ─────────────────────────────────────────────

class _MemberAvatar extends StatelessWidget {
  final Uint8List? photoBytes;
  final String? photoUrl;
  final String initials;
  final Color avatarColor;
  final double size;
  final double fontSize;

  const _MemberAvatar({
    required this.photoBytes,
    this.photoUrl,
    required this.initials,
    required this.avatarColor,
    required this.size,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final hasBytes = photoBytes != null && photoBytes!.isNotEmpty;
    final hasUrl   = photoUrl   != null && photoUrl!.isNotEmpty;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: avatarColor.withValues(alpha: 0.1),
        shape: BoxShape.circle,
        border: (hasBytes || hasUrl)
            ? Border.all(color: avatarColor.withValues(alpha: 0.3), width: 1.5)
            : null,
      ),
      child: ClipOval(
        child: hasBytes
            ? Image.memory(
                photoBytes!,
                fit: BoxFit.cover,
                width: size,
                height: size,
                errorBuilder: (_, __, ___) => hasUrl ? _networkImage() : _initials(),
              )
            : hasUrl
                ? _networkImage()
                : _initials(),
      ),
    );
  }

  Widget _networkImage() => Image.network(
    photoUrl!,
    fit: BoxFit.cover,
    width: size,
    height: size,
    errorBuilder: (_, __, ___) => _initials(),
    loadingBuilder: (_, child, progress) =>
        progress == null ? child : _initials(),
  );

  Widget _initials() => Center(
        child: Text(initials,
            style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                color: avatarColor)),
      );
}

// ─── Member Detail Bottom Sheet ───────────────────────────────────────────────

class _MemberDetailSheet extends StatelessWidget {
  final MemberModel member;
  const _MemberDetailSheet({required this.member});

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  Color get _avatarColor {
    switch (member.gender) {
      case 'Female': return const Color(0xFFAD1457);
      case 'Other': return const Color(0xFF6A1B9A);
      default: return AppColors.brandGreen;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      // Cap at 85% screen height so it never covers the full screen
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Scrollable content
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                  20, 0, 20, MediaQuery.of(context).padding.bottom + 24),
              child: Column(
                children: [

          // Avatar + name
          _MemberAvatar(
            photoBytes: member.photoBytes,
            photoUrl: member.photoUrl,
            initials: member.name.isNotEmpty
                ? member.name[0].toUpperCase()
                : '?',
            avatarColor: _avatarColor,
            size: 88,
            fontSize: 32,
          ),
          const SizedBox(height: 10),
          Text(member.name,
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary)),
          if (member.relation != null) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.brandGreenSurface,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(member.relation!,
                  style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.brandGreen,
                      fontWeight: FontWeight.w500)),
            ),
          ],

          const SizedBox(height: 20),

          // Detail rows
          _DetailRow(
              icon: Icons.phone_outlined,
              label: 'Mobile',
              value: '+91 ${member.mobile}'),
          if (member.gender.isNotEmpty)
            _DetailRow(
                icon: Icons.wc_outlined,
                label: 'Gender',
                value: member.gender),
          if (member.dob != null)
            _DetailRow(
                icon: Icons.cake_outlined,
                label: 'Date of Birth',
                value:
                    '${_formatDate(member.dob!)}  •  ${member.age} yrs'),
          if (member.email != null && member.email!.isNotEmpty)
            _DetailRow(
                icon: Icons.email_outlined,
                label: 'Email',
                value: member.email!),
          if (member.location.isNotEmpty)
            _DetailRow(
                icon: Icons.location_on_outlined,
                label: 'Location',
                value: member.location),
          if (member.address.isNotEmpty)
            _DetailRow(
                icon: Icons.home_outlined,
                label: 'Address',
                value: member.address),
          if (member.healthCondition != null &&
              member.healthCondition!.isNotEmpty)
            _DetailRow(
                icon: Icons.medical_information_outlined,
                label: 'Health Condition',
                value: member.healthCondition!),

          const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _DetailRow(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.brandGreen),
          const SizedBox(width: 12),
          SizedBox(
            width: 100,
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
      ),
    );
  }
}


