import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/widgets/tech/tech_widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

String _resolvePhotoUrl(String raw) {
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

  const TechnicianProfileScreen({
    super.key,
    required this.mobile,
    required this.onLogout,
    this.embedded = false,
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
  List<String> _specializations = [];
  List<Map<String, dynamic>> _branches = [];
  bool _branchesLoaded = false;

  // ── Today's stats (loaded from API) ──────────────────────────────────────────
  int _assignedToday  = 0;
  int _completedToday = 0;
  int _pendingToday   = 0;
  int _totalDone      = 0;

  late TextEditingController _nameCtrl;
  late TextEditingController _emailCtrl;

  late List<String> _editingSpecs;

  static const _availableSpecs = [
    'Phlebotomy', 'Diabetes', 'Thyroid', 'General', 'Paediatric',
    'Cardiology', 'Neurology', 'Oncology', 'Haematology', 'Microbiology',
  ];

  @override
  void initState() {
    super.initState();
    _nameCtrl     = TextEditingController();
    _emailCtrl    = TextEditingController();
    _editingSpecs = [];
    _loadProfile();
    WidgetsBinding.instance.addObserver(this);
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
    final specStr = prefs.getString('specialization')  ?? '';
    final techId  = prefs.getInt('user_id')            ?? 0;

    final specs = specStr.isNotEmpty
        ? specStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()
        : <String>[];

    if (mounted) {
      setState(() {
        _name           = name;
        _email          = email;
        _technicianCode = code;
        _branchName     = city;
        _photoUrl       = photo;
        _techCity       = city;
        _specializations = specs;
        _nameCtrl.text  = name;
        _emailCtrl.text = email;
        _editingSpecs   = List.from(specs);
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
            Uri.parse('${AppConstants.serverUrl}/api/technicians/$techId/profile'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 8));

      if (!mounted) return;
      if (res.statusCode == 200) {
        final body    = jsonDecode(res.body) as Map<String, dynamic>;
        final profile = body['profile'] as Map<String, dynamic>? ?? {};
        final stats   = body['stats']   as Map<String, dynamic>? ?? {};

        setState(() {
          if ((profile['branch_name'] as String? ?? '').isNotEmpty) {
            _branchName = profile['branch_name'] as String;
          }
          _assignedToday  = int.tryParse(stats['assigned_today'].toString())  ?? 0;
          _completedToday = int.tryParse(stats['completed_today'].toString()) ?? 0;
          _pendingToday   = int.tryParse(stats['pending_today'].toString())   ?? 0;
          _totalDone      = int.tryParse(stats['total_done'].toString())      ?? 0;
          _statsLoading   = false;
          _branches       = (body['branches'] as List? ?? []).cast<Map<String, dynamic>>();
          _branchesLoaded = true;
        });
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

  void _startEdit() {
    _editingSpecs = List.from(_specializations);
    setState(() => _isEditing = true);
  }

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

  void _save() {
    final name = _nameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    setState(() {
      if (name.isNotEmpty) _name = name;
      _email = email;
      _specializations = List.from(_editingSpecs);
      _isEditing = false;
    });
    // TODO: PUT /api/technician/profile
  }

  void _addSpec(String spec) {
    if (!_editingSpecs.contains(spec)) {
      setState(() => _editingSpecs.add(spec));
    }
  }

  void _removeSpec(String spec) => setState(() => _editingSpecs.remove(spec));

  void _showAddSpecDialog() {
    final remaining =
        _availableSpecs.where((s) => !_editingSpecs.contains(s)).toList();
    if (remaining.isEmpty) return;
    showTechSheet<void>(
      context: context,
      title: 'Add Specialization',
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: remaining
            .map((s) => ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  shape: const RoundedRectangleBorder(borderRadius: TechRadius.mdAll),
                  leading: const Icon(Icons.add_circle_outline_rounded,
                      color: TechColors.brand, size: 22),
                  title: Text(s, style: TechText.body),
                  onTap: () {
                    Navigator.pop(context);
                    _addSpec(s);
                  },
                ))
            .toList(),
      ),
    );
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
                  ClipOval(
                    child: _photoUrl.isNotEmpty
                        ? Image.network(
                            _resolvePhotoUrl(_photoUrl),
                            width: 60,
                            height: 60,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _buildInitials(),
                          )
                        : _buildInitials(),
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
                              const SizedBox(height: 6),
                              const TechStatusChip(
                                label: 'Senior Technician',
                                icon: Icons.verified_outlined,
                                tone: TechTone.brand,
                              ),
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
                        onPressed: _cancelEdit,
                        label: 'Cancel',
                        compact: true,
                      ),
                    ),
                    const SizedBox(width: TechSpace.md),
                    Expanded(
                      child: TechButton(
                        onPressed: _save,
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

        // ── Specializations ──────────────────────────────────
        Row(
          children: [
            const _SectionTitle('Specializations'),
            const Spacer(),
            if (_isEditing)
              Material(
                color: TechColors.brandSurface,
                shape: const StadiumBorder(side: BorderSide(color: TechColors.brand)),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: _showAddSpecDialog,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add_rounded,
                            size: 18, color: TechColors.brand),
                        SizedBox(width: 4),
                        Text('Add',
                            style: TextStyle(
                                fontSize: 13,
                                color: TechColors.brand,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: (_isEditing ? _editingSpecs : _specializations)
              .map((s) => _SpecChip(
                    label: s,
                    onRemove: _isEditing ? () => _removeSpec(s) : null,
                  ))
              .toList(),
        ),

        const SizedBox(height: 24),

        // ── Today's summary ──────────────────────────────────
        const _SectionTitle("Today's Summary"),
        const SizedBox(height: 10),
        if (_statsLoading)
          const TechLoadingState(label: "Loading today's summary…")
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
              const SizedBox(width: 10),
              Expanded(
                child: _StatCard(
                  label: 'Pending',
                  value: '$_pendingToday',
                  icon: Icons.pending_outlined,
                  color: TechColors.warning,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  label: 'Total Done',
                  value: '$_totalDone',
                  icon: Icons.star_outline_rounded,
                  color: const Color(0xFF6A1B9A),
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(child: SizedBox()),
              const SizedBox(width: 10),
              const Expanded(child: SizedBox()),
            ],
          ),
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

// ─── Specialization chip ──────────────────────────────────────────────────────

class _SpecChip extends StatelessWidget {
  final String label;
  final VoidCallback? onRemove;
  const _SpecChip({required this.label, this.onRemove});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.fromLTRB(14, onRemove != null ? 2 : 8, onRemove != null ? 2 : 14, onRemove != null ? 2 : 8),
        decoration: BoxDecoration(
          color: TechColors.brandSurface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppColors.brandGreenLight),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 13,
                    color: TechColors.brand,
                    fontWeight: FontWeight.w600)),
            if (onRemove != null)
              // 40px tap area around the small ✕.
              InkResponse(
                onTap: onRemove,
                radius: 20,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: Center(
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: const BoxDecoration(
                          color: TechColors.brand, shape: BoxShape.circle),
                      child: const Icon(Icons.close_rounded,
                          size: 12, color: Colors.white),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

// ─── Section title ────────────────────────────────────────────────────────────

// One branch this technician works at. Name, default marker, then city with
// pincode and the full address, each only when it's there.
class _BranchTile extends StatelessWidget {
  final Map<String, dynamic> branch;
  const _BranchTile({required this.branch});

  @override
  Widget build(BuildContext context) {
    final name     = branch['name'] as String? ?? '—';
    final isMain   = branch['isDefault'] == true;
    final address  = (branch['address'] as String? ?? '').trim();
    final location = [branch['location'], branch['pincode']]
        .map((v) => (v ?? '').toString().trim())
        .where((v) => v.isNotEmpty)
        .join(' - ');

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: TechSpace.md),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: TechRadius.lgAll,
        border: Border.all(color: TechColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.location_on_outlined, size: 18, color: AppColors.brandGreen),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(name,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textPrimary)),
                    ),
                    if (isMain)
                      const TechStatusChip(label: 'Default', tone: TechTone.brand),
                  ],
                ),
                if (location.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(location,
                      style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                ],
                if (address.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(address,
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ],
              ],
            ),
          ),
        ],
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
