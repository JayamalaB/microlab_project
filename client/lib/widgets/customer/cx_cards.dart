import 'package:flutter/material.dart';
import 'package:microlab/theme/customer_theme.dart';
import 'package:microlab/widgets/customer/cx_dialog.dart';

/// White card with border and soft shadow; tappable when [onTap] is set.
class CxCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;
  final bool selected;
  final Color? color;

  const CxCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(CxSpace.lg),
    this.selected = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(
          borderRadius: CxRadius.lgAll,
          boxShadow: [BoxShadow(color: Color(0x0D000000), blurRadius: 10, offset: Offset(0, 2))],
        ),
        child: Material(
          color: color ?? (selected ? CxColors.brandSurface : Colors.white),
          shape: RoundedRectangleBorder(
            borderRadius: CxRadius.lgAll,
            side: BorderSide(
              color: selected ? CxColors.brand : CxColors.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(padding: padding, child: child),
          ),
        ),
      );
}

/// Card with a title row (tinted icon + title + optional trailing).
class CxSectionCard extends StatelessWidget {
  final String title;
  final IconData? icon;
  final Widget? trailing;
  final Widget child;

  const CxSectionCard({super.key, required this.title, this.icon, this.trailing, required this.child});

  @override
  Widget build(BuildContext context) => CxCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            if (icon != null) ...[CxIconBadge(icon: icon!, size: 34), const SizedBox(width: CxSpace.md)],
            Expanded(child: Text(title, style: CxText.sectionTitle)),
            if (trailing != null) trailing!,
          ]),
          const SizedBox(height: CxSpace.lg),
          child,
        ]),
      );
}

/// Tappable choice: tinted icon, title, description, chevron (or check).
class CxOptionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool selected;
  final CxTone tone;
  final Widget? trailing;

  const CxOptionCard({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.selected = false,
    this.tone = CxTone.brand,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected ? tone.surface : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: CxRadius.lgAll,
            side: BorderSide(color: selected ? tone.color : CxColors.border, width: selected ? 1.5 : 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(CxSpace.lg),
              child: Row(children: [
                CxIconBadge(icon: icon, tone: tone),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: CxText.cardTitle),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!, style: CxText.bodySecondary),
                    ],
                  ]),
                ),
                const SizedBox(width: CxSpace.sm),
                trailing ??
                    Icon(selected ? Icons.check_circle_rounded : Icons.chevron_right_rounded,
                        color: selected ? tone.color : CxColors.textHint),
              ]),
            ),
          ),
        ),
      );
}

/// Small pill: "Offer", "Home collection", "Paid".
class CxChip extends StatelessWidget {
  final String label;
  final CxTone tone;
  final IconData? icon;
  const CxChip({super.key, required this.label, this.tone = CxTone.neutral, this.icon});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: tone.surface, borderRadius: CxRadius.pill),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 14, color: tone.color), const SizedBox(width: 4)],
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: tone.color)),
          ),
        ]),
      );
}

/// Selectable filter pill (search filters, categories).
class CxFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;
  final Widget? trailing;

  const CxFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected ? CxColors.brand : Colors.white,
          shape: StadiumBorder(side: BorderSide(color: selected ? CxColors.brand : CxColors.border)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 38),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16, color: selected ? Colors.white : CxColors.textSecondary),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: selected ? Colors.white : CxColors.textPrimary,
                        )),
                  ),
                  if (trailing != null) ...[const SizedBox(width: 4), trailing!],
                ]),
              ),
            ),
          ),
        ),
      );
}

/// Price with optional struck-through original price.
class CxPrice extends StatelessWidget {
  final String price;
  final String? originalPrice;
  final double fontSize;
  const CxPrice({super.key, required this.price, this.originalPrice, this.fontSize = 16});

  @override
  Widget build(BuildContext context) => Wrap(
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 6,
        children: [
          Text(price,
              style: CxText.price.copyWith(fontSize: fontSize)),
          if (originalPrice != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 1),
              child: Text(originalPrice!,
                  style: TextStyle(
                    fontSize: fontSize - 3,
                    color: CxColors.textHint,
                    decoration: TextDecoration.lineThrough,
                  )),
            ),
        ],
      );
}

/// One row of a bill: label left, amount right.
class CxPriceRow extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasis;
  final Color? valueColor;
  const CxPriceRow({super.key, required this.label, required this.value, this.emphasis = false, this.valueColor});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(
            child: Text(label,
                style: emphasis ? CxText.cardTitle : CxText.bodySecondary),
          ),
          const SizedBox(width: CxSpace.sm),
          Text(value,
              style: (emphasis ? CxText.price : CxText.body.copyWith(fontWeight: FontWeight.w600))
                  .copyWith(color: valueColor)),
        ]),
      );
}
