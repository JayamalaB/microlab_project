import 'dart:async';
import 'package:flutter/material.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';
import 'package:microlab/theme/app_theme.dart';
import 'login_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  Timer? _autoSlideTimer;

  final List<_OnboardData> _pages = const [
    _OnboardData(
      title: 'Book a blood test\nfrom home',
      subtitle:
          'Schedule your test in minutes. Choose your preferred time slot and a certified technician visits you.',
      bgColor: Color(0xFFE8F5F1),
      illustrationId: 0,
    ),
    _OnboardData(
      title: 'Verified technicians\nat your door',
      subtitle:
          'All technicians are certified, background-checked, and rated by other customers for your safety.',
      bgColor: Color(0xFFEEF4FB),
      illustrationId: 1,
    ),
    _OnboardData(
      title: 'Fast results,\nright to you',
      subtitle:
          'Receive your lab reports digitally within hours, reviewed by certified professionals.',
      bgColor: Color(0xFFFEF6EE),
      illustrationId: 2,
    ),
  ];

  Color get _currentBg => _pages[_currentPage].bgColor;

  @override
  void initState() {
    super.initState();
    _autoSlideTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      final next = (_currentPage + 1) % _pages.length;
      _pageController.animateToPage(
        next,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void dispose() {
    _autoSlideTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.of(context).size.height;
    final onboardH = screenH * 0.35;
    final keyboardH = MediaQuery.of(context).viewInsets.bottom;
    final keyboardOpen = keyboardH > 0;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        bottom: false,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          color: _currentBg,
          child: Stack(
            children: [
              // ── Onboarding slides — slide off-screen upward when keyboard opens
              AnimatedPositioned(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeInOut,
                top: keyboardOpen ? -onboardH : 0,
                left: 0, right: 0,
                height: onboardH,
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: _pages.length,
                  onPageChanged: (i) => setState(() => _currentPage = i),
                  itemBuilder: (_, i) => _OnboardPage(data: _pages[i]),
                ),
              ),

              // ── Login panel — expands to fill screen when keyboard opens
              AnimatedPositioned(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeInOut,
                top: keyboardOpen ? 0 : onboardH,
                left: 0, right: 0,
                bottom: keyboardH,
                child: const LoginScreen(),
              ),

              // ── Dots — fade out when keyboard opens
              AnimatedPositioned(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeInOut,
                top: keyboardOpen ? -20 : onboardH - 10,
                left: 0, right: 0,
                child: AnimatedOpacity(
                  opacity: keyboardOpen ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 150),
                  child: Center(
                    child: SmoothPageIndicator(
                      controller: _pageController,
                      count: _pages.length,
                      effect: const ExpandingDotsEffect(
                        dotHeight: 6,
                        dotWidth: 6,
                        expansionFactor: 3,
                        spacing: 5,
                        activeDotColor: AppColors.brandGreen,
                        dotColor: Color(0x442A9D5C),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Data model
// ─────────────────────────────────────────────────────────────────────────────

class _OnboardData {
  final String title;
  final String subtitle;
  final Color bgColor;
  final int illustrationId;

  const _OnboardData({
    required this.title,
    required this.subtitle,
    required this.bgColor,
    required this.illustrationId,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Single onboarding page
// ─────────────────────────────────────────────────────────────────────────────

class _OnboardPage extends StatelessWidget {
  final _OnboardData data;
  const _OnboardPage({required this.data});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Center(
            child: CustomPaint(
              size: const Size(160, 100),
              painter: _IllustrationPainter(id: data.illustrationId),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            data.title,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
              height: 1.25,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Illustrations
// ─────────────────────────────────────────────────────────────────────────────

class _IllustrationPainter extends CustomPainter {
  final int id;
  const _IllustrationPainter({required this.id});

  @override
  void paint(Canvas canvas, Size size) {
    switch (id) {
      case 0:
        _drawBooking(canvas, size);
        break;
      case 1:
        _drawTechnician(canvas, size);
        break;
      case 2:
        _drawResults(canvas, size);
        break;
    }
  }

  void _drawBooking(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - 45, cy - 44, 85, 88),
          const Radius.circular(12)),
      Paint()
        ..color = AppColors.brandGreen.withOpacity(0.10)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - 45, cy - 44, 85, 88),
          const Radius.circular(12)),
      Paint()
        ..color = AppColors.brandGreen.withOpacity(0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final lp = Paint()
      ..color = AppColors.brandGreen.withOpacity(0.25)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (int i = 0; i < 3; i++) {
      canvas.drawLine(Offset(cx - 28, cy - 4 + i * 13.0),
          Offset(cx + 18, cy - 4 + i * 13.0), lp);
    }
    canvas.drawCircle(
      Offset(cx + 38, cy - 36),
      15,
      Paint()
        ..color = AppColors.brandGreen
        ..style = PaintingStyle.fill,
    );
    final pp = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(cx + 38, cy - 45), Offset(cx + 38, cy - 27), pp);
    canvas.drawLine(Offset(cx + 29, cy - 36), Offset(cx + 47, cy - 36), pp);
    canvas.drawCircle(
      Offset(cx - 38, cy + 40),
      12,
      Paint()
        ..color = AppColors.brandGreenLight
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(cx - 38, cy + 40),
      12,
      Paint()
        ..color = AppColors.brandGreen
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3,
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx - 45, cy + 40)
        ..lineTo(cx - 40, cy + 46)
        ..lineTo(cx - 31, cy + 33),
      Paint()
        ..color = AppColors.brandGreen
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  void _drawTechnician(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    canvas.drawCircle(
      Offset(cx, cy),
      48,
      Paint()
        ..color = const Color(0xFF1565C0).withOpacity(0.08)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(cx, cy),
      48,
      Paint()
        ..color = const Color(0xFF1565C0).withOpacity(0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    final hp = Paint()
      ..color = const Color(0xFF1565C0).withOpacity(0.45)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy - 8), 16, hp);
    canvas.drawPath(
      Path()
        ..moveTo(cx - 24, cy + 34)
        ..quadraticBezierTo(cx, cy + 6, cx + 24, cy + 34)
        ..close(),
      hp,
    );
    canvas.drawCircle(
      Offset(cx + 40, cy - 32),
      13,
      Paint()
        ..color = AppColors.brandGreenLight
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(cx + 40, cy - 32),
      13,
      Paint()
        ..color = AppColors.brandGreen
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3,
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx + 33, cy - 32)
        ..lineTo(cx + 39, cy - 26)
        ..lineTo(cx + 48, cy - 42),
      Paint()
        ..color = AppColors.brandGreen
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  void _drawResults(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - 46, cy - 44, 92, 88),
          const Radius.circular(12)),
      Paint()
        ..color = AppColors.brandGreen.withOpacity(0.08)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - 46, cy - 44, 92, 88),
          const Radius.circular(12)),
      Paint()
        ..color = AppColors.brandGreen.withOpacity(0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3,
    );
    final bars = [0.5, 0.8, 0.6, 1.0, 0.7];
    const barW = 9.0;
    const gap = 5.0;
    final totalW = bars.length * barW + (bars.length - 1) * gap;
    var bx = cx - totalW / 2;
    for (final h in bars) {
      final barH = h * 38;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(bx, cy + 22 - barH, barW, barH),
            const Radius.circular(3)),
        Paint()
          ..color = AppColors.brandGreen.withOpacity(0.25 + h * 0.4)
          ..style = PaintingStyle.fill,
      );
      bx += barW + gap;
    }
    canvas.drawCircle(
      Offset(cx + 40, cy - 36),
      13,
      Paint()
        ..color = AppColors.brandGreenLight
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      Offset(cx + 40, cy - 36),
      13,
      Paint()
        ..color = AppColors.brandGreen
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3,
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx + 33, cy - 36)
        ..lineTo(cx + 39, cy - 30)
        ..lineTo(cx + 48, cy - 44),
      Paint()
        ..color = AppColors.brandGreen
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}