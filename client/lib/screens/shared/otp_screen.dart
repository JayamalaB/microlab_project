import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/auth_service.dart';
import 'package:microlab/services/socket_service.dart';
import '../customer/customer_home_screen.dart';
import '../technician/technician_dashboard_screen.dart';

class OtpScreen extends StatefulWidget {
  final String mobile;
  final String userRole;
  final String? devOtp; // dev only — remove before production
  final String? technicianName;
  final String? technicianPhoto;
  final String? technicianSpecialization;

  const OtpScreen({
    super.key,
    required this.mobile,
    required this.userRole,
    this.devOtp,
    this.technicianName,
    this.technicianPhoto,
    this.technicianSpecialization,
  });

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  // 4 individual controllers + focus nodes
  final List<TextEditingController> _controllers =
      List.generate(4, (_) => TextEditingController());
  final List<FocusNode> _focusNodes = List.generate(4, (_) => FocusNode());

  bool _isVerifying = false;
  bool _isAutoFilled = false;
  bool _hasError = false;
  String _errorMsg = '';

  // Countdown
  int _secondsLeft = 60;
  Timer? _timer;
  bool _canResend = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
    _listenForAutoFill();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusScope.of(context).requestFocus(_focusNodes[0]);
    });
  }

  void _startTimer() {
    _secondsLeft = 60;
    _canResend = false;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() {
        if (_secondsLeft > 0) {
          _secondsLeft--;
        } else {
          _canResend = true;
          t.cancel();
        }
      });
    });
  }

  void _listenForAutoFill() {
    // Reserved for real SMS autofill integration (e.g. sms_autofill package)
  }

  void _fillOtp(String otp) {
    if (otp.length != 4) return;
    setState(() => _isAutoFilled = true);
    for (int i = 0; i < 4; i++) {
      _controllers[i].text = otp[i];
    }
    // Move focus away
    FocusScope.of(context).unfocus();
  }

  String get _currentOtp =>
      _controllers.map((c) => c.text).join();

  bool get _isComplete => _currentOtp.length == 4;

  void _onDigitChanged(String value, int index) {
    setState(() {
      _hasError = false;
      _isAutoFilled = false;
    });

    if (value.length == 1 && index < 3) {
      FocusScope.of(context).requestFocus(_focusNodes[index + 1]);
    }

    // Paste: if user pastes full OTP into first box
    if (value.length == 4 && index == 0) {
      _fillOtp(value);
      return;
    }

    setState(() {});
  }

  void _onBackspace(int index) {
    if (_controllers[index].text.isEmpty && index > 0) {
      _controllers[index - 1].clear();
      FocusScope.of(context).requestFocus(_focusNodes[index - 1]);
    }
    setState(() {});
  }

  Future<void> _verify() async {
    if (!_isComplete) return;
    FocusScope.of(context).unfocus();
    setState(() { _isVerifying = true; _hasError = false; });

    final result = await AuthService.verifyOtp(
      widget.mobile, _currentOtp, widget.userRole,
    );

    if (!mounted) return;

    if (result['success'] != true) {
      final msg = result['message'] as String? ?? 'Incorrect OTP. Please try again.';
      setState(() {
        _isVerifying = false;
        _hasError    = true;
        _errorMsg    = msg;
        for (final c in _controllers) c.clear();
      });
      FocusScope.of(context).requestFocus(_focusNodes[0]);
      return;
    }

    setState(() => _isVerifying = false);

    final data = result['data'] as Map<String, dynamic>? ?? {};
    final user = data['user']  as Map<String, dynamic>? ?? {};

    if (widget.userRole == 'technician') {
      final techId   = user['technician_id'] as int? ?? 0;
      final branchId = user['branch_id']     as int? ?? 0;
      final name     = user['user_name']     as String? ?? widget.mobile;
      _connectSocket(techId, branchId, name);
      _navigateTechnician();
    } else {
      final patientId = user['patient_id'] as int? ?? 0;
      final name      = user['patient_name'] as String? ?? widget.mobile;
      _connectSocket(patientId, null, name);
      _navigateCustomer();
    }
  }

  void _connectSocket(int userId, int? branchId, String name) {
    SocketService.instance.connect(
      userId:   userId,
      role:     widget.userRole == 'technician' ? 'technician' : 'customer',
      name:     name,
      branchId: branchId,
    );
  }

  void _navigateCustomer() {
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (_) => CustomerHomeScreen(
          mobile: widget.mobile,
          isVip:  widget.userRole == 'vip_customer',
        ),
      ),
      (route) => false,
    );
  }

  void _navigateTechnician() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.check_circle_outline, color: Colors.white, size: 18),
            SizedBox(width: 8),
            Text('OTP verified! Logging you in…'),
          ],
        ),
        backgroundColor: AppColors.brandGreen,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
    Navigator.pushAndRemoveUntil(
      context,
      PageRouteBuilder(
        pageBuilder:        (_, __, ___) => TechnicianDashboardScreen(mobile: widget.mobile),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
      (route) => false,
    );
  }

  Future<void> _resend() async {
    if (!_canResend) return;
    for (final c in _controllers) c.clear();
    setState(() { _hasError = false; _isAutoFilled = false; });
    FocusScope.of(context).requestFocus(_focusNodes[0]);
    _startTimer();

    final result = await AuthService.sendOtp(widget.mobile, widget.userRole);
    if (!mounted) return;

    final msg = result['success'] == true
        ? 'OTP resent to +91 ${widget.mobile}'
        : (result['message'] as String? ?? 'Failed to resend OTP');

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: result['success'] == true
            ? AppColors.brandGreen
            : const Color(0xFFD32F2F),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in _controllers) c.dispose();
    for (final f in _focusNodes) f.dispose();
    super.dispose();
  }

  String get _maskedMobile =>
      '+91 ${widget.mobile.substring(0, 5)} ${widget.mobile.substring(5)}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.white,
      body: SafeArea(
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 16),

                // Back button
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.divider),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.arrow_back_ios_new_rounded,
                        size: 16, color: AppColors.textSecondary),
                  ),
                ),

                const SizedBox(height: 28),

                // Logo
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppColors.brandGreen,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.water_drop_outlined,
                          color: Colors.white, size: 18),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'MicroLab',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 32),

                // Technician info card (shown only for technician role)
                if (widget.userRole == 'technician' && widget.technicianName != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 24),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      color: AppColors.brandGreenSurface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.brandGreenLight),
                    ),
                    child: Row(
                      children: [
                        // Avatar / photo
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: AppColors.brandGreen.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                          child: ClipOval(
                            child: (widget.technicianPhoto != null && widget.technicianPhoto!.isNotEmpty)
                                ? Image.network(
                                    widget.technicianPhoto!,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => const Icon(
                                        Icons.person_rounded,
                                        color: AppColors.brandGreen, size: 28),
                                  )
                                : const Icon(Icons.person_rounded,
                                    color: AppColors.brandGreen, size: 28),
                          ),
                        ),
                        const SizedBox(width: 14),
                        // Name + role
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.technicianName!,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              if (widget.technicianSpecialization != null &&
                                  widget.technicianSpecialization!.isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Text(
                                  widget.technicianSpecialization!,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.brandGreen,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 3),
                              const Text(
                                'Technician account verified',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.verified_rounded,
                            color: AppColors.brandGreen, size: 20),
                      ],
                    ),
                  ),

                const Text(
                  'Verify OTP',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                    letterSpacing: -0.3,
                  ),
                ),

                const SizedBox(height: 8),

                Text(
                  'Enter the 4-digit code sent to',
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppColors.textSecondary,
                  ),
                ),

                const SizedBox(height: 6),

                // Mobile display with change
                Row(
                  children: [
                    Text(
                      _maskedMobile,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: const Text(
                        'Change',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppColors.brandGreen,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 32),

                // ── Dev OTP banner (remove before production) ─────────
                if (widget.devOtp != null)
                  GestureDetector(
                    onTap: () => _fillOtp(widget.devOtp!),
                    child: Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF8E1),
                        border: Border.all(color: const Color(0xFFFFB300)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.developer_mode_rounded,
                              size: 15, color: Color(0xFFE65100)),
                          const SizedBox(width: 8),
                          Text(
                            'DEV — OTP: ${widget.devOtp}  (tap to fill)',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFFE65100),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Autofill banner
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _isAutoFilled
                      ? Container(
                          key: const ValueKey('autofill'),
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppColors.brandGreenSurface,
                            border: Border.all(color: AppColors.brandGreenLight),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.sms_outlined,
                                  size: 16, color: AppColors.brandGreen),
                              SizedBox(width: 8),
                              Text(
                                'OTP auto-filled from SMS',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.brandGreen,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(key: ValueKey('no-autofill')),
                ),

                // OTP boxes
                Row(
                  children: List.generate(4, (i) => Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: i < 3 ? 10 : 0),
                      child: _OtpBox(
                        controller: _controllers[i],
                        focusNode: _focusNodes[i],
                        isAutoFilled: _isAutoFilled,
                        hasError: _hasError,
                        onChanged: (v) => _onDigitChanged(v, i),
                        onBackspace: () => _onBackspace(i),
                      ),
                    ),
                  )),
                ),

                const SizedBox(height: 8),

                // Error message
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _hasError
                      ? Padding(
                          key: const ValueKey('err'),
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline,
                                  size: 13, color: Color(0xFFD32F2F)),
                              const SizedBox(width: 4),
                              Text(
                                _errorMsg,
                                style: const TextStyle(
                                    fontSize: 12, color: Color(0xFFD32F2F)),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(key: ValueKey('no-err')),
                ),

                const SizedBox(height: 20),

                // Resend row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _canResend
                          ? "Didn't receive it?"
                          : 'Resend OTP in',
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    _canResend
                        ? GestureDetector(
                            onTap: _resend,
                            child: const Text(
                              'Resend OTP',
                              style: TextStyle(
                                fontSize: 13,
                                color: AppColors.brandGreen,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          )
                        : Text(
                            '00:${_secondsLeft.toString().padLeft(2, '0')}',
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.brandGreen,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ],
                ),

                const SizedBox(height: 28),

                // Verify button
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed:
                        _isComplete && !_isVerifying ? _verify : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.brandGreen,
                      disabledBackgroundColor:
                          AppColors.brandGreen.withOpacity(0.35),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _isVerifying
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Text(
                            'Verify OTP',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                  ),
                ),

                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Individual OTP box ───────────────────────────────────────────────────────

class _OtpBox extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isAutoFilled;
  final bool hasError;
  final ValueChanged<String> onChanged;
  final VoidCallback onBackspace;

  const _OtpBox({
    required this.controller,
    required this.focusNode,
    required this.isAutoFilled,
    required this.hasError,
    required this.onChanged,
    required this.onBackspace,
  });

  @override
  State<_OtpBox> createState() => _OtpBoxState();
}

class _OtpBoxState extends State<_OtpBox> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(() => setState(() {}));
    widget.controller.addListener(() => setState(() {}));
  }

  Color get _borderColor {
    if (widget.hasError) return const Color(0xFFD32F2F);
    if (widget.isAutoFilled && widget.controller.text.isNotEmpty) {
      return AppColors.brandGreen;
    }
    if (widget.focusNode.hasFocus) return AppColors.brandGreen;
    if (widget.controller.text.isNotEmpty) return AppColors.brandGreen;
    return AppColors.divider;
  }

  Color get _bgColor {
    if (widget.hasError) return const Color(0xFFFFF5F5);
    if (widget.isAutoFilled && widget.controller.text.isNotEmpty) {
      return AppColors.brandGreenSurface;
    }
    return AppColors.white;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: double.infinity,
      height: 64,
      decoration: BoxDecoration(
        color: _bgColor,
        border: Border.all(
          color: _borderColor,
          width: widget.focusNode.hasFocus ? 2 : 1.5,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: RawKeyboardListener(
        focusNode: FocusNode(),
        onKey: (event) {
          if (event is RawKeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.backspace) {
            widget.onBackspace();
          }
        },
        child: TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          maxLength: 1,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: widget.hasError
                ? const Color(0xFFD32F2F)
                : widget.isAutoFilled
                    ? AppColors.brandGreen
                    : AppColors.textPrimary,
          ),
          decoration: const InputDecoration(
            border: InputBorder.none,
            counterText: '',
            contentPadding: EdgeInsets.zero,
          ),
          onChanged: widget.onChanged,
        ),
      ),
    );
  }
}
