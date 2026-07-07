import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class _CustomerHomeScreenState extends State<CustomerHomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _selectedIndex = 0;
  MemberModel? _activeMember;
  List<MemberModel> _members = [];
  bool _loadingPatients = true;
  final _bookingsRefresh = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _loadPatients();
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
    mobile:          widget.mobile,
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
    await AuthService.logout();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const OnboardingScreen()),
        (route) => false,
      );
    }
  }

  void _openAddMember() async {
    final result = await Navigator.push<MemberModel>(
      context,
      MaterialPageRoute(builder: (_) => const AddMemberScreen()),
    );
    if (result != null) setState(() => _members.add(result));
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
            onPressed: () {
              setState(() => _members.removeWhere((m) => m.id == id));
              Navigator.pop(context);
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
    _bookingsRefresh.dispose();
    super.dispose();
  }

  void _onNavTap(int index) {
    setState(() {
      _selectedIndex = index;
      if (index != 0) _activeMember = null;
    });
    if (index == 1) _bookingsRefresh.value++;
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
        if (_activeMember != null) setState(() => _activeMember = null);
      },
      child: Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppColors.background,
      appBar: (!_inDashboard && _selectedIndex == 0)
          ? AppBar(
              backgroundColor: AppColors.white,
              elevation: 0,
              scrolledUnderElevation: 0,
              automaticallyImplyLeading: false,
              title: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: AppColors.brandGreen,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.water_drop_outlined,
                        color: Colors.white, size: 14),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'MicroLab',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary),
                  ),
                ],
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.notifications_outlined,
                      color: AppColors.textSecondary, size: 22),
                  onPressed: () {},
                ),
              ],
            )
          : null,
      body: Stack(
        children: [
          IndexedStack(
            index: _stackIndex,
            children: [
              _loadingPatients
                  ? const Center(
                      child: CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(AppColors.brandGreen),
                        strokeWidth: 2,
                      ),
                    )
                  : _members.isEmpty ? _emptyState() : _memberList(),
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
                    onBack: () => setState(() => _activeMember = null),
                  ),
                )
              else
                const SizedBox.shrink(),
              SafeArea(top: false, bottom: false, child: MyBookingsScreen(embedded: true, refreshTrigger: _bookingsRefresh)),
              const SafeArea(top: false, bottom: false, child: ReportsScreen(embedded: true)),
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
                  onLogout: _logout,
                ),
              ),
            ],
          ),
          // Chatbot FAB — sits above the cart bar when visible (cart bar top ≈ 96px)
          const Positioned(
            right: 16,
            bottom: 110,
            child: SupportChatbotButton(),
          ),
        ],
      ),
      floatingActionButton: (!_inDashboard && _selectedIndex == 0)
          ? FloatingActionButton.extended(
              onPressed: _openAddMember,
              backgroundColor: AppColors.brandGreen,
              foregroundColor: Colors.white,
              elevation: 2,
              icon: const Icon(Icons.person_add_outlined, size: 20),
              label: const Text('Add Customer',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            )
          : null,
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
            icon: Icon(Icons.group_outlined),
            activeIcon: Icon(Icons.group),
            label: 'Customers',
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


  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                color: AppColors.brandGreenSurface,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.group_outlined,
                  size: 36, color: AppColors.brandGreen),
            ),
            const SizedBox(height: 20),
            const Text('No customers yet',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 8),
            const Text(
              'Add customers to book blood tests for them',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14, color: AppColors.textSecondary, height: 1.5),
            ),
            const SizedBox(height: 28),
            ElevatedButton.icon(
              onPressed: _openAddMember,
              icon: const Icon(Icons.person_add_outlined, size: 18),
              label: const Text('Add Customer'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.brandGreen,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _memberList() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      children: [
        Text(
          '${_members.length} Customer${_members.length > 1 ? 's' : ''}',
          style: const TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 12),
        ..._members.map((m) => _MemberCard(
              member: m,
              isVip: widget.isVip,
              onView: () => _viewMember(m),
              onEdit: () => _openEditMember(m),
              onDelete: () => _confirmDelete(m.id, m.name),
              onBook: () => setState(() => _activeMember = m),
            )),
      ],
    );
  }
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

// ─── Member Card (minimal) ────────────────────────────────────────────────────

class _MemberCard extends StatelessWidget {
  final MemberModel member;
  final bool isVip;
  final VoidCallback onView;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onBook;

  const _MemberCard({
    required this.member,
    required this.isVip,
    required this.onView,
    required this.onEdit,
    required this.onDelete,
    required this.onBook,
  });

  Color get _avatarColor {
    switch (member.gender) {
      case 'Female': return const Color(0xFFAD1457);
      case 'Other': return const Color(0xFF6A1B9A);
      default: return AppColors.brandGreen;
    }
  }

  String get _initials {
    final parts = member.name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return member.name.isNotEmpty ? member.name[0].toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context) {
    final ageText = member.age != null ? ', ${member.age} yrs' : '';
    final genderAge = '${member.gender}$ageText';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onBook,
            borderRadius: BorderRadius.circular(13),
            child: Column(
              children: [
          ColoredBox(
            color: AppColors.white,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 6, 14),
              child: Row(
              children: [
                // Avatar
                _MemberAvatar(
                  photoBytes: member.photoBytes,
                  photoUrl: member.photoUrl,
                  initials: _initials,
                  avatarColor: _avatarColor,
                  size: 44,
                  fontSize: 16,
                ),
                const SizedBox(width: 12),

                // Name + secondary info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(member.name,
                                style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary),
                                overflow: TextOverflow.ellipsis),
                          ),
                          if (isVip) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Color(0xFFFFB300), Color(0xFFFF8F00)],
                                ),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.star_rounded,
                                      size: 10, color: Colors.white),
                                  SizedBox(width: 3),
                                  Text('VIP',
                                      style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                          letterSpacing: 0.5)),
                                ],
                              ),
                            ),
                          ],
                          if (member.relation != null) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.brandGreenSurface,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(member.relation!,
                                  style: const TextStyle(
                                      fontSize: 10,
                                      color: AppColors.brandGreen,
                                      fontWeight: FontWeight.w500)),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(genderAge,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textSecondary)),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          const Icon(Icons.location_on_outlined,
                              size: 11, color: AppColors.textHint),
                          const SizedBox(width: 2),
                          Expanded(
                            child: Text(member.location,
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textSecondary),
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // 3-dot menu
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert,
                      size: 20, color: AppColors.textHint),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  elevation: 3,
                  onSelected: (v) {
                    if (v == 'view') onView();
                    if (v == 'edit') onEdit();
                    if (v == 'delete') onDelete();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'view',
                      height: 44,
                      child: Row(children: [
                        Icon(Icons.visibility_outlined,
                            size: 16, color: AppColors.textSecondary),
                        SizedBox(width: 10),
                        Text('View', style: TextStyle(fontSize: 14)),
                      ]),
                    ),
                    if (!member.isReadOnly) ...[
                      const PopupMenuItem(
                        value: 'edit',
                        height: 44,
                        child: Row(children: [
                          Icon(Icons.edit_outlined,
                              size: 16, color: AppColors.textSecondary),
                          SizedBox(width: 10),
                          Text('Edit', style: TextStyle(fontSize: 14)),
                        ]),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'delete',
                        height: 44,
                        child: Row(children: [
                          Icon(Icons.person_remove_outlined,
                              size: 16, color: Color(0xFFD32F2F)),
                          SizedBox(width: 10),
                          Text('Remove',
                              style: TextStyle(
                                  fontSize: 14, color: Color(0xFFD32F2F))),
                        ]),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),

          // Book strip — purely visual, whole card tap handles navigation
          Container(
            color: AppColors.brandGreenSurface,
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.calendar_today_outlined,
                    size: 13, color: AppColors.brandGreen),
                SizedBox(width: 6),
                Text('Book Blood Test',
                    style: TextStyle(
                        fontSize: 12,
                        color: AppColors.brandGreen,
                        fontWeight: FontWeight.w500)),
                SizedBox(width: 4),
                Icon(Icons.arrow_forward_ios_rounded,
                    size: 10, color: AppColors.brandGreen),
              ],
            ),
          ),
          ],
        ),
          ),
        ),
      ),
    );
  }
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
          _DetailRow(
              icon: Icons.location_on_outlined,
              label: 'Location',
              value: member.location),
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


