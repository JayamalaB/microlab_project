import 'package:flutter/material.dart';
import 'package:microlab/theme/customer_theme.dart';
import 'package:microlab/widgets/customer/cx_buttons.dart';

/// A customer dialog: optional tinted icon, title, message / content and
/// full-width actions (side by side for two, stacked when narrow).
class CxDialog extends StatelessWidget {
  final IconData? icon;
  final CxTone tone;
  final String title;
  final String? message;
  final Widget? content;
  final List<Widget> actions;
  final bool centered;

  const CxDialog({
    super.key,
    this.icon,
    this.tone = CxTone.brand,
    required this.title,
    this.message,
    this.content,
    this.actions = const [],
    this.centered = true,
  });

  @override
  Widget build(BuildContext context) {
    final align = centered ? TextAlign.center : TextAlign.start;
    final mq = MediaQuery.of(context);
    return CustomerThemeScope(
      child: Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: CxRadius.xlAll),
        insetPadding: const EdgeInsets.symmetric(horizontal: CxSpace.xl, vertical: CxSpace.xxl),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: CxSize.dialogMaxWidth,
            maxHeight: (mq.size.height - mq.viewInsets.bottom) * 0.85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(CxSpace.xxl, CxSpace.xxl, CxSpace.xxl, CxSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
              children: [
                if (icon != null) ...[
                  CxIconBadge(icon: icon!, tone: tone, size: 52),
                  const SizedBox(height: CxSpace.lg),
                ],
                Text(title, textAlign: align, style: CxText.sheetTitle),
                if (message != null) ...[
                  const SizedBox(height: CxSpace.sm),
                  Text(message!, textAlign: align, style: CxText.bodySecondary),
                ],
                if (content != null) ...[
                  const SizedBox(height: CxSpace.lg),
                  SizedBox(width: double.infinity, child: content!),
                ],
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: CxSpace.xl),
                  LayoutBuilder(builder: (context, c) {
                    if (actions.length == 2 && c.maxWidth >= 280) {
                      return Row(children: [
                        Expanded(child: actions[0]),
                        const SizedBox(width: CxSpace.md),
                        Expanded(child: actions[1]),
                      ]);
                    }
                    final stacked = actions.reversed.toList();
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (var i = 0; i < stacked.length; i++) ...[
                        if (i > 0) const SizedBox(height: CxSpace.sm),
                        stacked[i],
                      ],
                    ]);
                  }),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Yes/no confirmation; true only when confirmed.
Future<bool> showCxConfirm(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  IconData? icon,
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => CxDialog(
      icon: icon,
      tone: destructive ? CxTone.error : CxTone.brand,
      title: title,
      message: message,
      actions: [
        CxButton.secondary(label: cancelLabel, compact: true, onPressed: () => Navigator.pop(ctx, false)),
        destructive
            ? CxButton.destructive(label: confirmLabel, compact: true, onPressed: () => Navigator.pop(ctx, true))
            : CxButton(label: confirmLabel, compact: true, onPressed: () => Navigator.pop(ctx, true)),
      ],
    ),
  );
  return ok == true;
}

/// Rounded tinted square with an icon.
class CxIconBadge extends StatelessWidget {
  final IconData icon;
  final CxTone tone;
  final double size;
  const CxIconBadge({super.key, required this.icon, this.tone = CxTone.brand, this.size = 44});

  @override
  Widget build(BuildContext context) => Container(
        width: size, height: size,
        decoration: BoxDecoration(color: tone.surface, borderRadius: BorderRadius.circular(size * 0.3)),
        child: Icon(icon, color: tone.color, size: size * 0.5),
      );
}
