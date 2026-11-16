import 'package:flutter/material.dart';
import 'package:microlab/theme/tech_theme.dart';
import 'package:microlab/widgets/tech/tech_buttons.dart';

/// A technician dialog: optional tinted icon, title, message and/or custom
/// content, and actions laid out full width (side by side for two, stacked
/// otherwise or when space is tight).
class TechDialog extends StatelessWidget {
  final IconData? icon;
  final TechTone tone;
  final String title;
  final String? message;
  final Widget? content;
  final List<Widget> actions;
  final bool centered;

  const TechDialog({
    super.key,
    this.icon,
    this.tone = TechTone.brand,
    required this.title,
    this.message,
    this.content,
    this.actions = const [],
    this.centered = false,
  });

  @override
  Widget build(BuildContext context) {
    final align = centered ? TextAlign.center : TextAlign.start;
    final cross = centered ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    final mq = MediaQuery.of(context);

    return TechThemeScope(
      child: Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: TechRadius.xlAll),
        insetPadding: const EdgeInsets.symmetric(horizontal: TechSpace.xl, vertical: TechSpace.xxl),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: TechSize.dialogMaxWidth,
            maxHeight: (mq.size.height - mq.viewInsets.bottom) * 0.85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(TechSpace.xxl, TechSpace.xxl, TechSpace.xxl, TechSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: cross,
              children: [
                if (icon != null) ...[
                  TechIconBadge(icon: icon!, tone: tone, size: 48),
                  const SizedBox(height: TechSpace.lg),
                ],
                Text(title, textAlign: align, style: TechText.dialogTitle),
                if (message != null) ...[
                  const SizedBox(height: TechSpace.sm),
                  Text(message!, textAlign: align, style: TechText.bodySecondary),
                ],
                if (content != null) ...[
                  const SizedBox(height: TechSpace.lg),
                  SizedBox(width: double.infinity, child: content!),
                ],
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: TechSpace.xl),
                  _DialogActions(actions: actions),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DialogActions extends StatelessWidget {
  final List<Widget> actions;
  const _DialogActions({required this.actions});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      // Two actions side by side when there is room; otherwise stacked with
      // the primary (last) action on top.
      if (actions.length == 2 && c.maxWidth >= 280) {
        return Row(children: [
          Expanded(child: actions[0]),
          const SizedBox(width: TechSpace.md),
          Expanded(child: actions[1]),
        ]);
      }
      final stacked = actions.reversed.toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < stacked.length; i++) ...[
            if (i > 0) const SizedBox(height: TechSpace.sm),
            stacked[i],
          ],
        ],
      );
    });
  }
}

/// A yes/no confirmation. Returns true only when confirmed.
///
///   if (!await showTechConfirm(context,
///       title: 'Remove photo?', message: '…',
///       confirmLabel: 'Remove', destructive: true)) return;
Future<bool> showTechConfirm(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  IconData? icon,
  bool destructive = false,
  bool barrierDismissible = true,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => TechDialog(
      icon: icon,
      tone: destructive ? TechTone.error : TechTone.brand,
      title: title,
      message: message,
      actions: [
        TechButton.secondary(
          label: cancelLabel, compact: true,
          onPressed: () => Navigator.pop(ctx, false),
        ),
        destructive
            ? TechButton.destructive(
                label: confirmLabel, compact: true,
                onPressed: () => Navigator.pop(ctx, true))
            : TechButton(
                label: confirmLabel, compact: true,
                onPressed: () => Navigator.pop(ctx, true)),
      ],
    ),
  );
  return ok == true;
}

/// A rounded square with a tinted background and an icon.
class TechIconBadge extends StatelessWidget {
  final IconData icon;
  final TechTone tone;
  final double size;
  const TechIconBadge({super.key, required this.icon, this.tone = TechTone.brand, this.size = 44});

  @override
  Widget build(BuildContext context) => Container(
        width: size, height: size,
        decoration: BoxDecoration(
          color: tone.surface,
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
        child: Icon(icon, color: tone.color, size: size * 0.5),
      );
}
