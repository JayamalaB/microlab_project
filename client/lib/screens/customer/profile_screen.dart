import 'package:flutter/material.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/models.dart';
import 'package:microlab/widgets/customer/cx_widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

Future<void> _confirmLogout(BuildContext context, VoidCallback onLogout) async {
  // Same result as before: logs out only when Logout is tapped.
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

class ProfileScreen extends StatelessWidget {
  final String mobile;
  final bool isVip;
  final List<MemberModel> members;
  final String? accountName;
  final VoidCallback onAddMember;
  final void Function(MemberModel) onEditMember;
  // Family-member View / Remove (moved here from the old Customers tab).
  final void Function(MemberModel)? onViewMember;
  final void Function(MemberModel)? onRemoveMember;
  final VoidCallback onLogout;
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
    this.isVip = false,
    this.embedded = false,
  });

  MemberModel? get _self {
    try {
      return members.firstWhere((m) => m.relation == 'Self');
    } catch (_) {}
    try {
      return members.firstWhere((m) => m.mobile == mobile);
    } catch (_) {}
    return null;
  }

  List<MemberModel> get _patients {
    final self = _self;
    return members.where((m) => m.id != self?.id).toList();
  }

  @override
  Widget build(BuildContext context) {
    final topPad = embedded ? MediaQuery.of(context).padding.top : 0.0;
    final self = _self;
    final patients = _patients;

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
              style: TextStyle(
                  color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
          if (isVip) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: const BoxDecoration(
                color: Color(0xFFFFB300),
                borderRadius: CxRadius.pill,
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.star_rounded, size: 12, color: Colors.white),
                  SizedBox(width: 3),
                  Text('VIP',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: 0.5)),
                ],
              ),
            ),
          ],
          const Spacer(),
          TextButton.icon(
            onPressed: () => _confirmLogout(context, onLogout),
            icon: const Icon(Icons.logout_rounded, size: 18, color: Colors.white),
            label: const Text('Logout',
                style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              minimumSize: const Size(48, 44),
            ),
          ),
        ],
      ),
      ),
    );

    final body = ListView(
      padding: const EdgeInsets.fromLTRB(CxSpace.gutter, CxSpace.xl, CxSpace.gutter, 80),
      children: [
        // ── Account Details ──────────────────────────────────
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
              // ── Avatar + name row ──────────────────────────
              Row(
                children: [
                  _Avatar(member: self),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          self?.name ?? accountName ?? mobile,
                          style: CxText.pageTitle.copyWith(fontSize: 18),
                        ),
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

              // ── Info rows ──────────────────────────────────
              _InfoRow(
                  icon: Icons.phone_outlined,
                  label: 'Mobile',
                  value: '+91 $mobile'),
              if (self != null) ...[
                if (self.email != null && self.email!.isNotEmpty) ...[
                  const _HDivider(),
                  _InfoRow(
                      icon: Icons.email_outlined,
                      label: 'Email',
                      value: self.email!),
                ],
                if (self.gender.isNotEmpty) ...[
                  const _HDivider(),
                  _InfoRow(
                      icon: Icons.person_outline_rounded,
                      label: 'Gender',
                      value: self.gender),
                ],
                if (self.dob != null) ...[
                  const _HDivider(),
                  _InfoRow(
                      icon: Icons.cake_outlined,
                      label: 'Date of Birth',
                      value: _formatDob(self.dob!, self.age)),
                ],
                if (self.address.isNotEmpty) ...[
                  const _HDivider(),
                  _InfoRow(
                      icon: Icons.location_on_outlined,
                      label: 'Address',
                      value: self.address),
                ],
                if (self.location.isNotEmpty) ...[
                  const _HDivider(),
                  _InfoRow(
                      icon: Icons.map_outlined,
                      label: 'Location',
                      value: self.location),
                ],
                if (self.healthCondition != null &&
                    self.healthCondition!.isNotEmpty) ...[
                  const _HDivider(),
                  _InfoRow(
                      icon: Icons.favorite_border_rounded,
                      label: 'Health Info',
                      value: self.healthCondition!),
                ],
              ],
            ],
          ),
        ),

        const SizedBox(height: 24),

        // ── Patients ─────────────────────────────────────────
        Row(
          children: [
            const Text('Customer', style: CxText.sectionTitle),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: onAddMember,
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
              label: const Text('Add '),
              style: OutlinedButton.styleFrom(
                foregroundColor: CxColors.brand,
                side: const BorderSide(color: CxColors.brand, width: 1.4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                minimumSize: const Size(64, 40),
                textStyle: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600),
                shape: const StadiumBorder(),
              ),
            ),
          ],
        ),
        const SizedBox(height: CxSpace.md),

        if (patients.isEmpty)
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: CxRadius.lgAll,
              border: Border.all(color: CxColors.border),
            ),
            child: const CxEmptyState(
              icon: Icons.people_outline_rounded,
              title: 'No customers added yet',
              message: 'Tap "Add" to add family members',
            ),
          ),

        ...patients.map((m) => _PatientCard(
              member: m,
              onEdit: m.isReadOnly ? null : () => onEditMember(m),
              onView: onViewMember == null ? null : () => onViewMember!(m),
              onRemove: m.isReadOnly || onRemoveMember == null ? null : () => onRemoveMember!(m),
            )),

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
    );

    if (embedded) {
      return CustomerThemeScope(
        child: Column(
        children: [
          header,
          Expanded(
            child: ColoredBox(color: CxColors.page, child: body),
          ),
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
            style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
        actions: [
          TextButton.icon(
            onPressed: () => _confirmLogout(context, onLogout),
            icon: const Icon(Icons.logout_rounded, size: 18, color: Colors.white),
            label: const Text('Logout',
                style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: body,
      ),
    );
  }

  String _formatDob(DateTime dob, int? age) {
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final formatted = '${dob.day} ${months[dob.month]} ${dob.year}';
    return age != null ? '$formatted  ($age yrs)' : formatted;
  }
}

// ─── Avatar ───────────────────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  final MemberModel? member;
  const _Avatar({this.member});

  @override
  Widget build(BuildContext context) {
    if (member?.photoBytes != null) {
      return CircleAvatar(
        radius: 30,
        backgroundImage: MemoryImage(member!.photoBytes!),
      );
    }
    if (member?.photoUrl != null && member!.photoUrl!.isNotEmpty) {
      return CircleAvatar(
        radius: 30,
        backgroundImage: NetworkImage(member!.photoUrl!),
      );
    }
    final initials = member?.name.isNotEmpty == true
        ? member!.name.trim().split(' ').where((w) => w.isNotEmpty).take(2).map((w) => w[0]).join()
        : '?';
    return Container(
      width: 60,
      height: 60,
      decoration: const BoxDecoration(
          color: AppColors.brandGreenSurface, shape: BoxShape.circle),
      child: Center(
        child: Text(initials.toUpperCase(),
            style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppColors.brandGreen)),
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
          textStyle:
              const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
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
          Icon(icon, size: 18, color: CxColors.textHint),
          const SizedBox(width: 12),
          SizedBox(
            width: 100,
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
      );
}

class _HDivider extends StatelessWidget {
  const _HDivider();

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 24, thickness: 1, color: CxColors.border);
}

// ─── Patient Card ─────────────────────────────────────────────────────────────

class _PatientCard extends StatelessWidget {
  final MemberModel member;
  final VoidCallback? onEdit;
  final VoidCallback? onView;   // tap the card
  final VoidCallback? onRemove;
  const _PatientCard({required this.member, this.onEdit, this.onView, this.onRemove});

  @override
  Widget build(BuildContext context) {
    final chips = <String>[
      if (member.relation != null) member.relation!,
      if (member.gender.isNotEmpty) member.gender,
      if (member.age != null) '${member.age} yrs',
    ];

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Avatar
          Container(
            width: 44,
            height: 44,
            margin: const EdgeInsets.only(right: 12, top: 2),
            decoration: const BoxDecoration(
                color: AppColors.brandGreenSurface, shape: BoxShape.circle),
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
                    spacing: 6,
                    runSpacing: 4,
                    children: chips
                        .map((c) => CxChip(label: c, tone: CxTone.neutral))
                        .toList(),
                  ),
                ],
                if (member.healthCondition != null &&
                    member.healthCondition!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.favorite_border_rounded,
                          size: 14, color: CxColors.textSecondary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(member.healthCondition!, style: CxText.caption),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (onEdit != null)
            CxIconButton(
              icon: Icons.edit_outlined,
              tooltip: 'Edit ${member.name}',
              color: CxColors.brand,
              onPressed: onEdit,
            ),
          if (onRemove != null)
            CxIconButton(
              icon: Icons.person_remove_outlined,
              tooltip: 'Remove ${member.name}',
              color: CxColors.error,
              onPressed: onRemove,
            ),
        ],
      ),
    );
    // Tapping the card opens the member's details (same as before).
    return Padding(
      padding: const EdgeInsets.only(bottom: CxSpace.md),
      child: Material(
        color: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: CxRadius.lgAll,
          side: BorderSide(color: CxColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: onView == null ? content : InkWell(onTap: onView, child: content),
      ),
    );
  }
}
