import 'package:flutter/material.dart';
import 'package:microlab/theme/tech_theme.dart';

enum TechButtonVariant { primary, secondary, text, destructive }

/// The technician app's one button: filled (primary), outlined (secondary),
/// text, or destructive (filled red). Full width by default, 52px tall
/// (44px when [compact]), with an optional leading icon and a loading state
/// that shows a spinner and ignores taps.
class TechButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final TechButtonVariant variant;
  final bool loading;
  final bool expand;
  final bool compact;

  const TechButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.variant = TechButtonVariant.primary,
    this.loading = false,
    this.expand = true,
    this.compact = false,
  });

  const TechButton.secondary({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.expand = true,
    this.compact = false,
  }) : variant = TechButtonVariant.secondary;

  const TechButton.text({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.expand = false,
    this.compact = true,
  }) : variant = TechButtonVariant.text;

  const TechButton.destructive({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.expand = true,
    this.compact = false,
  }) : variant = TechButtonVariant.destructive;

  @override
  Widget build(BuildContext context) {
    final height = compact ? TechSize.buttonHeightCompact : TechSize.buttonHeight;
    final tap = loading ? null : onPressed;
    final fg = switch (variant) {
      TechButtonVariant.primary || TechButtonVariant.destructive => Colors.white,
      TechButtonVariant.secondary || TechButtonVariant.text => TechColors.brand,
    };

    final Widget child = loading
        ? SizedBox(
            width: 20, height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: onPressed == null ? TechColors.textHint : fg,
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis, maxLines: 1)),
            ],
          );

    const shape = RoundedRectangleBorder(borderRadius: TechRadius.mdAll);
    final textStyle = compact
        ? TechText.button.copyWith(fontSize: 13)
        : TechText.button;
    final size = Size(expand ? double.infinity : 64, height);

    final Widget button = switch (variant) {
      TechButtonVariant.primary => FilledButton(
          onPressed: tap,
          style: FilledButton.styleFrom(
            backgroundColor: TechColors.brand,
            foregroundColor: Colors.white,
            disabledBackgroundColor: loading ? TechColors.brand : TechColors.border,
            disabledForegroundColor: loading ? Colors.white : TechColors.textHint,
            minimumSize: size, shape: shape, textStyle: textStyle,
          ),
          child: child,
        ),
      TechButtonVariant.destructive => FilledButton(
          onPressed: tap,
          style: FilledButton.styleFrom(
            backgroundColor: TechColors.error,
            foregroundColor: Colors.white,
            disabledBackgroundColor: loading ? TechColors.error : TechColors.border,
            disabledForegroundColor: loading ? Colors.white : TechColors.textHint,
            minimumSize: size, shape: shape, textStyle: textStyle,
          ),
          child: child,
        ),
      TechButtonVariant.secondary => OutlinedButton(
          onPressed: tap,
          style: OutlinedButton.styleFrom(
            foregroundColor: TechColors.brand,
            side: BorderSide(
                color: tap == null && !loading ? TechColors.border : TechColors.brand, width: 1.2),
            minimumSize: size, shape: shape,
            textStyle: textStyle.copyWith(fontWeight: FontWeight.w600),
          ),
          child: child,
        ),
      TechButtonVariant.text => TextButton(
          onPressed: tap,
          style: TextButton.styleFrom(
            foregroundColor: TechColors.brand,
            minimumSize: size, shape: shape,
            textStyle: textStyle.copyWith(fontWeight: FontWeight.w600),
          ),
          child: child,
        ),
    };

    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}
