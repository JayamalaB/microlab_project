import 'package:flutter/material.dart';
import 'package:microlab/theme/tech_theme.dart';

/// Opens a technician bottom sheet: rounded top, drag handle, title, safe
/// area, keyboard-aware, scrolls when tall, max 560px wide on tablets.
///
///   final result = await showTechSheet<String>(
///     context: context,
///     title: 'Collect Payment',
///     subtitle: 'RAJA · #180591',
///     builder: (ctx) => Column(...),
///   );
///
/// The builder returns only the sheet's content; the frame is added here.
Future<T?> showTechSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? title,
  String? subtitle,
  bool centerTitle = true,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useRootNavigator = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useRootNavigator: useRootNavigator,
    backgroundColor: Colors.transparent,
    elevation: 0,
    constraints: const BoxConstraints(maxWidth: TechSize.sheetMaxWidth),
    builder: (ctx) => TechThemeScope(
      child: TechSheetFrame(
        title: title,
        subtitle: subtitle,
        centerTitle: centerTitle,
        child: Builder(builder: builder),
      ),
    ),
  );
}

/// The frame every technician sheet shares. Use it directly when a sheet is
/// opened with showModalBottomSheet (e.g. one that needs a StatefulBuilder);
/// pass `backgroundColor: Colors.transparent` and `isScrollControlled: true`.
class TechSheetFrame extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final bool centerTitle;
  final Widget child;

  /// Content padding; the bottom safe area and keyboard are added to it.
  final EdgeInsets padding;

  /// Wrap content in a scroll view (turn off when [child] scrolls itself).
  final bool scrollable;

  const TechSheetFrame({
    super.key,
    this.title,
    this.subtitle,
    this.centerTitle = true,
    this.padding = const EdgeInsets.fromLTRB(TechSpace.gutter, 0, TechSpace.gutter, TechSpace.xl),
    this.scrollable = true,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final align = centerTitle ? TextAlign.center : TextAlign.start;
    final cross = centerTitle ? CrossAxisAlignment.center : CrossAxisAlignment.start;

    final header = <Widget>[
      const TechDragHandle(),
      if (title != null)
        SizedBox(
          width: double.infinity,
          child: Text(title!, textAlign: align, style: TechText.sheetTitle),
        ),
      if (subtitle != null) ...[
        const SizedBox(height: 4),
        SizedBox(
          width: double.infinity,
          child: Text(subtitle!, textAlign: align, maxLines: 2,
              overflow: TextOverflow.ellipsis, style: TechText.bodySecondary),
        ),
      ],
      if (title != null || subtitle != null) const SizedBox(height: TechSpace.xl),
    ];

    final body = Padding(
      padding: padding.copyWith(bottom: padding.bottom + mq.padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(crossAxisAlignment: cross, mainAxisSize: MainAxisSize.min, children: header),
          child,
        ],
      ),
    );

    // Keyboard: the sheet rises above it; max 90% of the screen, then scrolls.
    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: TechSize.sheetMaxWidth,
            maxHeight: (mq.size.height - mq.viewInsets.bottom) * 0.9,
          ),
          child: Material(
            color: Colors.white,
            shape: const RoundedRectangleBorder(borderRadius: TechRadius.sheetTop),
            clipBehavior: Clip.antiAlias,
            child: scrollable ? SingleChildScrollView(child: body) : body,
          ),
        ),
      ),
    );
  }
}

/// The small grey bar at the top of every sheet.
class TechDragHandle extends StatelessWidget {
  const TechDragHandle({super.key});

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          margin: const EdgeInsets.only(top: 10, bottom: 16),
          width: 36, height: 4,
          decoration: BoxDecoration(
            color: TechColors.border,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}
