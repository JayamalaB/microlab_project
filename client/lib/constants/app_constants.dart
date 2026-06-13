class AppConstants {
  // TODO: Replace with your deployed server URL
  // Local dev example:  'http://192.168.1.10:5000'
  // Production example: 'https://api.yourdomain.com'
  static const String serverUrl = 'http://192.168.1.10:5000';
  static const String socketUrl = serverUrl;

  // How often the technician pings location while on an active job
  static const int locationPingSeconds = 5;

  // How often the technician pings while idle (logged in but no active job)
  static const int idlePingSeconds = 30;

  // Seconds each booking request alarm stays on screen before timing out
  static const int bookingRequestTimeoutSeconds = 40;

  // Max time to wait for a technician before showing "not found" to customer
  static const int bookingSearchTimeoutSeconds = 400;
}
