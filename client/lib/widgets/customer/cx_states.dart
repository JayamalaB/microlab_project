import 'package:flutter/material.dart';
import 'package:microlab/theme/customer_theme.dart';
import 'package:microlab/widgets/customer/cx_buttons.dart';
import 'package:microlab/widgets/customer/cx_dialog.dart';

class _StateLayout extends StatelessWidget {
  final Widget badge;
  final String title;
  final String? message;
  final Widget? action;
  const _StateLayout({required this.badge, required this.title, this.message, this.action});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: CxSpace.xxl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              badge,
              const SizedBox(height: CxSpace.lg),
              Text(title, textAlign: TextAlign.center, style: CxText.sectionTitle),
              if (message != null) ...[
                const SizedBox(height: 6),
                Text(message!, textAlign: TextAlign.center, style: CxText.bodySecondary),
              ],
              if (action != null) ...[const SizedBox(height: CxSpace.xl), action!],
            ]),
          ),
        ),
      );
}

class CxEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const CxEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) => _StateLayout(
        badge: CxIconBadge(icon: icon, tone: CxTone.brand, size: 68),
        title: title,
        message: message,
        action: actionLabel != null && onAction != null
            ? CxButton.secondary(label: actionLabel!, onPressed: onAction, expand: false, compact: true)
            : null,
      );
}

class CxErrorState extends StatelessWidget {
  final String title;
  final String? message;
  final VoidCallback? onRetry;
  final String retryLabel;

  const CxErrorState({
    super.key,
    this.title = "Couldn't load this",
    this.message,
    this.onRetry,
    this.retryLabel = 'Try again',
  });

  @override
  Widget build(BuildContext context) => _StateLayout(
        badge: const CxIconBadge(icon: Icons.cloud_off_rounded, tone: CxTone.error, size: 68),
        title: title,
        message: message,
        action: onRetry != null
            ? CxButton(label: retryLabel, icon: Icons.refresh_rounded, onPressed: onRetry,
                expand: false, compact: true)
            : null,
      );
}

class CxLoading extends StatelessWidget {
  final String? label;
  const CxLoading({super.key, this.label});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(CxSpace.xxl),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(
              width: 28, height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.6, color: CxColors.brand),
            ),
            if (label != null) ...[
              const SizedBox(height: CxSpace.md),
              Text(label!, textAlign: TextAlign.center, style: CxText.bodySecondary),
            ],
          ]),
        ),
      );
}

/// Inline notice with tinted background.
class CxBanner extends StatelessWidget {
  final String message;
  final CxTone tone;
  final IconData? icon;
  final String? title;

  const CxBanner({super.key, required this.message, this.tone = CxTone.info, this.icon, this.title});

  IconData get _icon => icon ?? switch (tone) {
        CxTone.error => Icons.error_outline_rounded,
        CxTone.warning => Icons.warning_amber_rounded,
        CxTone.success || CxTone.brand => Icons.check_circle_outline_rounded,
        CxTone.offer => Icons.local_offer_outlined,
        CxTone.info || CxTone.neutral => Icons.info_outline_rounded,
      };

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: tone.surface, borderRadius: CxRadius.mdAll),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(_icon, size: 18, color: tone.color)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (title != null) ...[
                Text(title!, style: CxText.label.copyWith(color: tone.color)),
                const SizedBox(height: 2),
              ],
              Text(message, style: CxText.bodySecondary.copyWith(color: CxColors.textPrimary)),
            ]),
          ),
        ]),
      );
}
