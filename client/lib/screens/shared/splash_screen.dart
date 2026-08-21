import 'package:flutter/material.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:microlab/services/socket_service.dart';
import 'onboarding_screen.dart';
import '../customer/customer_home_screen.dart';
import '../technician/technician_dashboard_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _logoController;
  late AnimationController _dotController;
  late Animation<double> _logoScale;
  late Animation<double> _logoFade;
  late Animation<double> _textFade;
  int _activeDot = 0;

  @override
  void initState() {
    super.initState();

    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _dotController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    _logoScale = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeOutBack),
    );

    _logoFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _logoController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeIn),
      ),
    );

    _textFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _logoController,
        curve: const Interval(0.4, 1.0, curve: Curves.easeIn),
      ),
    );

    _logoController.forward();

    // Animate loading dots
    _dotController.addListener(() {
      final progress = _dotController.value;
      setState(() {
        if (progress < 0.33) {
          _activeDot = 0;
        } else if (progress < 0.66) {
          _activeDot = 1;
        } else {
          _activeDot = 2;
        }
      });
    });

    _dotController.repeat();

    // Navigate after 2.5s — check saved session first
    Future.delayed(const Duration(milliseconds: 2500), _navigateAfterSplash);
  }

  Future<void> _navigateAfterSplash() async {
    if (!mounted) return;

    final prefs  = await SharedPreferences.getInstance();
    final token  = prefs.getString('auth_token') ?? '';
    final role   = prefs.getString('user_role')  ?? '';
    final mobile = prefs.getString('user_mobile') ?? '';

    if (!mounted) return;

    Widget destination;

    if (token.isNotEmpty && role.isNotEmpty && mobile.isNotEmpty) {
      final userId = prefs.getInt('user_id') ?? 0;
      final name   = prefs.getString('user_name') ?? mobile;

      if (role == 'technician') {
        final branchId = prefs.getInt('branch_id') ?? 0;
        SocketService.instance.connect(
          userId: userId, role: 'technician', name: name, branchId: branchId,
        );
        destination = TechnicianDashboardScreen(mobile: mobile);
      } else {
        SocketService.instance.connect(
          userId: userId, role: 'customer', name: name, branchId: null,
        );
        destination = CustomerHomeScreen(mobile: mobile, isVip: false);
      }
    } else {
      destination = const OnboardingScreen();
    }

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder:        (_, __, ___) => destination,
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  void dispose() {
    _logoController.dispose();
    _dotController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.brandGreen,
      body: SafeArea(
        child: Stack(
          children: [
            // Background subtle pattern
            Positioned.fill(
              child: CustomPaint(painter: _BgPatternPainter()),
            ),

            // Center content
            Center(
              child: AnimatedBuilder(
                animation: _logoController,
                builder: (_, __) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Logo box
                    FadeTransition(
                      opacity: _logoFade,
                      child: ScaleTransition(
                        scale: _logoScale,
                        child: Container(
                          width: 88,
                          height: 88,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.2),
                              width: 1,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: Image.asset(
                              'assets/icon/app_icon.png',
                              width: 88,
                              height: 88,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),

                    // App name
                    FadeTransition(
                      opacity: _textFade,
                      child: const Text(
                        'MicroLab',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ),

                    const SizedBox(height: 6),

                    FadeTransition(
                      opacity: _textFade,
                      child: Text(
                        'HOME BLOOD TESTING',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.55),
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 2.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Loading dots
            Positioned(
              bottom: 48,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(3, (i) {
                  final isActive = i == _activeDot;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: isActive ? 20 : 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: isActive
                          ? Colors.white.withOpacity(0.9)
                          : Colors.white.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Subtle circular pattern background
class _BgPatternPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.04)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (int i = 1; i <= 5; i++) {
      canvas.drawCircle(
        Offset(size.width / 2, size.height / 2),
        i * 80.0,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
