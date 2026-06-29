import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:microlab/services/auth_service.dart';
import 'package:microlab/theme/app_theme.dart';
import 'otp_screen.dart';

/// This widget is embedded directly inside [OnboardingScreen] as the bottom
/// 65% panel. It no longer needs a [userRole] constructor argument — the role
/// is selected inline via the two role cards.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _mobileController = TextEditingController();
  final FocusNode _mobileFocus = FocusNode();

  String _selectedRole = 'customer';
  bool _isValid = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _mobileController.addListener(_validate);
    _mobileFocus.addListener(() => setState(() {}));
  }

  void _validate() {
    final val = _mobileController.text.trim();
    setState(() {
      _isValid = val.length == 10 && RegExp(r'^[6-9]\d{9}$').hasMatch(val);
    });
  }

  Future<void> _sendOtp() async {
    if (!_isValid) return;
    setState(() => _isLoading = true);
    FocusScope.of(context).unfocus();

    final mobile = _mobileController.text.trim();
    final result = await AuthService.sendOtp(mobile, _selectedRole);

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result['success'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['message'] as String? ?? 'Failed to send OTP'),
          backgroundColor: const Color(0xFFD32F2F),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      return;
    }

    // Extract dev OTP from response (remove before production)
    final data   = result['data'] as Map<String, dynamic>? ?? {};
    final devOtp = data['otp'] as String?;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OtpScreen(
          mobile:   mobile,
          userRole: _selectedRole,
          devOtp:   devOtp,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _mobileController.dispose();
    _mobileFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipPath(
      clipper: _UCurveClipper(),
      child: Container(
        color: AppColors.white,
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 66, 22, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                // Title
                Text(
                  _selectedRole == 'customer'
                      ? 'Enter mobile number'
                      : 'Technician login',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _selectedRole == 'customer'
                      ? "We'll send a 4-digit OTP to verify your number"
                      : 'Enter your registered technician mobile number',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 18),

                // ── Role cards ────────────────────────────────────────
                Row(
                  children: [
                    Expanded(
                      child: _RoleCard(
                        label: 'Customer',
                        description: 'Book lab tests',
                        icon: Icons.person_outline_rounded,
                        selected: _selectedRole == 'customer',
                        onTap: () =>
                            setState(() => _selectedRole = 'customer'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _RoleCard(
                        label: 'Technician',
                        description: 'Manage jobs',
                        icon: Icons.medical_services_outlined,
                        selected: _selectedRole == 'technician',
                        onTap: () =>
                            setState(() => _selectedRole = 'technician'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),

                // ── Mobile number field ───────────────────────────────
                const Text(
                  'Mobile number',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 6),

                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _mobileFocus.hasFocus
                          ? AppColors.brandGreen
                          : AppColors.divider,
                      width: _mobileFocus.hasFocus ? 1.5 : 1,
                    ),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Row(
                    children: [
                      // Country code prefix
                      Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 12),
                        height: 46,
                        decoration: const BoxDecoration(
                          color: AppColors.background,
                          border: Border(
                            right: BorderSide(color: AppColors.divider),
                          ),
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(13),
                            bottomLeft: Radius.circular(13),
                          ),
                        ),
                        child: const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('🇮🇳',
                                style: TextStyle(fontSize: 15)),
                            Text(
                              '+91',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Number input
                      Expanded(
                        child: TextField(
                          controller: _mobileController,
                          focusNode: _mobileFocus,
                          keyboardType: TextInputType.phone,
                          maxLength: 10,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textPrimary,
                            letterSpacing: 1.0,
                          ),
                          decoration: const InputDecoration(
                            hintText: '98765 43210',
                            hintStyle: TextStyle(
                              color: AppColors.textHint,
                              letterSpacing: 0.3,
                              fontWeight: FontWeight.w400,
                              fontSize: 13,
                            ),
                            border: InputBorder.none,
                            contentPadding:
                                EdgeInsets.symmetric(horizontal: 10),
                            counterText: '',
                          ),
                          onSubmitted: (_) => _sendOtp(),
                        ),
                      ),

                      // Tick / clear icon
                      if (_mobileController.text.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: _isValid
                              ? const Icon(
                                  Icons.check_circle_outline,
                                  color: AppColors.brandGreen,
                                  size: 18)
                              : GestureDetector(
                                  onTap: () =>
                                      _mobileController.clear(),
                                  child: const Icon(
                                      Icons.cancel_outlined,
                                      color: AppColors.textHint,
                                      size: 18),
                                ),
                        ),
                    ],
                  ),
                ),

                // Validation error
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _mobileController.text.isNotEmpty && !_isValid
                      ? const Padding(
                          key: ValueKey('err'),
                          padding: EdgeInsets.only(top: 5),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline,
                                  size: 11,
                                  color: Color(0xFFD32F2F)),
                              SizedBox(width: 4),
                              Text(
                                'Enter a valid 10-digit mobile number',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFFD32F2F)),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(key: ValueKey('ok')),
                ),

                const SizedBox(height: 16),

                // ── Send OTP button ───────────────────────────────────
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed:
                        _isValid && !_isLoading ? _sendOtp : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brandGreen,
                      disabledBackgroundColor:
                          AppColors.brandGreen.withOpacity(0.32),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(13),
                      ),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white),
                            ),
                          )
                        : const Text(
                            'Send OTP',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                  ),
                ),

                    ],
                  ),
                ),
              ),

              // T&C pinned to bottom
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 32),
                child: Center(
                  child: RichText(
                    textAlign: TextAlign.center,
                    text: const TextSpan(
                      style: TextStyle(
                          fontSize: 10,
                          color: AppColors.textSecondary),
                      children: [
                        TextSpan(text: 'By signing in, you accept our '),
                        TextSpan(
                          text: 'T&Cs',
                          style: TextStyle(
                              color: AppColors.brandGreen,
                              fontWeight: FontWeight.w500),
                        ),
                        TextSpan(text: ' and '),
                        TextSpan(
                          text: 'Privacy Policy',
                          style: TextStyle(
                              color: AppColors.brandGreen,
                              fontWeight: FontWeight.w500),
                        ),
                      ],
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
// U-curve clip — full-width concave arc at the top of the white login panel
// ─────────────────────────────────────────────────────────────────────────────

class _UCurveClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    const depth = 52.0; // how far the center dips below y=0

    return Path()
      // Start top-left corner (y=0)
      ..moveTo(0, 0)
      // Left side stays flat, then curves down to the center
      ..cubicTo(
        size.width * 0.30, 0,
        size.width * 0.30, depth,
        size.width * 0.50, depth,
      )
      // Center rises back up to top-right corner (y=0)
      ..cubicTo(
        size.width * 0.70, depth,
        size.width * 0.70, 0,
        size.width, 0,
      )
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> old) => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Role card
// ─────────────────────────────────────────────────────────────────────────────

class _RoleCard extends StatelessWidget {
  final String label;
  final String description;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _RoleCard({
    required this.label,
    required this.description,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.brandGreenSurface
              : const Color(0xFFFAFAFA),
          border: Border.all(
            color:
                selected ? AppColors.brandGreen : AppColors.divider,
            width: selected ? 1.5 : 1.0,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: selected
                    ? AppColors.brandGreen
                    : AppColors.brandGreenLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                size: 17,
                color:
                    selected ? Colors.white : AppColors.brandGreen,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected
                    ? AppColors.brandGreen
                    : AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              description,
              style: TextStyle(
                fontSize: 10,
                color: selected
                    ? AppColors.brandGreen.withOpacity(0.7)
                    : AppColors.textHint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}