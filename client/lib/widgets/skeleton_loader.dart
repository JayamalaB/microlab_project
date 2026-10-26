import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Shared skeleton-loading building blocks.
//
// Use SkeletonShimmer to wrap a group of SkeletonBox placeholders shaped like
// the real content that's about to load (one shimmer animation per screen,
// not per box, so a long list doesn't spin up dozens of controllers). Meant
// for INITIAL content loading (a list/section appearing for the first time),
// not for small action-feedback spinners (submit buttons, refresh icons,
// image loadingBuilders) — those stay as plain CircularProgressIndicators.
// ─────────────────────────────────────────────────────────────────────────────

class SkeletonShimmer extends StatefulWidget {
  final Widget child;
  const SkeletonShimmer({super.key, required this.child});

  @override
  State<SkeletonShimmer> createState() => _SkeletonShimmerState();
}

class _SkeletonShimmerState extends State<SkeletonShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final dx = _controller.value * 3 - 1.5; // sweeps left → right, off-screen on both ends
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment(dx - 0.6, 0),
            end: Alignment(dx + 0.6, 0),
            colors: const [Color(0xFFE4E4E1), Color(0xFFF4F4F2), Color(0xFFE4E4E1)],
          ).createShader(bounds),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// A single flat placeholder block — a stand-in for a line of text, an
/// avatar, a badge, etc. Must sit inside a SkeletonShimmer to animate.
class SkeletonBox extends StatelessWidget {
  final double width;
  final double height;
  final BorderRadius borderRadius;
  const SkeletonBox({
    super.key,
    this.width = double.infinity,
    required this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(6)),
  });

  const SkeletonBox.circle({super.key, required double size})
      : width = size,
        height = size,
        borderRadius = const BorderRadius.all(Radius.circular(999));

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: const Color(0xFFE0E0DD), borderRadius: borderRadius),
    );
  }
}
