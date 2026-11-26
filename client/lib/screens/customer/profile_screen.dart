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
      padding: const EdgeInsets.fromLTRB(CxSpace.gutter, CxSpace.xl, CxSpace.gutter, 80),
      children: [
        // ── Account Details ───────────────────────────────────────────────────
        Row(
          children: [
            const Text('Account Details', style: CxText.sectionTitle),
            const Spacer(),
            if (self != null && !self.isReadOnly)
              _EditButton(onTap: () => onEditMember(self)),
          ],
        ),
        const SizedBox(height: CxSpace.sm),

        Container(
          padding: const EdgeInsets.all(CxSpace.lg),
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
                  _Avatar(member: self),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(self?.name ?? accountName ?? mobile,
                            style: CxText.pageTitle.copyWith(fontSize: 18)),
                        if (self != null) ...[
                          const SizedBox(height: 3),
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

        const SizedBox(height: 24),

        // ── Menu tiles ────────────────────────────────────────────────────────
        _MenuSection(
          tiles: [
            _MenuTile(
              icon: Icons.people_outline_rounded,
              label: 'Family Members',
              subtitle: 'Manage and Add Family Members',
              onTap: onFamilyMembers ?? onAddMember,
            ),
            _MenuTile(
              icon: Icons.location_on_outlined,
              label: 'Saved Addresses',
              subtitle: 'Edit, Add, and Manage Addresses',
              onTap: onSavedAddresses,
            ),
            _MenuTile(
              icon: Icons.receipt_long_outlined,
              label: 'Booking History',
              subtitle: 'View Order History and Transactions',
              onTap: onBookingHistory,
            ),
            _MenuTile(
              icon: Icons.folder_outlined,
              label: 'Health Records',
              subtitle: 'Download and Share Reports',
              onTap: onHealthRecords,
            ),
            _MenuTile(
              icon: Icons.support_agent_outlined,
              label: 'Help & Support',
              subtitle: 'Get Assistance & Resolve Queries',
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

        const SizedBox(height: 20),
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
  final String? subtitle;
  final VoidCallback? onTap;
  final bool destructive;

  const _MenuTile({
    required this.icon,
    required this.label,
    this.subtitle,
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: destructive
                    ? CxColors.error.withValues(alpha: 0.08)
                    : AppColors.brandGreenSurface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 20, color: iconColor),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!,
                        style: const TextStyle(fontSize: 12, color: CxColors.textHint)),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 20, color: CxColors.textHint),
          ],
        ),
      ),
    );
  }
}

// ─── Avatar ───────────────────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  final MemberModel? member;
  const _Avatar({this.member});

  @override
  Widget build(BuildContext context) {
    if (member?.photoBytes != null) {
      return CircleAvatar(radius: 30, backgroundImage: MemoryImage(member!.photoBytes!));
    }
    if (member?.photoUrl != null && member!.photoUrl!.isNotEmpty) {
      return CircleAvatar(radius: 30, backgroundImage: NetworkImage(member!.photoUrl!));
    }
    final initials = member?.name.isNotEmpty == true
        ? member!.name.trim().split(' ').where((w) => w.isNotEmpty).take(2).map((w) => w[0]).join()
        : '?';
    return Container(
      width: 60, height: 60,
      decoration: const BoxDecoration(color: AppColors.brandGreenSurface, shape: BoxShape.circle),
      child: Center(
        child: Text(initials.toUpperCase(),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.brandGreen)),
      ),
    );
  }
}

// ─── Edit button ──────────────────────────────────────────────────────────────

class _EditButton extends StatelessWidget {
  final VoidCallback onTap;
  const _EditButton({required this.onTap});

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.edit_outlined, size: 18),
        label: const Text('Edit'),
        style: TextButton.styleFrom(
          foregroundColor: CxColors.brand,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          minimumSize: const Size(48, 40),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
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
      const Divider(height: 24, thickness: 1, color: CxColors.border);
}
