import 'package:flutter/material.dart';
import 'package:microlab/theme/tech_theme.dart';
import 'package:microlab/widgets/tech/tech_dialog.dart';

/// A tappable choice: tinted icon, title, description and a chevron (or a
/// check when [selected]). Used for "Single / Individual payment",
/// "Camera / Gallery", "Cash / Razorpay" and similar pickers.
class TechOptionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool selected;
  final TechTone tone;
  final Widget? trailing;

  const TechOptionCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.selected = false,
    this.tone = TechTone.brand,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: Material(
        color: selected ? tone.surface : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: TechRadius.lgAll,
          side: BorderSide(
            color: selected ? tone.color : TechColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: Padding(
              padding: const EdgeInsets.all(TechSpace.lg),
              child: Row(
                children: [
                  TechIconBadge(icon: icon, tone: tone, size: 44),
                  const SizedBox(width: TechSpace.md + 2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: TechText.cardTitle),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(subtitle!, style: TechText.bodySecondary),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: TechSpace.sm),
                  trailing ??
                      Icon(
                        selected ? Icons.check_circle_rounded : Icons.chevron_right_rounded,
                        color: selected ? tone.color : TechColors.textHint,
                        size: selected ? 22 : 24,
                      ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
