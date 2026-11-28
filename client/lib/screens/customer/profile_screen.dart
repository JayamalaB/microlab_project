import 'package:flutter/material.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/models.dart';
import 'package:microlab/widgets/customer/cx_widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

Future<void> _confirmLogout(BuildContext context, VoidCallback onLogout) async {
  final confirmed = await showCxConfirm(
    context,
    icon: Icons.logout_rounded,
    title: 'Logout?',
    message: 'Are you sure you want to logout from MicroLab?',
    confirmLabel: 'Logout',
    destructive: true,
  );
  if (confirmed == true) onLogout();
}

Future<void> _confirmDeleteAccount(BuildContext context, VoidCallback onDelete) async {
  final confirmed = await showCxConfirm(
    context,
    icon: Icons.delete_forever_rounded,
    title: 'Delete Account?',
    message: 'This will permanently delete your account. You will not be able to log in with this number again. This action cannot be undone.',
    confirmLabel: 'Delete',
    destructive: true,
  );
  if (confirmed == true) onDelete();
}

class ProfileScreen extends StatelessWidget {
  final String mobile;
  final bool isVip;
  final List<MemberModel> members;
  final String? accountName;
  final VoidCallback onAddMember;
  final void Function(MemberModel) onEditMember;
  final void Function(MemberModel)? onViewMember;
  final void Function(MemberModel)? onRemoveMember;
  final VoidCallback onLogout;
  final VoidCallback? onFamilyMembers;
  final VoidCallback? onSavedAddresses;
  final VoidCallback? onBookingHistory;
  final VoidCallback? onHealthRecords;
  final VoidCallback? onHelpSupport;
  final VoidCallback? onDeleteAccount;
  final bool embedded;

  const ProfileScreen({
    super.key,
    required this.mobile,
    required this.members,
    this.accountName,
    required this.onAddMember,
    required this.onEditMember,
    this.onViewMember,
    this.onRemoveMember,
    required this.onLogout,
    this.onFamilyMembers,
    this.onSavedAddresses,
    this.onBookingHistory,
    this.onHealthRecords,
    this.onHelpSupport,
    this.onDeleteAccount,
    this.isVip = false,
    this.embedded = false,
  });

  MemberModel? get _self {
    try { return members.firstWhere((m) => m.relation == 'Self'); } catch (_) {}
    try { return members.firstWhere((m) => m.mobile == mobile); } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final topPad = embedded ? MediaQuery.of(context).padding.top : 0.0;
    final self = _self;

    final header = Container(
      color: AppColors.brandGreen,
      width: double.infinity,
      height: topPad + 56,
      padding: EdgeInsets.only(top: topPad),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Text('Profile',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
            if (isVip) ...[
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: const BoxDecoration(color: Color(0xFFFFB300), borderRadius: CxRadius.pill),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.star_rounded, size: 12, color: Colors.white),
                    SizedBox(width: 3),
                    Text('VIP', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white, letterSpacing: 0.5)),
                  ],
                ),
              ),
            ],
            const Spacer(),
          ],
        ),
      ),
    );

    final body = ListView(
      padding: const EdgeInsets.fromLTRB(CxSpace.gutter, 12, CxSpace.gutter, 80),
      children: [
        // ── Account Details (Edit sits in the card's corner) ──────────────────
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: CxRadius.lgAll,
            border: Border.all(color: CxColors.border),
            boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 10, offset: Offset(0, 2))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _Avatar(member: self, size: 48),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(self?.name ?? accountName ?? mobile,
                            style: CxText.pageTitle.copyWith(fontSize: 17)),
                        if (self != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            [
                              if (self.relation != null) self.relation,
                              if (self.location.isNotEmpty) self.location,
                            ].join(' · '),
                            style: CxText.bodySecondary,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (self != null && !self.isReadOnly)
                    _EditButton(onTap: () => onEditMember(self)),
                ],
              ),
              const _HDivider(),
              _InfoRow(icon: Icons.phone_outlined, label: 'Mobile', value: '+91 $mobile'),
              if (self != null) ...[
                if (self.email != null && self.email!.isNotEmpty) ...[
                  const _HDivider(),
                  _InfoRow(icon: Icons.email_outlined, label: 'Email', value: self.email!),
                ],
                if (self.gender.isNotEmpty) ...[
                  const _HDivider(),
                  _InfoRow(icon: Icons.person_outline_rounded, label: 'Gender', value: self.gender),
                ],
                if (self.dob != null) ...[
                  const _HDivider(),
                  _InfoRow(icon: Icons.cake_outlined, label: 'Date of Birth', value: _formatDob(self.dob!, self.age)),
                ],
                if (self.address.isNotEmpty) ...[
                  const _HDivider(),
                  _InfoRow(icon: Icons.location_on_outlined, label: 'Address', value: self.address),
                ],
              ],
            ],
          ),
        ),

        const SizedBox(height: 12),

        // ── Menu tiles (labels say what they are — no subtitles) ──────────────
        _MenuSection(
          tiles: [
            _MenuTile(
              icon: Icons.people_outline_rounded,
              label: 'Family Members',
              onTap: onFamilyMembers ?? onAddMember,
            ),
            _MenuTile(
              icon: Icons.location_on_outlined,
              label: 'Saved Addresses',
              onTap: onSavedAddresses,
            ),
            _MenuTile(
              icon: Icons.receipt_long_outlined,
              label: 'Booking History',
              onTap: onBookingHistory,
            ),
            _MenuTile(
              icon: Icons.folder_outlined,
              label: 'Health Records',
              onTap: onHealthRecords,
            ),
            _MenuTile(
              icon: Icons.support_agent_outlined,
              label: 'Help & Support',
              onTap: onHelpSupport,
            ),
          ],
        ),

        const SizedBox(height: 12),

        // ── Logout / Delete ────────────────────────────────────────────────────
        _MenuSection(
          tiles: [
            _MenuTile(
              icon: Icons.logout_rounded,
              label: 'Logout',
              onTap: () => _confirmLogout(context, onLogout),
            ),
            _MenuTile(
              icon: Icons.delete_outline_rounded,
              label: 'Delete Account',
              destructive: true,
              onTap: onDeleteAccount == null
                  ? null
                  : () => _confirmDeleteAccount(context, onDeleteAccount!),
            ),
          ],
        ),

        const SizedBox(height: 14),
        FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (_, snap) {
            final version = snap.hasData ? 'v${snap.data!.version}+${snap.data!.buildNumber}' : '';
            return Text(version, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: AppColors.textHint));
          },
        ),
        const SizedBox(height: 8),
      ],
    );

    if (embedded) {
      return CustomerThemeScope(
        child: Column(
          children: [
            header,
            Expanded(child: ColoredBox(color: CxColors.page, child: body)),
          ],
        ),
      );
    }

    return CustomerThemeScope(
      child: Scaffold(
        backgroundColor: CxColors.page,
        appBar: AppBar(
          backgroundColor: AppColors.brandGreen,
          elevation: 0,
          scrolledUnderElevation: 0,
          automaticallyImplyLeading: false,
          title: const Text('Profile',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
        ),
        body: body,
      ),
    );
  }

  String _formatDob(DateTime dob, int? age) {
    const months = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final formatted = '${dob.day} ${months[dob.month]} ${dob.year}';
    return age != null ? '$formatted  ($age yrs)' : formatted;
  }
}

// ─── Menu section ─────────────────────────────────────────────────────────────

class _MenuSection extends StatelessWidget {
  final List<_MenuTile> tiles;
  const _MenuSection({required this.tiles});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: CxRadius.lgAll,
        border: Border.all(color: CxColors.border),
        boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 8, offset: Offset(0, 2))],
      ),
      child: Column(
        children: [
          for (int i = 0; i < tiles.length; i++) ...[
            if (i > 0) const Divider(height: 1, thickness: 1, color: CxColors.border, indent: 52),
            tiles[i],
          ],
        ],
      ),
    );
  }
}

class _MenuTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool destructive;

  const _MenuTile({
    required this.icon,
    required this.label,
    this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? CxColors.error : CxColors.textPrimary;
    final iconColor = destructive ? CxColors.error : AppColors.brandGreen;

    return InkWell(
      onTap: onTap,
      borderRadius: CxRadius.lgAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: destructive
                    ? CxColors.error.withValues(alpha: 0.08)
                    : AppColors.brandGreenSurface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color)),
            ),
            const Icon(Icons.chevron_right_rounded, size: 20, color: CxColors.textHint),
          ],
        ),
      ),
    );
  }
}

// ─── Avatar ───────────────────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  final MemberModel? member;
  final double size;
  const _Avatar({this.member, this.size = 60});

  @override
  Widget build(BuildContext context) {
    if (member?.photoBytes != null) {
      return CircleAvatar(radius: size / 2, backgroundImage: MemoryImage(member!.photoBytes!));
    }
    if (member?.photoUrl != null && member!.photoUrl!.isNotEmpty) {
      return CircleAvatar(radius: size / 2, backgroundImage: NetworkImage(member!.photoUrl!));
    }
    final initials = member?.name.isNotEmpty == true
        ? member!.name.trim().split(' ').where((w) => w.isNotEmpty).take(2).map((w) => w[0]).join()
        : '?';
    return Container(
      width: size, height: size,
      decoration: const BoxDecoration(color: AppColors.brandGreenSurface, shape: BoxShape.circle),
      child: Center(
        child: Text(initials.toUpperCase(),
            style: TextStyle(fontSize: size / 3, fontWeight: FontWeight.w700, color: AppColors.brandGreen)),
      ),
    );
  }
}

// ─── Edit button ──────────────────────────────────────────────────────────────

class _EditButton extends StatelessWidget {
  final VoidCallback onTap;
  const _EditButton({required this.onTap});

  @override
  // A pencil in the account card's corner.
  Widget build(BuildContext context) => IconButton(
        onPressed: onTap,
        tooltip: 'Edit profile',
        icon: const Icon(Icons.edit_outlined, size: 20, color: CxColors.brand),
      );
}

// ─── Info row ─────────────────────────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: CxColors.textHint),
          const SizedBox(width: 12),
          SizedBox(width: 100, child: Text(label, style: CxText.bodySecondary)),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: CxColors.textPrimary)),
          ),
        ],
      );
}

class _HDivider extends StatelessWidget {
  const _HDivider();

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 18, thickness: 1, color: CxColors.border);
}

// ─── Family Members Screen ────────────────────────────────────────────────────

class FamilyMembersScreen extends StatefulWidget {
  final List<MemberModel> initialMembers;
  final String selfId;
  /// Returns the new member on success, or null if cancelled.
  final Future<MemberModel?> Function() onAdd;
  /// Returns the updated member on success, or null if cancelled.
  final Future<MemberModel?> Function(MemberModel) onEdit;
  /// Returns true if the member was deleted.
  final Future<bool> Function(MemberModel) onRemove;

  const FamilyMembersScreen({
    super.key,
    required this.initialMembers,
    required this.selfId,
    required this.onAdd,
    required this.onEdit,
    required this.onRemove,
  });

  @override
  State<FamilyMembersScreen> createState() => _FamilyMembersScreenState();
}

class _FamilyMembersScreenState extends State<FamilyMembersScreen> {
  late List<MemberModel> _members;

  @override
  void initState() {
    super.initState();
    _members = List.from(widget.initialMembers);
  }

  List<MemberModel> get _patients =>
      _members.where((m) => m.id != widget.selfId).toList();

  void _showSuccess(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children: [
          const Icon(Icons.check_circle_outline, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(msg),
        ]),
        backgroundColor: AppColors.brandGreen,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _add() async {
    final result = await widget.onAdd();
    if (result != null && mounted) {
      setState(() => _members.add(result));
      _showSuccess('Profile added successfully');
    }
  }

  Future<void> _edit(MemberModel m) async {
    final result = await widget.onEdit(m);
    if (result != null && mounted) {
      setState(() {
        final idx = _members.indexWhere((x) => x.id == result.id);
        if (idx != -1) _members[idx] = result;
      });
      _showSuccess('Profile updated successfully');
    }
  }

  Future<void> _remove(MemberModel m) async {
    final ok = await widget.onRemove(m);
    if (ok && mounted) {
      setState(() => _members.removeWhere((x) => x.id == m.id));
      _showSuccess('Profile removed successfully');
    }
  }

  @override
  Widget build(BuildContext context) {
    final patients = _patients;
    return CustomerThemeScope(
      child: Scaffold(
        backgroundColor: CxColors.page,
        appBar: AppBar(
          backgroundColor: AppColors.brandGreen,
          elevation: 0,
          scrolledUnderElevation: 0,
          title: const Text('Family Members',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
          iconTheme: const IconThemeData(color: Colors.white),
          actions: [
            TextButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 18, color: Colors.white),
              label: const Text('Add', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)),
            ),
          ],
        ),
        body: patients.isEmpty
            ? Center(
                child: CxEmptyState(
                  icon: Icons.people_outline_rounded,
                  title: 'No family members added yet',
                  message: 'Tap "Add" to add a family member.',
                  actionLabel: 'Add Member',
                  onAction: _add,
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                itemCount: patients.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _FamilyMemberCard(
                  member: patients[i],
                  onEdit: patients[i].isReadOnly ? null : () => _edit(patients[i]),
                  onRemove: patients[i].isReadOnly ? null : () => _remove(patients[i]),
                ),
              ),
      ),
    );
  }
}

class _FamilyMemberCard extends StatelessWidget {
  final MemberModel member;
  final VoidCallback? onEdit;
  final VoidCallback? onRemove;

  const _FamilyMemberCard({required this.member, this.onEdit, this.onRemove});

  @override
  Widget build(BuildContext context) {
    final chips = <String>[
      if (member.relation != null) member.relation!,
      if (member.gender.isNotEmpty) member.gender,
      if (member.age != null) '${member.age} yrs',
    ];

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: CxRadius.lgAll,
        border: Border.all(color: CxColors.border),
        boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 8, offset: Offset(0, 2))],
      ),
      child: InkWell(
        onTap: onEdit,
        borderRadius: CxRadius.lgAll,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44, height: 44,
                margin: const EdgeInsets.only(right: 12, top: 2),
                decoration: const BoxDecoration(color: AppColors.brandGreenSurface, shape: BoxShape.circle),
                child: ClipOval(
                  child: member.photoBytes != null
                      ? Image.memory(member.photoBytes!, fit: BoxFit.cover)
                      : member.photoUrl != null && member.photoUrl!.isNotEmpty
                          ? Image.network(member.photoUrl!, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Center(
                                child: Text(
                                  member.name.isNotEmpty ? member.name[0].toUpperCase() : '?',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.brandGreen),
                                ),
                              ))
                          : Center(
                              child: Text(
                                member.name.isNotEmpty ? member.name[0].toUpperCase() : '?',
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.brandGreen),
                              ),
                            ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(member.name, style: CxText.cardTitle),
                    if (chips.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6, runSpacing: 4,
                        children: chips.map((c) => CxChip(label: c, tone: CxTone.neutral)).toList(),
                      ),
                    ],
                    if (member.healthCondition != null && member.healthCondition!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(Icons.favorite_border_rounded, size: 14, color: CxColors.textSecondary),
                          const SizedBox(width: 4),
                          Expanded(child: Text(member.healthCondition!, style: CxText.caption)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Column(
                children: [
                  if (onEdit != null)
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18, color: CxColors.textSecondary),
                      onPressed: onEdit,
                      tooltip: 'Edit',
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      padding: EdgeInsets.zero,
                    ),
                  if (onRemove != null)
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, size: 18, color: CxColors.error),
                      onPressed: onRemove,
                      tooltip: 'Remove',
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      padding: EdgeInsets.zero,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
