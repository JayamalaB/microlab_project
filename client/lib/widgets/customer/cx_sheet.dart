import 'package:flutter/material.dart';
import 'package:microlab/theme/customer_theme.dart';

/// Opens a customer bottom sheet: rounded top, drag handle, optional title,
/// safe area, keyboard-aware, scrolls when tall, max 600px wide.
Future<T?> showCxSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? title,
  String? subtitle,
  bool centerTitle = false,
  bool isDismissible = true,
  bool enableDrag = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    backgroundColor: Colors.transparent,
    elevation: 0,
    constraints: const BoxConstraints(maxWidth: CxSize.sheetMaxWidth),
    builder: (ctx) => CustomerThemeScope(
      child: CxSheetFrame(
        title: title,
        subtitle: subtitle,
        centerTitle: centerTitle,
        child: Builder(builder: builder),
      ),
    ),
  );
}

/// The frame every customer sheet shares. Use it directly inside an existing
/// showModalBottomSheet builder (pass backgroundColor: Colors.transparent).
class CxSheetFrame extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final bool centerTitle;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;
  final bool scrollable;

  /// Fixed share of the screen height (e.g. 0.85) for sheets whose content
  /// fills the space (lists); null sizes the sheet to its content.
  final double? heightFactor;

  const CxSheetFrame({
    super.key,
    this.title,
    this.subtitle,
    this.centerTitle = false,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(CxSpace.xl, 0, CxSpace.xl, CxSpace.xl),
    this.scrollable = true,
    this.heightFactor,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final align = centerTitle ? TextAlign.center : TextAlign.start;
    final hasHeader = title != null || subtitle != null || trailing != null;

    final header = Padding(
      padding: EdgeInsets.fromLTRB(padding.left, 0, padding.right, hasHeader ? CxSpace.lg : 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(
            crossAxisAlignment: centerTitle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              if (title != null) Text(title!, textAlign: align, style: CxText.sheetTitle),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(subtitle!, textAlign: align, style: CxText.bodySecondary),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ]),
    );

    final body = Padding(
      padding: EdgeInsets.fromLTRB(padding.left, 0, padding.right, padding.bottom + mq.padding.bottom),
      child: child,
    );

    final maxH = (mq.size.height - mq.viewInsets.bottom) * 0.92;
    final content = Column(
      mainAxisSize: heightFactor == null ? MainAxisSize.min : MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const CxDragHandle(),
        header,
        if (heightFactor != null)
          Expanded(child: body)
        else
          Flexible(child: scrollable ? SingleChildScrollView(child: body) : body),
      ],
    );

    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: CxSize.sheetMaxWidth, maxHeight: maxH),
          child: Material(
            color: Colors.white,
            shape: const RoundedRectangleBorder(borderRadius: CxRadius.sheetTop),
            clipBehavior: Clip.antiAlias,
            child: heightFactor == null
                ? content
                : SizedBox(height: (mq.size.height * heightFactor!).clamp(0, maxH), child: content),
          ),
        ),
      ),
    );
  }
}

class CxDragHandle extends StatelessWidget {
  const CxDragHandle({super.key});

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          margin: const EdgeInsets.only(top: 10, bottom: 14),
          width: 40, height: 4,
          decoration: BoxDecoration(color: CxColors.border, borderRadius: BorderRadius.circular(2)),
        ),
      );
}
