import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:microlab/theme/app_theme.dart';
import 'package:microlab/services/socket_service.dart';
import '../customer/customer_home_screen.dart';
import '../technician/technician_dashboard_screen.dart';

class OtpScreen extends StatefulWidget {
  final String mobile;
  final String userRole;

  const OtpScreen({super.key, required this.mobile, required this.userRole});

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> with CodeAutoFill {
  final List<TextEditingController> _controllers =
      List.generate(4, (_) => TextEditingController());
  final List<FocusNode> _focusNodes = List.generate(4, (_) => FocusNode());

  bool _isVerifying = false;
  bool _isAutoFilled = false;
  bool _hasError = false;
  String _errorMsg = '';

  int _secondsLeft = 60;
  Timer? _timer;
  bool _canResend = false;

  @override
  void initState() {
    super.initState();
    _startTimer();
    listenForCode();
    _printAppHash();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusScope.of(context).requestFocus(_focusNodes[0]);
    });
  }

  Future<void> _printAppHash() async {
    final hash = await SmsAutoFill().getAppSignature;
    // ignore: avoid_print
    print('APP HASH FOR SMS: [$hash]');
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

  @override
  void codeUpdated() {
    if (code != null && code!.length == 4) {
      _fillOtp(code!);
    }
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
    setState(() {
      _isVerifying = true;
      _hasError = false;
    });

    try {
      final result = await ApiService.verifyOtp(widget.mobile, _currentOtp);
      if (!mounted) return;
      if (result['success'] == true) {
        final token = result['data']?['token'];
        if (token != null) await ApiService.saveToken(token);
        await ApiService.saveUserInfo(widget.mobile, widget.userRole);
        setState(() => _isVerifying = false);
        const technicianIds = {'8056535850': 1, '7339535472': 2};
        final int userId = widget.userRole == 'technician'
            ? (technicianIds[widget.mobile] ?? 1)
            : 1;
        _connectSocket(userId);
        _showSuccess();
      } else {
        setState(() {
          _isVerifying = false;
          _hasError = true;
          _errorMsg = result['message'] ?? 'Incorrect OTP. Please try again.';
          for (final c in _controllers) {
            c.clear();
          }
        });
        FocusScope.of(context).requestFocus(_focusNodes[0]);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isVerifying = false;
        _hasError = true;
        _errorMsg = 'Network error. Please try again.';
      });
      FocusScope.of(context).requestFocus(_focusNodes[0]);
    }
  }

  void _connectSocket(int userId) {
    SocketService.instance.connect(
      userId: userId,
      role:   widget.userRole == 'technician' ? 'technician' : 'customer',
      name:   widget.mobile, // TODO: replace with real name from API
    );
  }

  void _showSuccess() {
    if (widget.userRole == 'customer') {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => CustomerHomeScreen(
            mobile: widget.mobile,
            isVip: false,
          ),
        ),
        (route) => false,
      );
      return;
    }
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

    if (widget.userRole == 'technician') {
      Navigator.pushAndRemoveUntil(
        context,
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => TechnicianDashboardScreen(mobile: widget.mobile),
          transitionsBuilder: (_, anim, __, child) => FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 400),
        ),
        (route) => false,
      );
      return;
    }
  }

  Future<void> _resend() async {
    if (!_canResend) return;
    for (final c in _controllers) {
      c.clear();
    }
    setState(() {
      _hasError = false;
      _isAutoFilled = false;
    });
    FocusScope.of(context).requestFocus(_focusNodes[0]);
    _startTimer();

    try {
      await ApiService.sendOtp(widget.mobile, widget.userRole);
    } catch (_) {}

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('OTP resent to +91 ${widget.mobile}'),
        backgroundColor: AppColors.brandGreen,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  void dispose() {
    cancel();
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
