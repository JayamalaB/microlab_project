import 'package:flutter/material.dart';
import 'package:microlab/theme/tech_theme.dart';
import 'package:microlab/widgets/tech/tech_buttons.dart';
import 'package:microlab/widgets/tech/tech_dialog.dart';

/// Nothing to show yet: icon, title, optional message and action.
class TechEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const TechEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) => _StateLayout(
        badge: TechIconBadge(icon: icon, tone: TechTone.neutral, size: 64),
        title: title,
        message: message,
        action: actionLabel != null && onAction != null
            ? TechButton.secondary(label: actionLabel!, onPressed: onAction, expand: false, compact: true)
            : null,
      );
}

/// Loading failed: plain-language message and a Retry button.
class TechErrorState extends StatelessWidget {
  final String title;
  final String? message;
  final VoidCallback? onRetry;
  final String retryLabel;

  const TechErrorState({
    super.key,
    this.title = "Couldn't load this",
    this.message,
    this.onRetry,
    this.retryLabel = 'Try again',
  });

  @override
  Widget build(BuildContext context) => _StateLayout(
        badge: const TechIconBadge(icon: Icons.cloud_off_rounded, tone: TechTone.error, size: 64),
        title: title,
        message: message,
        action: onRetry != null
            ? TechButton(label: retryLabel, icon: Icons.refresh_rounded,
                onPressed: onRetry, expand: false, compact: true)
            : null,
      );
}

/// A centred spinner with an optional label (for actions and short waits;
/// first-time list loading keeps using the skeleton loaders).
class TechLoadingState extends StatelessWidget {
  final String? label;
  const TechLoadingState({super.key, this.label});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(TechSpace.xxl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(
              width: 28, height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.6, color: TechColors.brand),
            ),
            if (label != null) ...[
              const SizedBox(height: TechSpace.md),
              Text(label!, textAlign: TextAlign.center, style: TechText.bodySecondary),
            ],
          ]),
        ),
      );
}

class _StateLayout extends StatelessWidget {
  final Widget badge;
  final String title;
  final String? message;
  final Widget? action;
  const _StateLayout({required this.badge, required this.title, this.message, this.action});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: TechSpace.xxl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              badge,
              const SizedBox(height: TechSpace.lg),
              Text(title, textAlign: TextAlign.center, style: TechText.sectionTitle),
              if (message != null) ...[
                const SizedBox(height: 6),
                Text(message!, textAlign: TextAlign.center, style: TechText.bodySecondary),
              ],
              if (action != null) ...[
                const SizedBox(height: TechSpace.xl),
                action!,
              ],
            ]),
          ),
        ),
      );
}

/// An inline notice inside a card, sheet or dialog (replaces the one-off
/// yellow / red / blue boxes). Subtle tinted background, icon, text.
class TechBanner extends StatelessWidget {
  final String message;
  final TechTone tone;
  final IconData? icon;

  const TechBanner({super.key, required this.message, this.tone = TechTone.info, this.icon});

  IconData get _icon => icon ?? switch (tone) {
        TechTone.error => Icons.error_outline_rounded,
        TechTone.warning => Icons.warning_amber_rounded,
        TechTone.success || TechTone.brand => Icons.check_circle_outline_rounded,
        TechTone.info || TechTone.neutral => Icons.info_outline_rounded,
      };

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: tone.surface, borderRadius: TechRadius.mdAll),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(_icon, size: 18, color: tone.color),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: TechText.bodySecondary.copyWith(color: TechColors.textPrimary))),
        ]),
      );
}

/// A small status pill ("Confirmed", "Paid", "Pending").
class TechStatusChip extends StatelessWidget {
  final String label;
  final TechTone tone;
  final IconData? icon;

  const TechStatusChip({super.key, required this.label, this.tone = TechTone.neutral, this.icon});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: tone.surface, borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 14, color: tone.color), const SizedBox(width: 4)],
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: tone.color)),
        ]),
      );
}

/// A white section card with an optional title row (icon + title + trailing).
class TechSectionCard extends StatelessWidget {
  final String? title;
  final IconData? icon;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  const TechSectionCard({
    super.key,
    this.title,
    this.icon,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.all(TechSpace.lg),
  });

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: TechRadius.lgAll,
          border: Border.all(color: TechColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (title != null) ...[
            Row(children: [
              if (icon != null) ...[Icon(icon, size: 20, color: TechColors.brand), const SizedBox(width: 8)],
              Expanded(child: Text(title!, style: TechText.sectionTitle)),
              if (trailing != null) trailing!,
            ]),
            const SizedBox(height: TechSpace.md),
          ],
          child,
        ]),
      );
}
