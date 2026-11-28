import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/services/api_service.dart';
import 'package:microlab/services/socket_service.dart';
import 'package:microlab/utils/app_messages.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/widgets/tech/tech_widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Full URL for a technician photo path (also used by the dashboard header).
String resolveTechPhotoUrl(String raw) {
  if (raw.isEmpty) return '';
  if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
  final base = AppConstants.serverUrl.replaceAll(RegExp(r'/+$'), '');
  final path = raw.startsWith('/') ? raw : '/$raw';
  return '$base$path';
}

class TechnicianProfileScreen extends StatefulWidget {
  final String mobile;
  final bool embedded;
  final VoidCallback onLogout;
  /// Bumped by the Dashboard each time the Profile tab is opened, so Today's
  /// Summary and the profile reload instead of showing old numbers.
  final int refreshTick;
  /// Called after the name or photo changes, so the Dashboard header updates.
  final VoidCallback? onProfileChanged;

  const TechnicianProfileScreen({
    super.key,
    required this.mobile,
    required this.onLogout,
    this.embedded = false,
    this.refreshTick = 0,
    this.onProfileChanged,
  });

  @override
  State<TechnicianProfileScreen> createState() =>
      _TechnicianProfileScreenState();
}

class _TechnicianProfileScreenState extends State<TechnicianProfileScreen> with WidgetsBindingObserver {
  bool _isEditing    = false;
  bool _statsLoading = true;

  // ── Profile fields (loaded from SharedPreferences + API) ─────────────────────
  String _name           = '';
  String _email          = '';
  String _technicianCode = '';
  String _branchName     = '';
  String _photoUrl       = '';
  String _techCity       = '';
  bool _saving     = false;
  bool _photoBusy  = false;
  List<Map<String, dynamic>> _branches = [];
  bool _branchesLoaded = false;

  // ── Today's stats (loaded from API) ──────────────────────────────────────────
  int _assignedToday  = 0;
  int _completedToday = 0;
  int _pendingToday   = 0;
  int _rescheduled    = 0;
  int _totalDone      = 0;

  // Summary period (server values → labels).
  String _period = 'today';
  static const _periods = {
    'all':        'All Time',
    'today':      'Today',
    'this_week':  'This Week',
    'last_week':  'Last Week',
    'this_month': 'This Month',
    'last_month': 'Last Month',
  };

  Future<void> _setPeriod(String p) async {
    if (p == _period) return;
    setState(() { _period = p; _statsLoading = true; });
    await _reload();
  }

  late TextEditingController _nameCtrl;
  late TextEditingController _emailCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl     = TextEditingController();
    _emailCtrl    = TextEditingController();
    _loadProfile();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant TechnicianProfileScreen old) {
    super.didUpdateWidget(old);
    if (widget.refreshTick != old.refreshTick) _reload();
  }

  Future<void> _reload() async {
    final prefs  = await SharedPreferences.getInstance();
    final techId = prefs.getInt('user_id') ?? 0;
    if (techId > 0 && mounted) await _loadStats(techId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final prefs = SharedPreferences.getInstance();
      prefs.then((p) {
        final techId = p.getInt('user_id') ?? 0;
        if (techId > 0) {
          setState(() => _statsLoading = true);
          _loadStats(techId);
        }
      });
    }
  }

  Future<void> _loadProfile() async {
    // ── Step 1: SharedPreferences (instant, no network) ───────────────────────
    final prefs = await SharedPreferences.getInstance();

    final name    = prefs.getString('user_name')       ?? '';
    final email   = prefs.getString('user_email')      ?? '';
    final code    = prefs.getString('technician_code') ?? '';
    final city    = prefs.getString('tech_city')       ?? '';
    final photo   = prefs.getString('tech_photo')      ?? '';
    final techId  = prefs.getInt('user_id')            ?? 0;

    if (mounted) {
      setState(() {
        _name           = name;
        _email          = email;
        _technicianCode = code;
        _branchName     = city;
        _photoUrl       = photo;
        _techCity       = city;
        _nameCtrl.text  = name;
        _emailCtrl.text = email;
      });
    }

    // ── Step 2: API call for branch name + today's stats ──────────────────────
    if (techId > 0) await _loadStats(techId);
  }

  Future<void> _loadStats(int techId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('auth_token') ?? '';
      final res = await http
          .get(
            Uri.parse('${AppConstants.serverUrl}/api/technicians/$techId/profile?period=$_period'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 8));

      if (!mounted) return;
      if (res.statusCode == 200) {
        final body    = jsonDecode(res.body) as Map<String, dynamic>;
        final profile = body['profile'] as Map<String, dynamic>? ?? {};
        final stats   = body['stats']   as Map<String, dynamic>? ?? {};

        // Name / email / photo as saved on the server (the source of truth —
        // e.g. after an edit on another device). Not while editing.
        final srvName  = (profile['user_name']  as String? ?? '').trim();
        final srvEmail = (profile['user_email'] as String? ?? '').trim();
        final srvPhoto = (profile['tech_photo'] as String? ?? '').trim();
        if (!_isEditing) {
          final prefs = await SharedPreferences.getInstance();
          if (srvName.isNotEmpty) await prefs.setString('user_name', srvName);
          await prefs.setString('user_email', srvEmail);
          await prefs.setString('tech_photo', srvPhoto);
          if (!mounted) return;
        }
        setState(() {
          if (!_isEditing) {
            if (srvName.isNotEmpty) { _name = srvName; _nameCtrl.text = srvName; }
            _email = srvEmail; _emailCtrl.text = srvEmail;
            _photoUrl = srvPhoto;
          }
          if ((profile['branch_name'] as String? ?? '').isNotEmpty) {
            _branchName = profile['branch_name'] as String;
          }
          _assignedToday  = int.tryParse(stats['assigned_today'].toString())  ?? 0;
          _completedToday = int.tryParse(stats['completed_today'].toString()) ?? 0;
          _pendingToday   = int.tryParse(stats['pending_today'].toString())   ?? 0;
          _rescheduled    = int.tryParse('${stats['rescheduled'] ?? 0}')      ?? 0;
          _totalDone      = int.tryParse(stats['total_done'].toString())      ?? 0;
          _statsLoading   = false;
          _branches       = (body['branches'] as List? ?? []).cast<Map<String, dynamic>>();
          _branchesLoaded = true;
        });
      } else {
        // Server error: stop the spinner (last numbers stay).
        setState(() => _statsLoading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _statsLoading = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Widget _buildInitials() => Container(
        width: 60,
        height: 60,
        color: AppColors.brandGreenSurface,
        child: Center(
          child: Text(
            _name.trim().split(' ').take(2)
                .map((w) => w.isNotEmpty ? w[0] : '').join().toUpperCase(),
            style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.brandGreen),
          ),
        ),
      );

  void _startEdit() => setState(() => _isEditing = true);

  void _cancelEdit() {
    _nameCtrl.text = _name;
    _emailCtrl.text = _email;
    setState(() => _isEditing = false);
  }

  Future<void> _confirmLogout() async {
    // Same result as before: logs out only when Logout is tapped.
    final confirmed = await showTechConfirm(
      context,
      icon: Icons.logout_rounded,
      title: 'Logout?',
      message: 'Are you sure you want to logout from MicroLab?',
      confirmLabel: 'Logout',
      destructive: true,
    );
    if (confirmed == true) widget.onLogout();
  }

  // Saves name + email on the server (ip_users), then locally.
  Future<void> _save() async {
    if (_saving) return;
    final name  = _nameCtrl.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final email = _emailCtrl.text.trim();
    if (name.length < 2) {
      AppMessages.error(context, 'Enter your full name');
      return;
    }
    setState(() => _saving = true);
    final res = await ApiService.updateTechnicianProfile(name: name, email: email);
    if (!mounted) return;
    if (res['success'] == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_name', name);
      await prefs.setString('user_email', email);
      SocketService.instance.userName = name; // Dashboard "Welcome, …"
      if (!mounted) return;
      setState(() {
        _name = name;
        _email = email;
        _nameCtrl.text = name;
        _emailCtrl.text = email;
        _isEditing = false;
        _saving = false;
      });
      widget.onProfileChanged?.call();
      AppMessages.success(context, 'Profile updated');
    } else {
      setState(() => _saving = false);
      AppMessages.error(context, AppMessages.serverMessage(res['message'],
          fallback: 'We couldn\'t save your profile. Please try again.'));
    }
  }

  // ── Profile photo: take / choose / remove ─────────────────────────────────
  Future<void> _changePhoto() async {
    if (_photoBusy) return;
    final choice = await showTechSheet<String>(
      context: context,
      title: 'Profile photo',
      builder: (sheetCtx) => Column(mainAxisSize: MainAxisSize.min, children: [
        TechOptionCard(
          icon: Icons.camera_alt_outlined,
          title: 'Take photo',
          subtitle: 'Use the camera now',
          onTap: () => Navigator.pop(sheetCtx, 'camera'),
        ),
        const SizedBox(height: TechSpace.md),
        TechOptionCard(
          icon: Icons.photo_library_outlined,
          title: 'Choose from gallery',
          subtitle: 'Pick a photo you already have',
          onTap: () => Navigator.pop(sheetCtx, 'gallery'),
        ),
        if (_photoUrl.isNotEmpty) ...[
          const SizedBox(height: TechSpace.md),
          TechOptionCard(
            icon: Icons.delete_outline_rounded,
            title: 'Remove photo',
            subtitle: 'Show your initials instead',
            onTap: () => Navigator.pop(sheetCtx, 'remove'),
          ),
        ],
      ]),
    );
    if (choice == null || !mounted) return;

    if (choice == 'remove') {
      final ok = await showTechConfirm(
        context,
        icon: Icons.delete_outline_rounded,
        title: 'Remove photo?',
        message: 'Your initials will show instead.',
        confirmLabel: 'Remove',
        destructive: true,
      );
      if (ok != true || !mounted) return;
      setState(() => _photoBusy = true);
      final res = await ApiService.removeTechnicianPhoto();
      await _applyPhotoResult(res, removed: true);
      return;
    }

    XFile? file;
    try {
      file = await ImagePicker().pickImage(
        source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
        preferredCameraDevice: CameraDevice.front,
        imageQuality: 80,
        maxWidth: 1024,
        maxHeight: 1024,
      );
    } catch (e) {
      if (mounted) AppMessages.error(context, 'Couldn\'t open the ${choice == 'camera' ? 'camera' : 'gallery'}.');
      return;
    }
    if (file == null || !mounted) return;

    setState(() => _photoBusy = true);
    final bytes = await file.readAsBytes();
    final name  = file.name.toLowerCase().endsWith('.png') ? 'profile.png' : 'profile.jpg';
    final res   = await ApiService.uploadTechnicianPhoto(bytes, name);
    await _applyPhotoResult(res);
  }

  Future<void> _applyPhotoResult(Map<String, dynamic> res, {bool removed = false}) async {
    if (!mounted) return;
    if (res['success'] == true) {
      final url = removed ? '' : (res['tech_photo'] as String? ?? '');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('tech_photo', url);
      if (!mounted) return;
      setState(() { _photoUrl = url; _photoBusy = false; });
      widget.onProfileChanged?.call();
      AppMessages.success(context, removed ? 'Photo removed' : 'Photo updated');
    } else {
      setState(() => _photoBusy = false);
      AppMessages.error(context, AppMessages.serverMessage(res['message'],
          fallback: 'We couldn\'t update your photo. Please try again.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPad = widget.embedded ? MediaQuery.of(context).padding.top : 0.0;

    final header = Container(
      color: AppColors.brandGreen,
      padding: EdgeInsets.fromLTRB(16, topPad + 16, 8, 14),
      child: Row(
        children: [
          const Text('Profile',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700)),
          const Spacer(),
          if (!_isEditing)
            TextButton.icon(
              onPressed: _confirmLogout,
              icon: const Icon(Icons.logout_rounded,
                  size: 15, color: Colors.white70),
              label: const Text('Logout',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                minimumSize: const Size(48, TechSize.minTouch),
              ),
            ),
        ],
      ),
    );

    final body = RefreshIndicator(
      onRefresh: () async {
        final prefs = await SharedPreferences.getInstance();
        final techId = prefs.getInt('user_id') ?? 0;
        if (techId > 0) {
          setState(() => _statsLoading = true);
          await _loadStats(techId);
        }
      },
      color: AppColors.brandGreen,
      child: ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 80),
      children: [
        // ── Profile card ─────────────────────────────────────
        Row(
          children: [
            const Text('Profile Details',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            const Spacer(),
            if (!_isEditing)
              TextButton.icon(
                onPressed: _startEdit,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Edit'),
                style: TextButton.styleFrom(
                  foregroundColor: TechColors.brand,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  minimumSize: const Size(48, TechSize.minTouch),
                  textStyle: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),

        Container(
          padding: const EdgeInsets.all(TechSpace.lg),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: TechRadius.lgAll,
            border: Border.all(
              color: _isEditing ? TechColors.brand : TechColors.border,
              width: _isEditing ? 1.5 : 1,
            ),
            boxShadow: const [BoxShadow(color: Color(0x0A000000), blurRadius: 8, offset: Offset(0, 2))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Avatar row ────────────────────────────────
              Row(
                children: [
                  // Tap the photo (or its 📷 badge) to take / choose / remove.
                  Semantics(
                    button: true,
                    label: 'Change profile photo',
                    child: GestureDetector(
                      onTap: _photoBusy ? null : _changePhoto,
                      child: Stack(clipBehavior: Clip.none, children: [
                        ClipOval(
                          child: _photoBusy
                              ? Container(
                                  width: 60, height: 60,
                                  color: AppColors.brandGreenSurface,
                                  alignment: Alignment.center,
                                  child: const SizedBox(width: 22, height: 22,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.brandGreen)),
                                )
                              : _photoUrl.isNotEmpty
                                  ? Image.network(
                                      resolveTechPhotoUrl(_photoUrl),
                                      width: 60,
                                      height: 60,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => _buildInitials(),
                                    )
                                  : _buildInitials(),
                        ),
                        Positioned(
                          right: -4, bottom: -4,
                          child: Container(
                            width: 26, height: 26,
                            decoration: BoxDecoration(
                              color: TechColors.brand,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                            child: const Icon(Icons.camera_alt_rounded, size: 13, color: Colors.white),
                          ),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: _isEditing
                        ? _EditField(
                            controller: _nameCtrl,
                            hint: 'Full name',
                            icon: Icons.badge_outlined,
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_name,
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: TechColors.textPrimary)),
                              const SizedBox(height: 2),
                              const Text('Tap the photo to change it', style: TechText.caption),
                            ],
                          ),
                  ),
                ],
              ),
              const Divider(height: 24, color: AppColors.divider),

              // ── Mobile (locked) ───────────────────────────
              _LockedRow(
                  icon: Icons.phone_outlined,
                  label: 'Mobile',
                  value: '+91 ${widget.mobile}'),
              const _HDivider(),

              // ── Employee ID (locked) ──────────────────────
              _LockedRow(
                  icon: Icons.badge_outlined,
                  label: 'Employee ID',
                  value: _technicianCode.isNotEmpty ? _technicianCode : '—'),
              const _HDivider(),

              // ── Branch (locked) ───────────────────────────
              _LockedRow(
                  icon: Icons.location_on_outlined,
                  label: 'Branch',
                  value: _branchName.isNotEmpty ? _branchName : '—'),
              const _HDivider(),

              // ── Email (editable) ──────────────────────────
              if (_isEditing)
                _EditField(
                  controller: _emailCtrl,
                  hint: 'Email address',
                  icon: Icons.email_outlined,
                  keyboardType: TextInputType.emailAddress,
                )
              else
                _InfoRow(
                    icon: Icons.email_outlined,
                    label: 'Email',
                    value: _email.isNotEmpty ? _email : '—'),
              const _HDivider(),

              // ── City (locked) ──────────────────────────────
              _LockedRow(
                  icon: Icons.location_city_outlined,
                  label: 'City',
                  value: _techCity.isNotEmpty ? _techCity : '—'),

              // ── Save / Cancel ─────────────────────────────
              if (_isEditing) ...[
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: TechButton.secondary(
                        onPressed: _saving ? null : _cancelEdit,
                        label: 'Cancel',
                        compact: true,
                      ),
                    ),
                    const SizedBox(width: TechSpace.md),
                    Expanded(
                      child: TechButton(
                        onPressed: _saving ? null : _save,
                        loading: _saving,
                        label: 'Save Changes',
                        compact: true,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 24),

        // ── My Branches ───────────────────────────────────────────────────
        const _SectionTitle('My Branches'),
        const SizedBox(height: 10),
        if (_branches.isNotEmpty)
          ..._branches.map((b) => _BranchTile(branch: b))
        else if (_branchesLoaded)
          const TechBanner(
            tone: TechTone.warning,
            message: 'No branch assigned yet. Please contact your admin.',
          ),

        const SizedBox(height: 24),

        // ── Summary (period dropdown) ────────────────────────
        // Counted per job (a family visit is one), cancelled left out.
        Row(children: [
          const _SectionTitle('Summary'),
          const Spacer(),
          PopupMenuButton<String>(
            tooltip: 'Summary period',
            initialValue: _period,
            onSelected: _setPeriod,
            position: PopupMenuPosition.under,
            shape: const RoundedRectangleBorder(borderRadius: TechRadius.mdAll),
            itemBuilder: (_) => [
              for (final e in _periods.entries)
                PopupMenuItem<String>(
                  value: e.key,
                  height: 44,
                  child: Row(children: [
                    SizedBox(
                      width: 22,
                      child: e.key == _period
                          ? const Icon(Icons.check_rounded, size: 18, color: TechColors.brand)
                          : null,
                    ),
                    const SizedBox(width: 6),
                    Text(e.value,
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: e.key == _period ? FontWeight.w700 : FontWeight.w500,
                            color: e.key == _period ? TechColors.brand : TechColors.textPrimary)),
                  ]),
                ),
            ],
            child: Container(
              constraints: const BoxConstraints(minHeight: 36),
              padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
              decoration: BoxDecoration(
                color: TechColors.brandSurface,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: AppColors.brandGreenLight),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.calendar_month_outlined, size: 15, color: TechColors.brand),
                const SizedBox(width: 6),
                Text(_periods[_period] ?? 'Today',
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: TechColors.brand)),
                const Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: TechColors.brand),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        if (_statsLoading)
          const TechLoadingState(label: 'Loading summary…')
        else ...[
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  label: 'Assigned',
                  value: '$_assignedToday',
                  icon: Icons.calendar_today_outlined,
                  color: AppColors.brandGreen,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatCard(
                  label: 'Completed',
                  value: '$_completedToday',
                  icon: Icons.check_circle_outline,
                  color: TechColors.info,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  label: 'Pending',
                  value: '$_pendingToday',
                  icon: Icons.pending_outlined,
                  color: TechColors.warning,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatCard(
                  label: 'Rescheduled',
                  value: '$_rescheduled',
                  icon: Icons.update_rounded,
                  color: const Color(0xFF1565C0),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.star_outline_rounded, size: 16, color: Color(0xFF6A1B9A)),
            const SizedBox(width: 6),
            Text('All-time completed: $_totalDone', style: TechText.caption),
          ]),
        ],

        const SizedBox(height: 24),
        FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (_, snap) {
            final version = snap.hasData ? 'v${snap.data!.version}+${snap.data!.buildNumber}' : '';
            return Text(
              version,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: AppColors.textHint),
            );
          },
        ),
        const SizedBox(height: 8),
      ],
      ),
    );

    if (widget.embedded) {
      return Column(
        children: [
          header,
          Expanded(
            child: ColoredBox(color: AppColors.background, child: body),
          ),
        ],
      );
    }

    return TechThemeScope(
      child: Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.brandGreen,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text('Profile',
            style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600)),
        actions: [
          if (!_isEditing)
            TextButton.icon(
              onPressed: _confirmLogout,
              icon: const Icon(Icons.logout_rounded,
                  size: 16, color: Colors.white70),
              label: const Text('Logout',
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
      body: body,
      ),
    );
  }
}

// ─── Edit field ───────────────────────────────────────────────────────────────

class _EditField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final TextInputType? keyboardType;
  const _EditField(
      {required this.controller,
      required this.hint,
      required this.icon,
      this.keyboardType});

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: const TextStyle(fontSize: 14, color: TechColors.textPrimary),
        // Borders, focus colour and padding come from the technician theme.
        decoration: InputDecoration(
          prefixIcon: Icon(icon, size: 20, color: TechColors.textHint),
          hintText: hint,
        ),
      );
}

// ─── Locked row (admin-set, non-editable) ────────────────────────────────────

class _LockedRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _LockedRow(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: TechColors.textHint),
          const SizedBox(width: TechSpace.md),
          SizedBox(
            width: 96,
            child: Text(label, style: TechText.bodySecondary),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: TechColors.textPrimary)),
          ),
          const Tooltip(
            message: 'Set by your admin',
            child: Icon(Icons.lock_outline_rounded,
                size: 14, color: TechColors.textHint),
          ),
        ],
      );
}

// ─── Info row ─────────────────────────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: TechColors.textHint),
          const SizedBox(width: TechSpace.md),
          SizedBox(
            width: 96,
            child: Text(label, style: TechText.bodySecondary),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: TechColors.textPrimary)),
          ),
        ],
      );
}

class _HDivider extends StatelessWidget {
  const _HDivider();
  @override
  Widget build(BuildContext context) =>
      const Divider(height: 20, thickness: 1, color: AppColors.divider);
}

// ─── Section title ────────────────────────────────────────────────────────────

// One branch this technician works at, as an accordion row: name + Default
// marker + ˅ when closed; tap to show city with pincode and the full address.
class _BranchTile extends StatefulWidget {
  final Map<String, dynamic> branch;
  const _BranchTile({required this.branch});

  @override
  State<_BranchTile> createState() => _BranchTileState();
}

class _BranchTileState extends State<_BranchTile> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final branch   = widget.branch;
    final name     = branch['name'] as String? ?? '—';
    final isMain   = branch['isDefault'] == true;
    final address  = (branch['address'] as String? ?? '').trim();
    final location = [branch['location'], branch['pincode']]
        .map((v) => (v ?? '').toString().trim())
        .where((v) => v.isNotEmpty)
        .join(' - ');
    final hasDetails = location.isNotEmpty || address.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: TechSpace.sm),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: TechRadius.mdAll,
          side: BorderSide(color: _open ? TechColors.brand : TechColors.border, width: _open ? 1.4 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Header row (always visible)
          Semantics(
            button: hasDetails,
            expanded: hasDetails ? _open : null,
            child: InkWell(
              onTap: hasDetails ? () => setState(() => _open = !_open) : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 52),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                  child: Row(children: [
                    const Icon(Icons.location_on_outlined, size: 18, color: AppColors.brandGreen),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                    ),
                    if (isMain) ...[
                      const SizedBox(width: 8),
                      const TechStatusChip(label: 'Default', tone: TechTone.brand),
                    ],
                    if (hasDetails)
                      AnimatedRotation(
                        turns: _open ? 0.5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: const Padding(
                          padding: EdgeInsets.all(6),
                          child: Icon(Icons.keyboard_arrow_down_rounded, size: 24, color: TechColors.textSecondary),
                        ),
                      )
                    else
                      const SizedBox(width: 8),
                  ]),
                ),
              ),
            ),
          ),
          // Details (open only)
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: !_open
                ? const SizedBox(width: double.infinity)
                : Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(42, 0, 14, 14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Divider(height: 1, color: AppColors.divider),
                      const SizedBox(height: 10),
                      if (location.isNotEmpty)
                        Text(location,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                                color: AppColors.textSecondary)),
                      if (address.isNotEmpty) ...[
                        if (location.isNotEmpty) const SizedBox(height: 3),
                        Text(address,
                            style: const TextStyle(fontSize: 12.5, color: AppColors.textSecondary, height: 1.35)),
                      ],
                    ]),
                  ),
          ),
        ]),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.textPrimary));
}

// ─── Stat card ────────────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  const _StatCard(
      {required this.label,
      required this.value,
      required this.icon,
      required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(TechSpace.md),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: TechRadius.lgAll,
          border: Border.all(color: TechColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: TechRadius.smAll,
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(height: TechSpace.sm),
            Text(value,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w700, color: TechColors.textPrimary)),
            const SizedBox(height: 2),
            Text(label, style: TechText.caption),
          ],
        ),
      );
}
