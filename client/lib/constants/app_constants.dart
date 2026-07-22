class AppConstants {
  static const String serverUrl    = 'https://microlab.neuralarc.com';   // Node.js — booking, socket, OTP
  static const String phpServerUrl = 'https://jayamala.neuralarc.com'; // PHP — user registry
  static const String socketUrl    = serverUrl;
  static const String googleMapsApiKey = 'AIzaSyBIGPfna9mxSXpAJOhp0xigKhyZeeU0L0I';

  // How often the technician pings location while on an active job
  static const int locationPingSeconds = 5;

  // How often the technician pings while idle (logged in but no active job)
  static const int idlePingSeconds = 30;

  // Seconds each booking request alarm stays on screen before timing out
  static const int bookingRequestTimeoutSeconds = 40;

  // Max time to wait for a technician before showing "not found" to customer
  static const int bookingSearchTimeoutSeconds = 400;
}
