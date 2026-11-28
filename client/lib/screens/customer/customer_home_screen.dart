import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
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
import 'saved_addresses_screen.dart';
import 'package:microlab/widgets/skeleton_loader.dart';
import 'package:microlab/utils/app_messages.dart';
import 'package:microlab/widgets/customer/cx_widgets.dart';


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
  MemberModel? _dashboardMember; // kept alive in IndexedStack even when back is pressed
  List<MemberModel> _members = [];
  String? _accountName;
  final Map<String, BookingDraft> _drafts = {};
  int _dashboardRebuildKey = 0;
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

  // "Book Test" / quick actions: opens the booking screen for the selected
  // member. Pass [mode] to pre-select 'Home Collection' or 'Lab Test'.
  // No members yet → add one first, then book for them.
  Future<void> _startBooking({String? mode}) async {
    // Always treat the mode as chosen so the dashboard shows the location
    // warning immediately — even when no specific mode was passed (e.g. search
    // bar tap), default to Home Collection.
    final effectiveMode = mode ?? 'Home Collection';
    final m = _bookingFor;
    if (m != null) {
      // Preserve cart but override mode. Increment rebuild key so the
      // IndexedStack creates a fresh dashboard widget that reads the new draft
      // in initState (the existing widget ignores initialDraft changes).
      _drafts[m.id] = BookingDraft(
        cart:       _drafts[m.id]?.cart ?? [],
        mode:       effectiveMode,
        modeChosen: true,
      );
      _dashboardRebuildKey++;
      setState(() { _activeMember = m; _dashboardMember = m; });
      return;
    }
    final added = await _openAddMember(select: true);
    if (added != null && mounted) {
      _drafts[added.id] = BookingDraft(mode: effectiveMode, modeChosen: true);
      _dashboardRebuildKey++;
      setState(() { _activeMember = added; _dashboardMember = added; });
    }
  }

  void _pickBookingFor() {
    if (_loadingPatients) return;
    final current = _bookingFor;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => CustomerThemeScope(
        child: CxSheetFrame(
          title: 'Family members',
          child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final m in [
                    if (_selfMember != null) _selfMember!,
                    ..._members.where((m) => m.id != _selfMember?.id),
                  ])
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      shape: const RoundedRectangleBorder(borderRadius: CxRadius.mdAll),
                      selected: m.id == current?.id,
                      selectedTileColor: CxColors.brandSurface,
                      leading: CircleAvatar(
                        backgroundColor: AppColors.brandGreenSurface,
                        child: Text(m.name.isNotEmpty ? m.name[0].toUpperCase() : '?',
                            style: const TextStyle(
                                color: AppColors.brandGreen, fontWeight: FontWeight.w700)),
                      ),
                      title: Text(m.name,
                          style: CxText.cardTitle),
                      subtitle: m.relation != null
                          ? Text(m.relation!, style: CxText.caption)
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
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    shape: const RoundedRectangleBorder(borderRadius: CxRadius.mdAll),
                    leading: const CircleAvatar(
                      backgroundColor: AppColors.brandGreenSurface,
                      child: Icon(Icons.person_add_alt_1_rounded,
                          color: AppColors.brandGreen, size: 20),
                    ),
                    title: const Text('Add member',
                        style: TextStyle(
                            fontSize: 15,
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
      ),
    );
  }

  Future<void> _loadPatients() async {
    try {
      final prefs   = await SharedPreferences.getInstance();
      final accName = prefs.getString('user_name');
      final patients = await ApiService.getPatients();
      if (!mounted) return;
      setState(() {
        _members      = patients.map(_patientToMember).toList();
        _accountName  = accName;
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

  Future<void> _confirmLogout(BuildContext ctx) async {
    final confirmed = await showCxConfirm(
      ctx,
      icon: Icons.logout_rounded,
      title: 'Logout?',
      message: 'Are you sure you want to logout from MicroLab?',
      confirmLabel: 'Logout',
      destructive: true,
    );
    if (confirmed == true) _logout();
  }

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

  void _openFamilyMembers() {
    final self = _selfMember;
    final nonSelf = _members.where((m) => m.id != (self?.id ?? '')).toList();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FamilyMembersScreen(
          initialMembers: nonSelf,
          selfId: self?.id ?? '',
          onAdd: () => _openAddMember(),
          onEdit: (m) async {
            final result = await Navigator.push<MemberModel>(
              context,
              MaterialPageRoute(builder: (_) => AddMemberScreen(existingMember: m)),
            );
            if (result != null && mounted) {
              setState(() {
                final idx = _members.indexWhere((x) => x.id == result.id);
                if (idx != -1) _members[idx] = result;
              });
            }
            return result;
          },
          onRemove: _deleteMemberAsync,
        ),
      ),
    ).then((_) => _loadPatients());
  }

  Future<bool> _deleteMemberAsync(MemberModel m) async {
    final confirmed = await showCxConfirm(
      context,
      icon: Icons.person_remove_outlined,
      title: 'Remove customer?',
      message: '${m.name} will be removed from your account.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (confirmed != true) return false;
    try {
      await ApiService.deletePatient(m.id);
      if (mounted) setState(() => _members.removeWhere((x) => x.id == m.id));
      return true;
    } catch (_) {
      if (mounted) AppMessages.error(context, 'Could not remove customer. Please try again.');
      return false;
    }
  }

  void _openSavedAddresses() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => const SavedAddressesScreen()));
  }

  void _openSupportChatbot() {
    showSupportChatbot(context, patientId: _selfPatientId);
  }

  Future<void> _deleteAccount() async {
    final token = await AuthService.getToken();
    if (token == null) return;
    final ok = await ApiService.deleteAccount(token);
    if (!mounted) return;
    if (ok) {
      SocketService.instance.disconnect();
      await AuthService.logout();
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const OnboardingScreen()),
          (route) => false,
        );
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to delete account. Please try again.')),
      );
    }
  }

  void _openUploadPrescription() {
    final member = _bookingFor ?? _selfMember ?? (_members.isNotEmpty ? _members.first : null);
    if (member == null) {
      AppMessages.error(context, 'Please add a family member first.');
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PrescriptionUploadSheet(member: member),
    );
  }

  void _openNearestBranch() {
    final member = _selfMember;
    final addr = [member?.address, member?.location]
        .where((s) => s != null && s.trim().isNotEmpty)
        .join(', ');
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _NearestBranchSheet(defaultAddress: addr.isNotEmpty ? addr : null),
    );
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
      builder: (_) => CxDialog(
        icon: Icons.person_remove_outlined,
        tone: CxTone.error,
        title: 'Remove customer?',
        message: '$name will be removed from your account.',
        actions: [
          CxButton.secondary(
            onPressed: () => Navigator.pop(context),
            label: 'Cancel',
            compact: true,
          ),
          CxButton.destructive(
            compact: true,
            label: 'Remove',
            onPressed: () async {
              Navigator.pop(context);
              try {
                await ApiService.deletePatient(id);
                if (mounted) setState(() => _members.removeWhere((m) => m.id == id));
              } catch (_) {
                if (mounted) {
                  AppMessages.error(context, 'Could not remove customer. Please try again.');
                }
              }
            },
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
      // Customer look for the home shell (each tab also applies it).
      child: CustomerThemeScope(
      child: Scaffold(
      key: _scaffoldKey,
      backgroundColor: CxColors.page,
      appBar: (!_inDashboard && _selectedIndex == 0)
          ? PreferredSize(
              preferredSize: const Size.fromHeight(88),
              child: Container(
                color: AppColors.brandGreen,
                child: SafeArea(
                  bottom: false,
                  child: Stack(
                    children: [
                      Positioned(
                        right: 56,
                        top: -10,
                        child: Icon(Icons.science_outlined,
                            size: 100, color: Colors.white.withValues(alpha: 0.08)),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Greeting = the account holder; "Booking for" =
                            // who Book Test books for.
                            GestureDetector(
                              onTap: () => _onNavTap(3),
                              child: Row(
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
                                      const SizedBox(height: 4),
                                      Semantics(
                                        button: true,
                                        label: 'Change who this booking is for',
                                        child: Material(
                                        color: Colors.white.withValues(alpha: 0.16),
                                        shape: StadiumBorder(
                                          side: BorderSide(color: Colors.white.withValues(alpha: 0.35)),
                                        ),
                                        clipBehavior: Clip.antiAlias,
                                        child: InkWell(
                                        onTap: _pickBookingFor,
                                        child: Container(
                                          padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
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
                                                      fontSize: 13,
                                                      fontWeight: FontWeight.w600),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                              const Icon(Icons.keyboard_arrow_down_rounded,
                                                  color: Colors.white, size: 20),
                                            ],
                                          ),
                                        ),
                                        ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                // Call MicroLab — phone icon in a circle.
                                Material(
                                  color: Colors.white.withValues(alpha: 0.16),
                                  shape: CircleBorder(
                                      side: BorderSide(color: Colors.white.withValues(alpha: 0.35))),
                                  child: InkWell(
                                    customBorder: const CircleBorder(),
                                    onTap: () async {
                                      final uri = Uri(scheme: 'tel', path: '18004251316');
                                      if (await canLaunchUrl(uri)) launchUrl(uri);
                                    },
                                    child: const Tooltip(
                                      message: 'Call us',
                                      child: SizedBox(
                                        width: 44,
                                        height: 44,
                                        child: Icon(Icons.phone_rounded, color: Colors.white, size: 22),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Logout
                                Material(
                                  color: Colors.white.withValues(alpha: 0.16),
                                  shape: CircleBorder(
                                      side: BorderSide(color: Colors.white.withValues(alpha: 0.35))),
                                  child: InkWell(
                                    customBorder: const CircleBorder(),
                                    onTap: () => _confirmLogout(context),
                                    child: const Tooltip(
                                      message: 'Logout',
                                      child: SizedBox(
                                        width: 44,
                                        height: 44,
                                        child: Icon(Icons.logout_rounded, color: Colors.white, size: 22),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
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
              // Slot 1: embedded dashboard — kept alive via _dashboardMember so
              // back-press (which only clears _activeMember) does not destroy state.
              if (_dashboardMember != null)
                SafeArea(
                  top: false,
                  bottom: false,
                  child: CustomerDashboardScreen(
                    key: ValueKey('${_dashboardMember!.id}_$_dashboardRebuildKey'),
                    member: _dashboardMember!,
                    isVip: widget.isVip,
                    embedded: true,
                    onBack: () {
                      setState(() => _activeMember = null);
                      _loadRecentBooking();
                    },
                    initialDraft: _drafts[_dashboardMember!.id],
                    onDraftSave: (draft) => _drafts[_dashboardMember!.id] = draft,
                    onMemberAdded: _loadPatients,
                  ),
                )
              else
                const SizedBox.shrink(),
              SafeArea(top: false, bottom: false, child: MyBookingsScreen(embedded: true, refreshTrigger: _bookingsRefresh)),
              SafeArea(top: false, bottom: false, child: ReportsScreen(embedded: true, refreshTrigger: _reportsRefresh, onViewBookings: () => _onNavTap(1))),
              // Slot 4: profile
              SafeArea(
                top: false,
                bottom: false,
                child: ProfileScreen(
                  mobile: widget.mobile,
                  isVip: widget.isVip,
                  members: _members,
                  accountName: _accountName,
                  embedded: true,
                  onAddMember: _openAddMember,
                  onEditMember: _openEditMember,
                  onViewMember: _viewMember,
                  onRemoveMember: (m) => _confirmDelete(m.id, m.name),
                  onLogout: _logout,
                  onFamilyMembers: _openFamilyMembers,
                  onSavedAddresses: _openSavedAddresses,
                  onBookingHistory: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const MyBookingsScreen()),
                  ),
                  onHealthRecords: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => ReportsScreen(onViewBookings: () {
                      Navigator.pop(context);
                      _onNavTap(1);
                    })),
                  ),
                  onHelpSupport: _openSupportChatbot,
                  onDeleteAccount: _deleteAccount,
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
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: CxColors.border)),
          boxShadow: [BoxShadow(color: Color(0x0F000000), blurRadius: 12, offset: Offset(0, -2))],
        ),
        child: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: _onNavTap,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: CxColors.brand,
        unselectedItemColor: CxColors.textSecondary,
        backgroundColor: Colors.white,
        selectedLabelStyle:
            const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        selectedIconTheme: const IconThemeData(size: 26),
        unselectedIconTheme: const IconThemeData(size: 24),
        elevation: 0,
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
      ),
    ), // Scaffold
    ), // CustomerThemeScope
    ), // PopScope
    ); // AnnotatedRegion
  }


  // ── Home tab ───────────────────────────────────────────────────────────────
  Widget _homeBody() {
    return RefreshIndicator(
      color: AppColors.brandGreen,
      onRefresh: () => Future.wait([_loadPatients(), _loadRecentBooking()]),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(CxSpace.gutter, CxSpace.lg, CxSpace.gutter, 120),
        children: [
          // Search bar — tapping opens the booking / test-search flow
          GestureDetector(
            onTap: _startBooking,
            child: Container(
              height: 52,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.07), blurRadius: 8, offset: const Offset(0, 2)),
                ],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(children: [
                Icon(Icons.search_rounded, color: Colors.grey.shade400, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Search tests & packages...',
                    style: TextStyle(fontSize: 15, color: Colors.grey.shade400, fontWeight: FontWeight.w400),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: CxColors.brand.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.tune_rounded, color: CxColors.brand, size: 18),
                ),
              ]),
            ),
          ),
          const SizedBox(height: CxSpace.xxl),

          // Your Recent Bookings — latest booking of anyone on the account
          Row(children: [
            const Expanded(
              child: Text('Your Recent Bookings', style: CxText.sectionTitle),
            ),
            TextButton(
              onPressed: () => _onNavTap(1),
              style: TextButton.styleFrom(
                foregroundColor: CxColors.brand,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(48, 40),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Text('View All',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                Icon(Icons.chevron_right_rounded, size: 20),
              ]),
            ),
          ]),
          const SizedBox(height: CxSpace.sm),
          _recentBookingCard(),
          const SizedBox(height: CxSpace.xxl),

          // Quick Actions — 2×2 grid
          const Text('Quick Actions', style: CxText.sectionTitle),
          const SizedBox(height: CxSpace.md),
          Row(children: [
            _QuickAction(
              icon: Icons.home_outlined,
              label: 'Home Collection',
              subtitle: 'Technician visits you',
              color: AppColors.brandGreen,
              onTap: () => _startBooking(mode: 'Home Collection'),
            ),
            const SizedBox(width: 10),
            _QuickAction(
              icon: Icons.science_outlined,
              label: 'Book Lab Visit',
              subtitle: 'Walk-in appointment',
              color: CxColors.info,
              onTap: () => _startBooking(mode: 'Lab Test'),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _QuickAction(
              icon: Icons.upload_file_rounded,
              label: 'Upload Prescription',
              subtitle: 'Get tests prescribed',
              color: const Color(0xFF6A4BC4),
              onTap: _openUploadPrescription,
            ),
            const SizedBox(width: 10),
            _QuickAction(
              icon: Icons.location_on_outlined,
              label: 'Nearest Branch',
              subtitle: 'Find labs near you',
              color: CxColors.offer,
              onTap: _openNearestBranch,
            ),
          ]),
          const SizedBox(height: CxSpace.xxl),

          // Trusted Diagnostics — feature strip
          Container(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
            decoration: BoxDecoration(
              color: AppColors.brandGreenSurface,
              borderRadius: CxRadius.lgAll,
              border: Border.all(color: AppColors.brandGreenLight),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(children: [
                  Icon(Icons.verified_user_rounded, color: AppColors.brandGreen, size: 20),
                  SizedBox(width: 8),
                  Text('Trusted Diagnostics', style: CxText.cardTitle),
                ]),
                const SizedBox(height: 14),
                Row(children: [
                  const _FeatureBadge(icon: Icons.biotech_outlined,  label: '1000+\nTests'),
                  const SizedBox(width: 10),
                  const _FeatureBadge(icon: Icons.verified_outlined, label: 'Certified\nLabs'),
                  const SizedBox(width: 10),
                  const _FeatureBadge(icon: Icons.home_outlined,     label: 'Home\nCollection'),
                  const SizedBox(width: 10),
                  const _FeatureBadge(icon: Icons.flash_on_rounded,  label: 'Fast\nReports'),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Latest booking (getMyBookings is newest first). Tap → Bookings tab.
  Widget _recentBookingCard() {
    if (_loadingRecent) {
      return const SkeletonShimmer(
        child: SkeletonBox(height: 92, borderRadius: CxRadius.lgAll),
      );
    }
    final b = _recentBooking;
    if (b == null) {
      return _HomeCard(
        onTap: _startBooking,
        child: const Row(children: [
          CxIconBadge(icon: Icons.event_note_outlined, tone: CxTone.neutral, size: 44),
          SizedBox(width: 12),
          Expanded(
            child: Text('No bookings yet — book your first test', style: CxText.body),
          ),
          Icon(Icons.chevron_right_rounded, color: CxColors.textHint),
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
      'cancelled' => (CxColors.error, CxColors.errorSurface),
      'completed' => (AppColors.brandGreen, AppColors.brandGreenSurface),
      _           => (CxColors.info, CxColors.infoSurface),
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
                    style: CxText.cardTitle,
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: bg, borderRadius: CxRadius.pill),
                child: Text(status, style: TextStyle(fontSize: 12, color: fg, fontWeight: FontWeight.w600)),
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
        'en_route'              => 'Technician On the Way',
        'arrived'               => 'Technician Arrived',
        'collection_started'    => 'Collection In Progress',
        'sample_collected'      => 'Sample Collected',
        'collected'             => 'Sample Collected', // older value
        'otp_verified'          => 'Sample Collected',
        'submitted'             => 'Handed to Lab',
        'handed_to_lab_pending' => 'Handed to Lab',
        'handed_to_lab'         => 'Handed to Lab',
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
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(
          borderRadius: CxRadius.lgAll,
          boxShadow: [BoxShadow(color: Color(0x0D000000), blurRadius: 10, offset: Offset(0, 2))],
        ),
        child: Material(
        color: color,
        shape: RoundedRectangleBorder(
          borderRadius: CxRadius.lgAll,
          side: BorderSide(color: color == Colors.white ? CxColors.border : Colors.transparent),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(CxSpace.lg),
            child: child,
          ),
        ),
        ),
      );
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final Color color;
  final VoidCallback onTap;
  const _QuickAction({
    required this.icon,
    required this.label,
    this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Expanded(
        child: Material(
          color: Colors.white,
          shape: const RoundedRectangleBorder(
            borderRadius: CxRadius.lgAll,
            side: BorderSide(color: CxColors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
              child: Row(children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: CxRadius.mdAll),
                  child: Icon(icon, color: color, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: CxColors.textPrimary)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: CxColors.textHint)),
                    ],
                  ]),
                ),
              ]),
            ),
          ),
        ),
      );
}

class _FeatureBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  const _FeatureBadge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: CxRadius.mdAll,
            border: Border.all(color: AppColors.brandGreenLight),
          ),
          child: Column(children: [
            Icon(icon, color: AppColors.brandGreen, size: 20),
            const SizedBox(height: 5),
            Text(label,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: AppColors.brandGreen)),
          ]),
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
    return CustomerThemeScope(
      child: Align(
      alignment: Alignment.bottomCenter,
      child: Container(
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: CxRadius.sheetTop,
      ),
      // Cap at 85% screen height so it never covers the full screen
      constraints: BoxConstraints(
        maxWidth: CxSize.sheetMaxWidth,
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          const CxSheetHandleBar(),

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
          Text(member.name, style: CxText.pageTitle),
          if (member.relation != null) ...[
            const SizedBox(height: 6),
            CxChip(label: member.relation!, tone: CxTone.brand),
          ],

          const SizedBox(height: CxSpace.xl),

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
      ),
      ),
    );
  }
}

// ─── Nearest Branch Sheet ─────────────────────────────────────────────────────

class _NearestBranchSheet extends StatefulWidget {
  final String? defaultAddress;
  const _NearestBranchSheet({this.defaultAddress});

  @override
  State<_NearestBranchSheet> createState() => _NearestBranchSheetState();
}

class _NearestBranchSheetState extends State<_NearestBranchSheet> {
  late final TextEditingController _addrCtrl;
  bool _loading = false;
  String? _error;
  List<({BranchModel branch, double? distKm})> _sorted = [];
  List<BranchModel>? _allBranches;

  @override
  void initState() {
    super.initState();
    _addrCtrl = TextEditingController(text: widget.defaultAddress ?? '');
    // Auto-search on open if we have an address; otherwise just load branches.
    _search();
  }

  @override
  void dispose() {
    _addrCtrl.dispose();
    super.dispose();
  }

  static double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLon = (lon2 - lon1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * sin(dLon / 2) * sin(dLon / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  // Geocode via Nominatim (OpenStreetMap — free, no key needed).
  // Returns null if the address can't be resolved.
  Future<({double lat, double lng})?> _geocode(String address) async {
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': address,
        'format': 'json',
        'limit': '1',
        'countrycodes': 'in',
      });
      final res = await http.get(uri, headers: {
        'User-Agent': 'microlab-flutter-app/1.0',
        'Accept-Language': 'en',
      }).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final list = jsonDecode(res.body) as List<dynamic>;
        if (list.isNotEmpty) {
          final r = list.first as Map<String, dynamic>;
          final lat = double.tryParse(r['lat']?.toString() ?? '');
          final lng = double.tryParse(r['lon']?.toString() ?? '');
          if (lat != null && lng != null) return (lat: lat, lng: lng);
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _search() async {
    setState(() { _loading = true; _error = null; });
    try {
      _allBranches ??= await ApiService.getBranches();
      final branches = _allBranches!;

      final addr = _addrCtrl.text.trim();
      double? refLat, refLng;

      if (addr.isNotEmpty) {
        final coords = await _geocode(addr);
        if (coords != null) {
          refLat = coords.lat;
          refLng = coords.lng;
        }
      }

      final sorted = branches.map((b) {
        double? dist;
        if (refLat != null && refLng != null && b.lat != null && b.lng != null) {
          dist = _haversine(refLat, refLng, b.lat!, b.lng!);
        }
        return (branch: b, distKm: dist);
      }).toList();

      sorted.sort((a, b) {
        if (a.distKm == null && b.distKm == null) return 0;
        if (a.distKm == null) return 1;
        if (b.distKm == null) return -1;
        return a.distKm!.compareTo(b.distKm!);
      });

      if (mounted) {
        setState(() {
          _sorted = sorted;
          _loading = false;
          if (addr.isNotEmpty && refLat == null) {
            _error = 'Could not locate that address. Try entering a pincode or city name.';
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = 'Could not load branches. Please try again.'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return CustomerThemeScope(
      child: CxSheetFrame(
        title: 'Nearest Branches',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Address input
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _addrCtrl,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    hintText: 'Enter address, city or pincode',
                    hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                    prefixIcon: const Icon(Icons.location_on_outlined, size: 20),
                    filled: true,
                    fillColor: CxColors.page,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: CxRadius.mdAll,
                      borderSide: const BorderSide(color: CxColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: CxRadius.mdAll,
                      borderSide: const BorderSide(color: CxColors.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: CxRadius.mdAll,
                      borderSide: BorderSide(color: CxColors.brand, width: 1.5),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: _loading ? null : _search,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: CxColors.brand,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: CxRadius.mdAll),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    elevation: 0,
                  ),
                  child: _loading
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.search_rounded, size: 22),
                ),
              ),
            ]),

            if (_error != null) ...[
              const SizedBox(height: 10),
              Row(children: [
                const Icon(Icons.info_outline, size: 16, color: CxColors.textSecondary),
                const SizedBox(width: 6),
                Expanded(child: Text(_error!, style: CxText.caption)),
              ]),
            ],

            const SizedBox(height: 12),

            if (!_loading && _sorted.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('No branches found.', style: CxText.bodySecondary)),
              )
            else
              Column(
                mainAxisSize: MainAxisSize.min,
                children: _sorted.map((entry) {
                  final b = entry.branch;
                  final dist = entry.distKm;
                  final phone = b.mobileNo?.isNotEmpty == true
                      ? b.mobileNo!
                      : b.telephoneNo?.isNotEmpty == true
                          ? b.telephoneNo!
                          : null;
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    leading: Container(
                      width: 44, height: 44,
                      decoration: const BoxDecoration(
                        color: AppColors.brandGreenSurface,
                        borderRadius: CxRadius.mdAll,
                      ),
                      child: const Icon(Icons.location_on_rounded, color: AppColors.brandGreen, size: 22),
                    ),
                    title: Text(b.name, style: CxText.cardTitle),
                    subtitle: Text(
                      [b.address, if (b.location != null && b.location!.isNotEmpty) b.location].join(', '),
                      style: CxText.caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (dist != null)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: const BoxDecoration(color: AppColors.brandGreenSurface, borderRadius: CxRadius.pill),
                            child: Text(
                              dist < 1 ? '${(dist * 1000).round()} m' : '${dist.toStringAsFixed(1)} km',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.brandGreen),
                            ),
                          ),
                        if (phone != null) ...[
                          const SizedBox(height: 4),
                          GestureDetector(
                            onTap: () async {
                              final uri = Uri(scheme: 'tel', path: phone);
                              if (await canLaunchUrl(uri)) launchUrl(uri);
                            },
                            child: const Icon(Icons.phone_outlined, color: AppColors.brandGreen, size: 20),
                          ),
                        ],
                      ],
                    ),
                  );
                }).toList(),
              ),
          ],
        ),
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
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: CxColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: CxColors.textHint),
          const SizedBox(width: 12),
          SizedBox(
            width: 110,
            child: Text(label, style: CxText.bodySecondary),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: CxColors.textPrimary)),
          ),
        ],
      ),
    );
  }
}


