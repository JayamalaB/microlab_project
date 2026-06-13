// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js;

void openRazorpay({
  required Map<String, dynamic> options,
  required void Function(String paymentId) onSuccess,
  required void Function(String message) onError,
}) {
  // Razorpay checkout.js must be included in web/index.html
  // <script src="https://checkout.razorpay.com/v1/checkout.js"></script>

  final jsOptions = js.JsObject.jsify({
    ...options,
    'handler': js.allowInterop((js.JsObject response) {
      final paymentId = response['razorpay_payment_id']?.toString() ?? 'razorpay';
      onSuccess(paymentId);
    }),
    'modal': {
      'ondismiss': js.allowInterop(() {
        onError('Payment cancelled');
      }),
    },
  });

  try {
    final rzp = js.JsObject(js.context['Razorpay'] as js.JsFunction, [jsOptions]);
    rzp.callMethod('open');
  } catch (e) {
    onError('Could not open Razorpay: $e');
  }
}

void clearRazorpay() {
  // Nothing to clear on web — JS handles its own lifecycle
}
