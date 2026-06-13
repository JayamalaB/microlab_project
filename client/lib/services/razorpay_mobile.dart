import 'package:razorpay_flutter/razorpay_flutter.dart';

Razorpay? _instance;
void Function(String)? _onSuccess;
void Function(String)? _onError;

void openRazorpay({
  required Map<String, dynamic> options,
  required void Function(String paymentId) onSuccess,
  required void Function(String message) onError,
}) {
  _onSuccess = onSuccess;
  _onError = onError;

  _instance ??= Razorpay();
  _instance!.on(Razorpay.EVENT_PAYMENT_SUCCESS, (PaymentSuccessResponse r) {
    _onSuccess?.call(r.paymentId ?? 'razorpay');
  });
  _instance!.on(Razorpay.EVENT_PAYMENT_ERROR, (PaymentFailureResponse r) {
    _onError?.call(r.message ?? 'Payment failed');
  });
  _instance!.on(Razorpay.EVENT_EXTERNAL_WALLET, (ExternalWalletResponse r) {
    // External wallet selected — treat as pending
    _onSuccess?.call('wallet:${r.walletName}');
  });

  _instance!.open(options);
}

void clearRazorpay() {
  _instance?.clear();
  _instance = null;
  _onSuccess = null;
  _onError = null;
}
