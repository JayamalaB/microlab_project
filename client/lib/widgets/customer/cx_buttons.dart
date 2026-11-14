import 'package:flutter/material.dart';
import 'package:microlab/theme/customer_theme.dart';

enum CxButtonVariant { primary, secondary, text, destructive }

/// The customer app's button: filled (primary), outlined (secondary), text,
/// or destructive. Full width by default, 50px tall (42px when [compact]),
/// optional leading icon, and a loading state that ignores taps.
class CxButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final CxButtonVariant variant;
  final bool loading;
  final bool expand;
  final bool compact;

  const CxButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.variant = CxButtonVariant.primary,
    this.loading = false,
    this.expand = true,
    this.compact = false,
  });

  const CxButton.secondary({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.expand = true,
    this.compact = false,
  }) : variant = CxButtonVariant.secondary;

  const CxButton.text({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.expand = false,
    this.compact = true,
  }) : variant = CxButtonVariant.text;

  const CxButton.destructive({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.expand = true,
    this.compact = false,
  }) : variant = CxButtonVariant.destructive;

  @override
  Widget build(BuildContext context) {
    final height = compact ? CxSize.buttonHeightCompact : CxSize.buttonHeight;
    final tap = loading ? null : onPressed;
    final filled = variant == CxButtonVariant.primary || variant == CxButtonVariant.destructive;
    final fill = variant == CxButtonVariant.destructive ? CxColors.error : CxColors.brand;
    final fg = filled ? Colors.white : CxColors.brand;

    final Widget child = loading
        ? SizedBox(
            width: 20, height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: fg),
          )
        : Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
            Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ]);

    const shape = RoundedRectangleBorder(borderRadius: CxRadius.mdAll);
    final textStyle = compact ? CxText.button.copyWith(fontSize: 14) : CxText.button;
    final size = Size(expand ? double.infinity : 64, height);

    final Widget button = switch (variant) {
      CxButtonVariant.primary || CxButtonVariant.destructive => FilledButton(
          onPressed: tap,
          style: FilledButton.styleFrom(
            backgroundColor: fill,
            foregroundColor: Colors.white,
            disabledBackgroundColor: loading ? fill : CxColors.border,
            disabledForegroundColor: loading ? Colors.white : CxColors.textHint,
            minimumSize: size, shape: shape, textStyle: textStyle,
          ),
          child: child,
        ),
      CxButtonVariant.secondary => OutlinedButton(
          onPressed: tap,
          style: OutlinedButton.styleFrom(
            foregroundColor: CxColors.brand,
            side: BorderSide(
                color: tap == null && !loading ? CxColors.border : CxColors.brand, width: 1.2),
            minimumSize: size, shape: shape, textStyle: textStyle,
          ),
          child: child,
        ),
      CxButtonVariant.text => TextButton(
          onPressed: tap,
          style: TextButton.styleFrom(
            foregroundColor: CxColors.brand,
            minimumSize: size, shape: shape, textStyle: textStyle,
          ),
          child: child,
        ),
    };
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// A round icon button with a tooltip (screen readers read the tooltip).
class CxIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final Color? background;
  final double size;

  const CxIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color,
    this.background,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: background ?? Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: SizedBox(
              width: size, height: size,
              child: Icon(icon, size: size * 0.5, color: color ?? CxColors.textPrimary),
            ),
          ),
        ),
      );
}
