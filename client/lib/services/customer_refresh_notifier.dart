import 'package:flutter/foundation.dart';

enum CustomerRefreshEvent {
  bookingStatusChanged,
  reportReady,
}

/// In-process event bus for customer-side FCM notifications.
/// NotificationService fires events here; customer screens listen
/// and reload their data when relevant events arrive.
class CustomerRefreshNotifier extends ChangeNotifier {
  CustomerRefreshNotifier._();
  static final CustomerRefreshNotifier instance = CustomerRefreshNotifier._();

  CustomerRefreshEvent? _lastEvent;
  CustomerRefreshEvent? get lastEvent => _lastEvent;

  void fire(CustomerRefreshEvent event) {
    _lastEvent = event;
    notifyListeners();
  }
}
