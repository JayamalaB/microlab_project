// Stub — replaced at compile time by web.dart or mobile.dart
void openRazorpay({
  required Map<String, dynamic> options,
  required void Function(String paymentId) onSuccess,
  required void Function(String message) onError,
}) {
  onError('Razorpay not supported on this platform');
}

void clearRazorpay() {}
