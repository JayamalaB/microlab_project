import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/theme/app_theme.dart';

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
      final res = await http
          .get(Uri.parse('${AppConstants.serverUrl}/api/technicians/$techId/profile'))
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
                fontSize: 20,
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
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: const Color(0xFFFFEBEE),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.logout_rounded,
                  size: 26, color: Color(0xFFD32F2F)),
            ),
            const SizedBox(height: 16),
            const Text('Logout?',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 8),
            const Text(
              'Are you sure you want to logout from MicroLab?',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                      side: const BorderSide(color: AppColors.divider),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Cancel',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFD32F2F),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Logout',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 14),
          Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 14),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Add Specialization',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary)),
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              children: remaining
                  .map((s) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.add_circle_outline_rounded,
                            color: AppColors.brandGreen, size: 20),
                        title: Text(s,
                            style: const TextStyle(
                                fontSize: 14, color: AppColors.textPrimary)),
                        onTap: () {
                          Navigator.pop(context);
                          _addSpec(s);
                        },
                      ))
                  .toList(),
            ),
          ),
        ],
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
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
          const Spacer(),
          if (!_isEditing)
            TextButton.icon(
              onPressed: _confirmLogout,
              icon: const Icon(Icons.logout_rounded,
                  size: 15, color: Colors.white70),
              label: const Text('Logout',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            const Spacer(),
            if (!_isEditing)
              TextButton.icon(
                onPressed: _startEdit,
                icon: const Icon(Icons.edit_outlined, size: 14),
                label: const Text('Edit'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.brandGreen,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  textStyle: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),

        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _isEditing ? AppColors.brandGreen : AppColors.divider,
              width: _isEditing ? 1.5 : 1,
            ),
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
                                      color: AppColors.textPrimary)),
                              const SizedBox(height: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: AppColors.brandGreenSurface,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: const Text('Senior Technician',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: AppColors.brandGreen,
                                        fontWeight: FontWeight.w500)),
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
                      child: OutlinedButton(
                        onPressed: _cancelEdit,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.textSecondary,
                          side: const BorderSide(color: AppColors.divider),
                          padding:
                              const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _save,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.brandGreen,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding:
                              const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        child: const Text('Save Changes',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 24),

        // ── Specializations ──────────────────────────────────
        Row(
          children: [
            const _SectionTitle('Specializations'),
            const Spacer(),
            if (_isEditing)
              GestureDetector(
                onTap: _showAddSpecDialog,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppColors.brandGreenSurface,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.brandGreen),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_rounded,
                          size: 14, color: AppColors.brandGreen),
                      SizedBox(width: 4),
                      Text('Add',
                          style: TextStyle(
                              fontSize: 12,
                              color: AppColors.brandGreen,
                              fontWeight: FontWeight.w600)),
                    ],
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
          const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: CircularProgressIndicator(strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(AppColors.brandGreen)),
            ),
          )
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
                  color: const Color(0xFF1565C0),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatCard(
                  label: 'Pending',
                  value: '$_pendingToday',
                  icon: Icons.pending_outlined,
                  color: const Color(0xFFE65100),
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

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.brandGreen,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: const Text('Profile',
            style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w600)),
        actions: [
          if (!_isEditing)
            TextButton.icon(
              onPressed: _confirmLogout,
              icon: const Icon(Icons.logout_rounded,
                  size: 16, color: Colors.white70),
              label: const Text('Logout',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
            ),
        ],
      ),
      body: body,
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
        style: const TextStyle(fontSize: 14, color: AppColors.textPrimary),
        decoration: InputDecoration(
          prefixIcon: Icon(icon, size: 16, color: AppColors.textSecondary),
          hintText: hint,
          hintStyle: const TextStyle(
              fontSize: 14, color: AppColors.textHint),
          filled: true,
          fillColor: AppColors.background,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.divider),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: AppColors.divider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:
                const BorderSide(color: AppColors.brandGreen, width: 1.5),
          ),
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
          Icon(icon, size: 15, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          SizedBox(
            width: 96,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textSecondary)),
          ),
          const Text(':  ',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary)),
          ),
          const Icon(Icons.lock_outline_rounded,
              size: 12, color: AppColors.textHint),
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
          Icon(icon, size: 15, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          SizedBox(
            width: 96,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textSecondary)),
          ),
          const Text(':  ',
              style:
                  TextStyle(fontSize: 13, color: AppColors.textSecondary)),
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
        padding: EdgeInsets.fromLTRB(12, 6, onRemove != null ? 6 : 12, 6),
        decoration: BoxDecoration(
          color: AppColors.brandGreenSurface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.brandGreenLight),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.brandGreen,
                    fontWeight: FontWeight.w500)),
            if (onRemove != null) ...[
              const SizedBox(width: 4),
              GestureDetector(
                onTap: onRemove,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: const BoxDecoration(
                      color: AppColors.brandGreen, shape: BoxShape.circle),
                  child: const Icon(Icons.close_rounded,
                      size: 10, color: Colors.white),
                ),
              ),
            ],
          ],
        ),
      );
}

// ─── Section title ────────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary));
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
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(height: 6),
            Text(value,
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700, color: color)),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(
                    fontSize: 10, color: AppColors.textSecondary)),
          ],
        ),
      );
}
