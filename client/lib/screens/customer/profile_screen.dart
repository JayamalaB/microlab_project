import 'package:flutter/material.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/models.dart';

Future<void> _confirmLogout(BuildContext context, VoidCallback onLogout) async {
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
            decoration: const BoxDecoration(
              color: Color(0xFFFFEBEE),
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
  if (confirmed == true) onLogout();
}

class ProfileScreen extends StatelessWidget {
  final String mobile;
  final bool isVip;
  final List<MemberModel> members;
  final VoidCallback onAddMember;
  final void Function(MemberModel) onEditMember;
  final VoidCallback onLogout;
  final bool embedded;

  const ProfileScreen({
    super.key,
    required this.mobile,
    required this.members,
    required this.onAddMember,
    required this.onEditMember,
    required this.onLogout,
    this.isVip = false,
    this.embedded = false,
  });

  MemberModel? get _self {
    try {
      return members.firstWhere((m) => m.relation == 'Self');
    } catch (_) {
      return members.isNotEmpty ? members.first : null;
    }
  }

  List<MemberModel> get _patients =>
      members.where((m) => m.relation != 'Self').toList();

  @override
  Widget build(BuildContext context) {
    final topPad = embedded ? MediaQuery.of(context).padding.top : 0.0;
    final self = _self;
    final patients = _patients;

    final header = Container(
      color: AppColors.brandGreen,
      padding: EdgeInsets.fromLTRB(16, topPad + 16, 8, 14),
      child: Row(
        children: [
          const Text('Profile',
              style: TextStyle(
                  color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
          if (isVip) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFFFB300),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.star_rounded, size: 10, color: Colors.white),
                  SizedBox(width: 3),
                  Text('VIP',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 0.5)),
                ],
              ),
            ),
          ],
          const Spacer(),
          TextButton.icon(
            onPressed: () => _confirmLogout(context, onLogout),
            icon: const Icon(Icons.logout_rounded, size: 15, color: Colors.white70),
            label: const Text('Logout',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );

    final body = ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 80),
      children: [
        // ── Account Details ──────────────────────────────────
        Row(
          children: [
            const Text('Account Details',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            const Spacer(),
            if (self != null)
              _EditButton(onTap: () => onEditMember(self)),
          ],
        ),
        const SizedBox(height: 10),

        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.divider),
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
                          self?.name ?? '—',
                          style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          [
                            if (self?.relation != null) self!.relation,
                            if (self?.location.isNotEmpty == true) self!.location,
                          ].join(' · '),
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textSecondary),
                        ),
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
              if (self?.email != null && self!.email!.isNotEmpty) ...[
                const _HDivider(),
                _InfoRow(
                    icon: Icons.email_outlined,
                    label: 'Email',
                    value: self.email!),
              ],
              if (self?.gender.isNotEmpty == true) ...[
                const _HDivider(),
                _InfoRow(
                    icon: Icons.person_outline_rounded,
                    label: 'Gender',
                    value: self!.gender),
              ],
              if (self?.dob != null) ...[
                const _HDivider(),
                _InfoRow(
                    icon: Icons.cake_outlined,
                    label: 'Date of Birth',
                    value: _formatDob(self!.dob!, self.age)),
              ],
              if (self?.address.isNotEmpty == true) ...[
                const _HDivider(),
                _InfoRow(
                    icon: Icons.location_on_outlined,
                    label: 'Address',
                    value: self!.address),
              ],
              if (self?.location.isNotEmpty == true) ...[
                const _HDivider(),
                _InfoRow(
                    icon: Icons.map_outlined,
                    label: 'Location',
                    value: self!.location),
              ],
              if (self?.healthCondition != null &&
                  self!.healthCondition!.isNotEmpty) ...[
                const _HDivider(),
                _InfoRow(
                    icon: Icons.favorite_border_rounded,
                    label: 'Health Info',
                    value: self.healthCondition!),
              ],
            ],
          ),
        ),

        const SizedBox(height: 24),

        // ── Patients ─────────────────────────────────────────
        Row(
          children: [
            const Text('Customer',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: onAddMember,
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 15),
              label: const Text('Add '),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.brandGreen,
                side: const BorderSide(color: AppColors.brandGreen, width: 1.5),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                textStyle: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600),
                visualDensity: VisualDensity.compact,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        if (patients.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 28),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.divider),
            ),
            child: const Column(
              children: [
                Icon(Icons.people_outline_rounded,
                    size: 32, color: AppColors.textHint),
                SizedBox(height: 8),
                Text('No patients added yet',
                    style: TextStyle(
                        fontSize: 14, color: AppColors.textSecondary)),
                SizedBox(height: 2),
                Text('Tap "Add Patient" to add family members',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textHint)),
              ],
            ),
          ),

        ...patients.map((m) => _PatientCard(
              member: m,
              onEdit: () => onEditMember(m),
            )),
      ],
    );

    if (embedded) {
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
                color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
        actions: [
          TextButton.icon(
            onPressed: () => _confirmLogout(context, onLogout),
            icon: const Icon(Icons.logout_rounded, size: 16, color: Colors.white70),
            label: const Text('Logout',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
          ),
        ],
      ),
      body: body,
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
    final initials = member?.name.isNotEmpty == true
        ? member!.name.trim().split(' ').take(2).map((w) => w[0]).join()
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
        icon: const Icon(Icons.edit_outlined, size: 14),
        label: const Text('Edit'),
        style: TextButton.styleFrom(
          foregroundColor: AppColors.brandGreen,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          textStyle:
              const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
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
          Icon(icon, size: 15, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          SizedBox(
            width: 90,
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
        ],
      );
}

class _HDivider extends StatelessWidget {
  const _HDivider();

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 22, thickness: 1, color: AppColors.divider);
}

// ─── Patient Card ─────────────────────────────────────────────────────────────

class _PatientCard extends StatelessWidget {
  final MemberModel member;
  final VoidCallback onEdit;
  const _PatientCard({required this.member, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final chips = <String>[
      if (member.relation != null) member.relation!,
      if (member.gender.isNotEmpty) member.gender,
      if (member.age != null) '${member.age} yrs',
    ];

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Avatar
          Container(
            width: 40,
            height: 40,
            margin: const EdgeInsets.only(right: 12, top: 2),
            decoration: const BoxDecoration(
                color: AppColors.brandGreenSurface, shape: BoxShape.circle),
            child: Center(
              child: Text(
                member.name.isNotEmpty ? member.name[0].toUpperCase() : '?',
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.brandGreen),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(member.name,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                if (chips.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: chips
                        .map((c) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: AppColors.background,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: AppColors.divider),
                              ),
                              child: Text(c,
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: AppColors.textSecondary)),
                            ))
                        .toList(),
                  ),
                ],
                if (member.healthCondition != null &&
                    member.healthCondition!.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      const Icon(Icons.favorite_border_rounded,
                          size: 12, color: AppColors.textSecondary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(member.healthCondition!,
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.textSecondary)),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          // Edit icon
          GestureDetector(
            onTap: onEdit,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: AppColors.brandGreenSurface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.edit_outlined,
                  size: 16, color: AppColors.brandGreen),
            ),
          ),
        ],
      ),
    );
  }
}
