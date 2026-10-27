import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show GlobalKey, MaterialPageRoute, NavigatorState, ScaffoldMessenger, SnackBar, Text, WidgetsBinding;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:microlab/models.dart';
import 'package:microlab/constants/app_constants.dart';
import 'package:microlab/screens/shared/onboarding_screen.dart';

class ApiService {
  static const String baseUrl = AppConstants.serverUrl;

  // Global navigator key — wire into MaterialApp so _handle401 can navigate
  // without a BuildContext.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static final _client = _AuthClient();

  /// Use this for every authenticated HTTP call that lives outside ApiService
  /// (e.g., in screen files). Routes through the global 401 handler so a
  /// stale token redirects to login automatically.
  // ignore: library_private_types_in_public_api
  static http.Client get authClient => _client;

  static bool _redirecting401 = false;

  // Called by _AuthClient when any authenticated response comes back 401.
  // Clears stored credentials and pushes OnboardingScreen, replacing the
  // entire stack so the user cannot go back to a now-invalid screen.
  static void _handle401() {
    if (_redirecting401) return;
    _redirecting401 = true;
    clearToken(); // unawaited — fire-and-forget; navigation is the priority
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _redirecting401 = false;
      navigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const OnboardingScreen()),
        (_) => false,
      );
      final ctx = navigatorKey.currentContext;
      if (ctx != null) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(
            content: Text('Signed out — another device logged in with your number.'),
            duration: Duration(seconds: 5),
          ),
        );
      }
    });
  }

  /// Called by SocketService when the server pushes `force_logout` — same
  /// redirect as a 401, but triggered immediately via socket instead of waiting
  /// for the next HTTP call.
  static void handleForceLogout() => _handle401();

  // forceLogout: set only after the user has explicitly confirmed, in
  // response to "already logged in on another device", that they want to
  // release that other session and continue. Must also be passed to
  // whichever verify-otp call completes this same login attempt (see
  // AuthService.verifyOtp, which is what OtpScreen actually calls) — this
  // flag alone only gets the OTP sent, the real session claim happens there.
  static Future<Map<String, dynamic>> sendOtp(
    String mobile,
    String role, {
    bool forceLogout = false,
  }) async {
    final res = await http
        .post(
          Uri.parse('$baseUrl/api/auth/send-otp'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'mobile': mobile,
            'role': role,
            if (forceLogout) 'forceLogout': true,
          }),
        )
        .timeout(const Duration(seconds: 15));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> verifyOtp(String mobile, String otp) async {
    final res = await http
        .post(
          Uri.parse('$baseUrl/api/auth/verify-otp'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'mobile': mobile, 'otp': otp}),
        )
        .timeout(const Duration(seconds: 30));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<void> registerFcmToken(String fcmToken) async {
    try {
      final authToken = await getToken();
      if (authToken == null) return;
      await _client.post(
        Uri.parse('$baseUrl/api/auth/fcm-token'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $authToken',
        },
        body: jsonEncode({'token': fcmToken}),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  static Future<void> logout(String token) async {
    // Use plain http (not _client) so a 401 response here — which is normal
    // when the session was already invalidated — does not trigger the "another
    // device signed in" redirect.
    await http
        .post(
          Uri.parse('$baseUrl/api/auth/logout'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
        )
        .timeout(const Duration(seconds: 15));
  }

  static Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token', token);
  }

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('auth_token');
  }

  static Future<void> saveUserInfo(String mobile, String role) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_mobile', mobile);
    await prefs.setString('user_role', role);
  }

  static Future<Map<String, String>?> getUserInfo() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('auth_token');
    final mobile = prefs.getString('user_mobile');
    final role = prefs.getString('user_role');
    if (token == null || mobile == null || role == null) return null;
    return {'token': token, 'mobile': mobile, 'role': role};
  }

  static Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('user_mobile');
    await prefs.remove('user_role');
  }

  static Future<List<TestModel>> getPackages() async {
    final res = await http
        .get(Uri.parse('$baseUrl/api/tests'))
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['success'] == true) {
      return (body['data'] as List)
          .map((p) => TestModel.fromJson(p as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  // One page of the catalog, filtered and searched on the server — the
  // customer home screen loads the list this way instead of all ~1,000
  // products at once. Throws on a network/server error so the caller can
  // keep what it already shows.
  static Future<({List<TestModel> items, int total, bool hasMore})> getPackagesPage({
    String search = '',
    String? category,
    bool offersOnly = false,
    int limit = 20,
    int offset = 0,
  }) async {
    final params = <String, String>{
      'limit':  '$limit',
      'offset': '$offset',
      if (search.trim().isNotEmpty) 'search': search.trim(),
      if (category != null && category != 'All') 'category': category,
      if (offersOnly) 'offer': 'yes',
    };
    final res = await http
        .get(Uri.parse('$baseUrl/api/tests').replace(queryParameters: params))
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['success'] != true) {
      throw Exception(body['message'] ?? 'Could not load tests');
    }
    final items = (body['data'] as List)
        .map((p) => TestModel.fromJson(p as Map<String, dynamic>))
        .toList();
    return (
      items:   items,
      total:   (body['total'] as num?)?.toInt() ?? items.length,
      hasMore: body['hasMore'] == true,
    );
  }

  // Specific products by id (e.g. the tests already on a booking), without
  // downloading the whole catalog. At most 100 ids per call.
  static Future<List<TestModel>> getPackagesByIds(Iterable<String> ids) async {
    final list = ids.where((id) => id.isNotEmpty && id != '0').toSet().toList();
    if (list.isEmpty) return [];
    final res = await http
        .get(Uri.parse('$baseUrl/api/tests').replace(queryParameters: {'ids': list.join(',')}))
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['success'] != true) {
      throw Exception(body['message'] ?? 'Could not load tests');
    }
    return (body['data'] as List)
        .map((p) => TestModel.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  // Category names for the filter chips (all active products, not just the
  // loaded page).
  static Future<List<String>> getPackageCategories() async {
    final res = await http
        .get(Uri.parse('$baseUrl/api/tests/categories'))
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['success'] == true) {
      return (body['data'] as List).map((c) => c.toString()).toList();
    }
    return [];
  }

  static Future<List<PatientModel>> getPatients() async {
    final token = await getToken();
    if (token == null) return [];
    final res = await _client
        .get(
          Uri.parse('$baseUrl/api/patients'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 30));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['success'] == true) {
      return (body['data'] as List)
          .map((p) => PatientModel.fromJson(p as Map<String, dynamic>))
          .toList();
    }
    return [];
  }

  static Future<Map<String, dynamic>> savePatient(Map<String, dynamic> body) async {
    final token = await getToken();
    final res = await _client
        .post(
          Uri.parse('$baseUrl/api/patients'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> updatePatient(String id, Map<String, dynamic> body) async {
    final token = await getToken();
    final res = await _client
        .put(
          Uri.parse('$baseUrl/api/patients/$id'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> deletePatient(String id) async {
    final token = await getToken();
    final res = await _client
        .delete(
          Uri.parse('$baseUrl/api/patients/$id'),
          headers: {'Authorization': 'Bearer $token'},
        )
        .timeout(const Duration(seconds: 15));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<String?> uploadPhoto(Uint8List bytes, String filename) async {
    final token = await getToken();
    if (token == null) return null;
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/upload'))
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(http.MultipartFile.fromBytes(
          'photo', bytes,
          filename: filename,
          contentType: MediaType('image', 'jpeg')));
    final streamed = await _client.send(req).timeout(const Duration(seconds: 30));
    final raw = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200 && streamed.statusCode != 201) return null;
    try {
      final body = jsonDecode(raw) as Map<String, dynamic>;
      if (body['success'] == true) return body['url'] as String?;
    } catch (_) {}
    return null;
  }

  static Future<List<Map<String, dynamic>>> getMyBookings() async {
    final token = await getToken();
    if (token == null) {
      debugPrint('[getMyBookings] No token — user not logged in');
      return [];
    }
    try {
      debugPrint('[getMyBookings] GET $baseUrl/api/bookings/mine');
      final res = await _client.get(
        Uri.parse('$baseUrl/api/bookings/mine'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      debugPrint('[getMyBookings] HTTP ${res.statusCode} — body: ${res.body}');
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) {
        final list = (body['bookings'] as List).cast<Map<String, dynamic>>();
        debugPrint('[getMyBookings] ${list.length} booking(s) received');
        return list;
      }
      debugPrint('[getMyBookings] success=false — ${body['message']}');
    } catch (e, st) {
      debugPrint('[getMyBookings] ERROR: $e\n$st');
    }
    return [];
  }

  static Future<Map<String, dynamic>> createBooking(Map<String, dynamic> body) async {
    final token = await getToken();
    final res = await _client.post(
      Uri.parse('$baseUrl/api/bookings'),
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 10));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<List<TimeSlot>> getSlots({
    required String branchId,
    required DateTime date,
    required String slotType,
  }) async {
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final uri = Uri.parse('$baseUrl/api/slots').replace(queryParameters: {
      'branch_id': branchId,
      'date':      dateStr,
      'slot_type': slotType,
    });
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) {
        return (body['slots'] as List).map((s) => TimeSlot(
          id:    s['time_slot_id'].toString(),
          label: s['label'] as String,
          time:  s['time']  as String,
        )).toList();
      }
    } catch (_) {}
    return [];
  }

  static Future<BranchModel?> lookupBranch({
    String? pincode,
    String? place,
    double? lat,
    double? lng,
  }) async {
    try {
      final params = <String, String>{};
      if (pincode != null && pincode.isNotEmpty) params['pincode'] = pincode;
      if (place   != null && place.isNotEmpty)   params['place']   = place;
      if (lat     != null) params['lat'] = lat.toString();
      if (lng     != null) params['lng'] = lng.toString();

      if (params.isEmpty) return null;

      final uri = Uri.parse('$baseUrl/api/branches/lookup')
          .replace(queryParameters: params);
      final res  = await http.get(uri).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;

      if (res.statusCode == 200 && body['success'] == true) {
        return BranchModel.fromJson(body['branch'] as Map<String, dynamic>);
      }
      debugPrint('[lookupBranch] ${res.statusCode} — ${body['message']}');
    } catch (e) {
      debugPrint('[lookupBranch] ERROR: $e');
    }
    return null;
  }

  // Pre-confirm Home Collection fare preview — mirrors exactly what
  // POST /api/bookings itself independently (re)computes at booking-creation
  // time (server/services/fareCalculator.js), so this is a preview of the
  // same number, not a separate estimate. Returns the raw decoded response
  // body ({success, fare: {...}} on success; {success: false, code,
  // message} on a known fare-calculation failure) rather than just the fare
  // amount, so the caller can show a specific message (e.g. "outside
  // service area") instead of a generic failure.
  static Future<Map<String, dynamic>> getHomeCollectionFareQuote({
    required int branchId,
    required double lat,
    required double lng,
  }) async {
    final token = await getToken();
    if (token == null) {
      return {'success': false, 'code': 'NOT_AUTHENTICATED', 'message': 'Not logged in'};
    }
    try {
      final uri = Uri.parse('$baseUrl/api/bookings/fare-quote').replace(queryParameters: {
        'branchId': branchId.toString(),
        'lat': lat.toString(),
        'lng': lng.toString(),
      });
      final res = await _client.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[getHomeCollectionFareQuote] ERROR: $e');
      return {'success': false, 'code': 'NETWORK_ERROR', 'message': 'Could not reach the server'};
    }
  }

  static Future<String?> uploadFile(List<int> bytes, String fileName) async {
    final token = await getToken();
    if (token == null) return null;
    try {
      final uri = Uri.parse('$baseUrl/api/upload');
      final req = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $token'
        ..files.add(http.MultipartFile.fromBytes('photo', bytes, filename: fileName));
      final streamed = await _client.send(req).timeout(const Duration(seconds: 30));
      // Reading the reply is covered too, so a stalled response can't keep
      // the caller (e.g. "Uploading photo…") waiting with no limit.
      final res  = await http.Response.fromStream(streamed).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) return body['url'] as String?;
      debugPrint('[uploadFile] failed: ${body['message']}');
    } catch (e) {
      debugPrint('[uploadFile] ERROR: $e');
    }
    return null;
  }

  static Future<bool> savePrescription({
    required int    bookingId,
    required int    patientId,
    int?            bookingItemId,
    int?            branchId,
    String?         testMode,
    required List<String> imageUrls,
  }) async {
    final token = await getToken();
    if (token == null) return false;
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/api/prescriptions'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type':  'application/json',
        },
        body: jsonEncode({
          'bookingId':     bookingId,
          'patientId':     patientId,
          'bookingItemId': bookingItemId,
          'branchId':      branchId,
          'testMode':      testMode,
          'imageUrls':     imageUrls,
        }),
      ).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) return true;
      debugPrint('[savePrescription] failed: ${body['message']}');
    } catch (e) {
      debugPrint('[savePrescription] ERROR: $e');
    }
    return false;
  }

  // Returns [{bookingItemId, productId, name, category, price}]
  static Future<List<Map<String, dynamic>>> getBookingItems(int bookingId) async {
    final token = await getToken();
    if (token == null) return [];
    try {
      final res = await _client.get(
        Uri.parse('$baseUrl/api/bookings/$bookingId/items'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) {
        return (body['items'] as List).cast<Map<String, dynamic>>();
      }
    } catch (e) {
      debugPrint('[getBookingItems] ERROR: $e');
    }
    return [];
  }

  // Returns {bookingItemId, productId, name, category, price} or null on failure
  static Future<Map<String, dynamic>?> addBookingItem({
    required int bookingId,
    required int productId,
  }) async {
    final token = await getToken();
    if (token == null) return null;
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/api/bookings/$bookingId/items'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'productId': productId}),
      ).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) return body['item'] as Map<String, dynamic>?;
      debugPrint('[addBookingItem] failed: ${body['message']}');
    } catch (e) {
      debugPrint('[addBookingItem] ERROR: $e');
    }
    return null;
  }

  static Future<bool> removeBookingItem({
    required int bookingId,
    required int bookingItemId,
  }) async {
    final token = await getToken();
    if (token == null) return false;
    try {
      final res = await _client.delete(
        Uri.parse('$baseUrl/api/bookings/$bookingId/items/$bookingItemId'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return body['success'] == true;
    } catch (e) {
      debugPrint('[removeBookingItem] ERROR: $e');
    }
    return false;
  }

  // Technician checklist toggle — marks (or unmarks) one test/package as
  // physically collected. Purely a per-item tracking flag, independent of
  // the booking/collection status flow (sample_collected, etc.).
  static Future<bool> setBookingItemCollected({
    required int bookingId,
    required int bookingItemId,
    required bool collected,
  }) async {
    final token = await getToken();
    if (token == null) return false;
    try {
      final res = await _client.patch(
        Uri.parse('$baseUrl/api/bookings/$bookingId/items/$bookingItemId/collected'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        // Server reuses the pre-existing item_status column (also written by
        // admin/reporting flows), so we must match its exact lowercase
        // vocabulary: 'completed' / 'pending'.
        body: jsonEncode({'status': collected ? 'completed' : 'pending'}),
      ).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return body['success'] == true;
    } catch (e) {
      debugPrint('[setBookingItemCollected] ERROR: $e');
    }
    return false;
  }

  // Associates an already-uploaded (via uploadFile) proof-of-collection photo
  // URL with a booking_id. Separate from savePrescriptionDoc/ip_prescriptions
  // so it does not appear in the prescription document list.
  static Future<bool> saveCollectionProofPhoto({
    required int bookingId,
    required String imageUrl,
  }) async {
    final token = await getToken();
    if (token == null) return false;
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/api/bookings/$bookingId/collection-photo'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'imageUrl': imageUrl}),
      ).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return body['success'] == true;
    } catch (e) {
      debugPrint('[saveCollectionProofPhoto] ERROR: $e');
    }
    return false;
  }

  // Removes the sample-collection proof photo for a booking (before OTP).
  // Returns {success, message}; the server refuses once the visit is
  // OTP-verified or handed over.
  static Future<Map<String, dynamic>> deleteCollectionProofPhoto(int bookingId) async {
    final token = await getToken();
    if (token == null) return {'success': false};
    try {
      final res = await http.delete(
        Uri.parse('$baseUrl/api/bookings/$bookingId/collection-photo'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[deleteCollectionProofPhoto] ERROR: $e');
      return {'success': false, 'error': e};
    }
  }

  // Fetches the current sample-collection proof photo for a booking, if any
  // — used to render "Added"/"Not Added" and the thumbnail when the Manage
  // Booking screen loads (a retake replaces this with the newest photo).
  static Future<Map<String, dynamic>?> getCollectionProofPhoto(int bookingId) async {
    final token = await getToken();
    if (token == null) return null;
    try {
      final res = await _client.get(
        Uri.parse('$baseUrl/api/bookings/$bookingId/collection-photo'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) return body['doc'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('[getCollectionProofPhoto] ERROR: $e');
    }
    return null;
  }

  // Records on-site payment collected by technician and marks booking paid in DB.
  // paymentMethod: 'RAZORPAY' (default, requires razorpayPaymentId) or 'CASH'
  // (razorpayPaymentId not required). amount may be less than the full amount
  // due — the server tracks the remaining balance as a partial payment.
  static Future<bool> collectPayment({
    required int bookingId,
    String? razorpayPaymentId,
    required double amount,
    String paymentMethod = 'RAZORPAY',
  }) async {
    final token = await getToken();
    if (token == null) return false;
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/api/technicians/collect-payment'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'bookingId': bookingId,
          'razorpayPaymentId': razorpayPaymentId,
          'amount': amount,
          'paymentMethod': paymentMethod,
        }),
      ).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) return true;
      debugPrint('[collectPayment] failed: ${body['message']}');
    } catch (e) {
      debugPrint('[collectPayment] ERROR: $e');
    }
    return false;
  }

  // Sets the booking's additional charge (amount + reason) entered by the
  // technician on site — replaces any earlier one, amount 0 removes it. The
  // server adds it to total_amount / amount_due. Returns the server reply:
  // {success, totalAmount, amountDue, paymentStatus, ...} or {success:false, message}.
  static Future<Map<String, dynamic>> setAdditionalCharge({
    required int bookingId,
    required double amount,
    required String reason,
  }) async {
    final token = await getToken();
    if (token == null) return {'success': false, 'message': 'Not logged in'};
    try {
      final res = await _client.put(
        Uri.parse('$baseUrl/api/technicians/bookings/$bookingId/additional-charge'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'amount': amount, 'reason': reason}),
      ).timeout(const Duration(seconds: 15));
      // A server without this route answers with an HTML 404 page, not JSON.
      if (!res.body.trimLeft().startsWith('{')) {
        debugPrint('[setAdditionalCharge] HTTP ${res.statusCode} — not a JSON reply (server not updated?)');
        return {'success': false, 'message': 'Additional charges aren\'t available on the server yet. Please try again later.'};
      }
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[setAdditionalCharge] ERROR: $e');
      return {'success': false, 'message': 'Network error'};
    }
  }

  // Technician hands off an already-accepted job before starting travel — the
  // booking is released and re-dispatched to another technician, not cancelled
  // for the patient. Server only allows this while the job is still 'assigned'.
  // reason must be one of: vehicle_issue, personal_emergency, unreachable_patient, other.
  static Future<Map<String, dynamic>> cancelAssignedBooking({
    required int bookingId,
    required String reason,
    String? note,
  }) async {
    final token = await getToken();
    if (token == null) return {'success': false, 'message': 'Not logged in'};
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/api/technicians/cancel-booking'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'bookingId': bookingId,
          'reason': reason,
          'note': note,
        }),
      ).timeout(const Duration(seconds: 15));
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[cancelAssignedBooking] ERROR: $e');
      return {'success': false, 'message': 'Network error'};
    }
  }

  // Returns [{patientId, patientName, patientMobile}] for additional patients linked to a booking
  // Returns {payment_status, amount_paid, amount_due, total_amount, items_total}
  // for a booking — used by the technician detail screen to get fresh payment
  // info on every open. total_amount is fixed at booking creation (tests +
  // service charge at that time); items_total reflects the CURRENT item list
  // (including tests added at the door), so total_amount - items_total is only
  // meaningful against the ORIGINAL item set, not the live one.
  static Future<Map<String, dynamic>?> getBookingPaymentInfo(int bookingId) async {
    final token = await getToken();
    if (token == null) return null;
    try {
      final res = await _client.get(
        Uri.parse('$baseUrl/api/bookings/$bookingId'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) {
        final b = body['booking'] as Map<String, dynamic>;
        return {
          'payment_status': b['payment_status'],
          'amount_paid':    b['amount_paid'],
          'amount_due':     b['amount_due'],
          'total_amount':   b['total_amount'],
          'items_total':    b['items_total'],
          'additional_charge_amount': b['additional_charge_amount'],
          'additional_charge_reason': b['additional_charge_reason'],
        };
      }
    } catch (e) {
      debugPrint('[getBookingPaymentInfo] ERROR: $e');
    }
    return null;
  }

  static Future<List<Map<String, dynamic>>> getLinkedPatients(int bookingId) async {
    final token = await getToken();
    if (token == null) return [];
    try {
      final res = await _client.get(
        Uri.parse('$baseUrl/api/bookings/$bookingId/linked-patients'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) {
        return (body['patients'] as List).cast<Map<String, dynamic>>();
      }
    } catch (e) {
      debugPrint('[getLinkedPatients] ERROR: $e');
    }
    return [];
  }

  // Fetches /api/tests and maps to {id, name, category, price} for the technician catalogue
  static Future<List<Map<String, String>>> getTechTestCatalogue() async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/api/tests'))
          .timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) {
        return (body['data'] as List).map((p) {
          final m = p as Map<String, dynamic>;
          return {
            'id':           m['id']?.toString() ?? '',
            'name':         m['name']?.toString() ?? '',
            'category':     m['category']?.toString() ?? 'General',
            'price':        (m['final_price'] as num?)?.toStringAsFixed(0) ?? '0',
            'docRequired':  m['doc_req']?.toString() ?? 'no',
          };
        }).toList();
      }
    } catch (e) {
      debugPrint('[getTechTestCatalogue] ERROR: $e');
    }
    return [];
  }

  static Future<List<Map<String, dynamic>>> getPrescriptions(int bookingId) async {
    final token = await getToken();
    if (token == null) return [];
    try {
      final res = await _client.get(
        Uri.parse('$baseUrl/api/prescriptions/$bookingId'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) {
        return (body['docs'] as List).cast<Map<String, dynamic>>();
      }
    } catch (e) {
      debugPrint('[getPrescriptions] ERROR: $e');
    }
    return [];
  }

  static Future<int?> savePrescriptionDoc({
    required int bookingId,
    required int patientId,
    required String imageUrl,
  }) async {
    final token = await getToken();
    if (token == null) return null;
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/api/prescriptions'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'bookingId': bookingId,
          'patientId': patientId,
          'imageUrls': [imageUrl],
        }),
      ).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) {
        final ids = body['docIds'] as List?;
        return ids?.isNotEmpty == true ? (ids!.first as num).toInt() : null;
      }
      debugPrint('[savePrescriptionDoc] failed: ${body['message']}');
    } catch (e) {
      debugPrint('[savePrescriptionDoc] ERROR: $e');
    }
    return null;
  }

  static Future<bool> verifyPrescription(int docId) async {
    final token = await getToken();
    if (token == null) return false;
    try {
      final res = await _client.patch(
        Uri.parse('$baseUrl/api/prescriptions/$docId/verify'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return body['success'] == true;
    } catch (e) {
      debugPrint('[verifyPrescription] ERROR: $e');
    }
    return false;
  }

  static Future<bool> deletePrescription(int docId) async {
    final token = await getToken();
    if (token == null) return false;
    try {
      final res = await _client.delete(
        Uri.parse('$baseUrl/api/prescriptions/$docId'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return body['success'] == true;
    } catch (e) {
      debugPrint('[deletePrescription] ERROR: $e');
    }
    return false;
  }

  static Future<bool> payBooking({
    required int bookingId,
    required String razorpayPaymentId,
    String? razorpayOrderId,
    required double amount,
  }) async {
    final token = await getToken();
    if (token == null) return false;
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/api/bookings/$bookingId/pay'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type':  'application/json',
        },
        body: jsonEncode({
          'razorpayPaymentId': razorpayPaymentId,
          'razorpayOrderId':   razorpayOrderId,
          'amount':            amount,
        }),
      ).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) return true;
      debugPrint('[payBooking] failed: ${body['message']}');
    } catch (e) {
      debugPrint('[payBooking] ERROR: $e');
    }
    return false;
  }

  /// Returns only the live technician fields for a booking — used to poll
  /// collection_status while the detail sheet is open.
  /// Returns null on error or if no technician row exists yet.
  static Future<Uint8List> getReportProxy(int bookingId, int resultId) async {
    final token = await getToken();
    final res = await _client.get(
      Uri.parse('$baseUrl/api/bookings/$bookingId/results/$resultId/proxy'),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw Exception('Failed to fetch report (HTTP ${res.statusCode})');
    }
    return res.bodyBytes;
  }

  static Future<List<Map<String, dynamic>>> getBookingResults(int bookingId) async {
    try {
      final token = await getToken();
      if (token == null) return [];
      final res = await _client.get(
        Uri.parse('$baseUrl/api/bookings/$bookingId/results'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) {
        return List<Map<String, dynamic>>.from(body['results'] as List);
      }
    } catch (_) {}
    return [];
  }

  static Future<Map<String, dynamic>?> fetchBookingStatus(int bookingId) async {
    try {
      final token = await getToken();
      final res = await _client.get(
        Uri.parse('$baseUrl/api/bookings/$bookingId'),
        headers: token != null ? {'Authorization': 'Bearer $token'} : {},
      ).timeout(const Duration(seconds: 10));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true && body['booking'] != null) {
        final b = body['booking'] as Map<String, dynamic>;
        return {
          'collection_status':   b['collection_status'],
          'tech_name':           b['tech_name'],
          'tech_mobile':         b['tech_mobile'],
          'tech_photo':          b['tech_photo'],
          'technician_id':       b['technician_id'],
          'collection_latitude': b['collection_latitude'],
          'collection_longitude': b['collection_longitude'],
        };
      }
    } catch (_) {}
    return null;
  }

  /// Returns {bookingId, bookingRef, patientId, patientName, totalAmount} or null on failure.
  static Future<Map<String, dynamic>?> addCustomerBooking({
    required int parentBookingId,
    required String name,
    required String mobile,
    String? email,
    String? dob,
    int? age,
    String? gender,
    String? relation,
    String? healthNotes,
    required List<int> productIds,
  }) async {
    final token = await getToken();
    if (token == null) return null;
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/api/technicians/add-customer'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'parentBookingId': parentBookingId,
          'name': name,
          'mobile': mobile,
          if (email != null && email.isNotEmpty) 'email': email,
          if (dob != null) 'dob': dob,
          if (age != null) 'age': age,
          if (gender != null) 'gender': gender,
          if (relation != null && relation.isNotEmpty) 'relation': relation,
          if (healthNotes != null && healthNotes.isNotEmpty) 'healthNotes': healthNotes,
          'tests': productIds.map((id) => {'productId': id}).toList(),
        }),
      ).timeout(const Duration(seconds: 20));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) return body;
      debugPrint('[addCustomerBooking] failed: ${body['message']}');
    } catch (e) {
      debugPrint('[addCustomerBooking] ERROR: $e');
    }
    return null;
  }

  /// Search for an existing patient by mobile within the booking's client scope.
  /// Returns the patient map if found, or null if not found / on error.
  static Future<Map<String, dynamic>?> lookupPatientByMobile({
    required String mobile,
    required int bookingId,
  }) async {
    final token = await getToken();
    if (token == null) return null;
    try {
      final res = await _client.get(
        Uri.parse('$baseUrl/api/technicians/patient-lookup?mobile=$mobile&bookingId=$bookingId'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) return body['patient'] as Map<String, dynamic>?;
      debugPrint('[lookupPatientByMobile] failed: ${body['message']}');
    } catch (e) {
      debugPrint('[lookupPatientByMobile] ERROR: $e');
    }
    return null;
  }

  /// Creates a sibling booking for an on-site family member, linked via visit_group_id.
  /// Pass [patientId] when the patient was found via lookupPatientByMobile; otherwise
  /// pass [name] + [mobile] and the server will find-or-create the patient.
  static Future<Map<String, dynamic>?> addVisitMember({
    required int parentBookingId,
    int? patientId,
    String? name,
    String? mobile,
    String? email,
    String? dob,
    int? age,
    String? gender,
    String? relation,
    String? healthNotes,
    required List<Map<String, dynamic>> tests,
  }) async {
    final token = await getToken();
    if (token == null) return null;
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/api/technicians/add-visit-member'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'parentBookingId': parentBookingId,
          if (patientId != null) 'patientId': patientId,
          if (name != null && name.isNotEmpty) 'name': name,
          if (mobile != null && mobile.isNotEmpty) 'mobile': mobile,
          if (email != null && email.isNotEmpty) 'email': email,
          if (dob != null) 'dob': dob,
          if (age != null) 'age': age,
          if (gender != null) 'gender': gender,
          if (relation != null && relation.isNotEmpty) 'relation': relation,
          if (healthNotes != null && healthNotes.isNotEmpty) 'healthNotes': healthNotes,
          'tests': tests,
        }),
      ).timeout(const Duration(seconds: 20));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) return body;
      debugPrint('[addVisitMember] failed: ${body['message']} | detail: ${body['detail']}');
    } catch (e) {
      debugPrint('[addVisitMember] ERROR: $e');
    }
    return null;
  }

  // Sends 1–4 members in one call; server creates one booking per member.
  // members: [{ patientId?, name, mobile, dob?, age?, gender?, relation?, healthNotes?, tests:[{productId, price?}] }]
  static Future<Map<String, dynamic>?> addVisitMembers({
    required int parentBookingId,
    required List<Map<String, dynamic>> members,
  }) async {
    final token = await getToken();
    if (token == null) return null;
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/api/technicians/add-visit-member'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'parentBookingId': parentBookingId,
          'members': members,
        }),
      ).timeout(const Duration(seconds: 30));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) return body;
      debugPrint('[addVisitMembers] failed: ${body['message']} | detail: ${body['detail']}');
    } catch (e) {
      debugPrint('[addVisitMembers] ERROR: $e');
    }
    return null;
  }

  static Future<List<Map<String, dynamic>>> getBookingFamily(int bookingId) async {
    final token = await getToken();
    if (token == null) return [];
    try {
      final res = await _client.get(
        Uri.parse('$baseUrl/api/technicians/booking-family?bookingId=$bookingId'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) {
        return (body['members'] as List).cast<Map<String, dynamic>>();
      }
    } catch (e) {
      debugPrint('[getBookingFamily] ERROR: $e');
    }
    return [];
  }

  // ── Booking OTP (sample-collection handoff) ──────────────────────────────

  static Future<Map<String, dynamic>?> generateBookingOtp(int bookingId) async {
    final token = await getToken();
    if (token == null) return null;
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/api/technicians/booking-otp/generate'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({'bookingId': bookingId}),
      ).timeout(const Duration(seconds: 15));
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[generateBookingOtp] ERROR: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>?> verifyBookingOtp({
    required int bookingId,
    required String otp,
  }) async {
    final token = await getToken();
    if (token == null) return null;
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/api/technicians/booking-otp/verify'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({'bookingId': bookingId, 'otp': otp}),
      ).timeout(const Duration(seconds: 15));
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[verifyBookingOtp] ERROR: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>?> resendBookingOtp(int bookingId) async {
    final token = await getToken();
    if (token == null) return null;
    try {
      final res = await _client.post(
        Uri.parse('$baseUrl/api/technicians/booking-otp/resend'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({'bookingId': bookingId}),
      ).timeout(const Duration(seconds: 15));
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[resendBookingOtp] ERROR: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>?> updateBookingItems({
    required int bookingId,
    required List<Map<String, dynamic>> items,
    double serviceCharge = 0,
  }) async {
    final token = await getToken();
    if (token == null) return null;
    try {
      final res = await _client.put(
        Uri.parse('$baseUrl/api/bookings/$bookingId/items'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({'items': items, 'serviceCharge': serviceCharge}),
      ).timeout(const Duration(seconds: 15));
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[updateBookingItems] ERROR: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>?> createFamilyBooking({
    required List<Map<String, dynamic>> members,
    int? availableSlotId,
    String? collectionDate,
    required String bookingType,
    String? collectionAddress,
    String? collectionPincode,
    String? collectionCity,
    double? collectionLatitude,
    double? collectionLongitude,
    int? branchId,
    required String paymentType,
    String? razorpayPaymentId,
    String? razorpayOrderId,
  }) async {
    final token = await getToken();
    if (token == null) return null;
    try {
      final body = <String, dynamic>{
        'members':     members,
        'bookingType': bookingType,
        'paymentType': paymentType,
        if (availableSlotId     != null) 'availableSlotId':    availableSlotId,
        if (collectionDate      != null) 'collectionDate':     collectionDate,
        if (collectionAddress   != null) 'collectionAddress':  collectionAddress,
        if (collectionPincode   != null) 'collectionPincode':  collectionPincode,
        if (collectionCity      != null) 'collectionCity':     collectionCity,
        if (collectionLatitude  != null) 'collectionLatitude': collectionLatitude,
        if (collectionLongitude != null) 'collectionLongitude': collectionLongitude,
        if (branchId            != null) 'branchId':           branchId,
        if (razorpayPaymentId   != null) 'razorpayPaymentId':  razorpayPaymentId,
        if (razorpayOrderId     != null) 'razorpayOrderId':    razorpayOrderId,
      };
      final res = await _client.post(
        Uri.parse('$baseUrl/api/bookings/family'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 15));
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[createFamilyBooking] ERROR: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>> submitPrescriptionRequest(
      List<String> filePaths, {String? patientId, String? notes}) async {
    final token = await getToken();
    if (token == null) throw Exception('Not authenticated');
    final res = await _client.post(
      Uri.parse('$baseUrl/api/prescription-requests'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode({
        'file_paths': filePaths,
        if (patientId != null) 'patient_id': int.tryParse(patientId) ?? patientId,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      }),
    ).timeout(const Duration(seconds: 15));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<List<Map<String, dynamic>>> getMyPrescriptionRequests({String? patientId}) async {
    final token = await getToken();
    if (token == null) return [];
    try {
      final uri = Uri.parse('$baseUrl/api/prescription-requests/mine')
          .replace(queryParameters: patientId != null ? {'patient_id': patientId} : null);
      final res = await _client.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] == true) {
        return List<Map<String, dynamic>>.from(body['requests'] as List);
      }
    } catch (_) {}
    return [];
  }

  static Future<Map<String, dynamic>> rescheduleBooking(
      int bookingIdNum, {required String collectionDate, required int availableSlotId}) async {
    final token = await getToken();
    if (token == null) throw Exception('Not authenticated');
    final res = await _client.post(
      Uri.parse('$baseUrl/api/bookings/$bookingIdNum/reschedule'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode({'collectionDate': collectionDate, 'availableSlotId': availableSlotId}),
    ).timeout(const Duration(seconds: 15));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> cancelBooking(int bookingIdNum, {String? reason}) async {
    final token = await getToken();
    if (token == null) throw Exception('Not authenticated');
    final res = await _client.post(
      Uri.parse('$baseUrl/api/bookings/$bookingIdNum/cancel'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode({'reason': reason}),
    ).timeout(const Duration(seconds: 15));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> selfEditBookingItems(
    int bookingIdNum, {
    required List<Map<String, dynamic>> items,
    String? razorpayPaymentId,
    bool payDiffLater = false,
    double? topUpAmount,
  }) async {
    final token = await getToken();
    if (token == null) throw Exception('Not authenticated');
    final body = <String, dynamic>{'items': items};
    if (razorpayPaymentId != null) body['razorpayPaymentId'] = razorpayPaymentId;
    if (payDiffLater) body['payDiffLater'] = true;
    if (topUpAmount != null) body['topUpAmount'] = topUpAmount;
    final res = await _client.post(
      Uri.parse('$baseUrl/api/bookings/$bookingIdNum/self-edit'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 20));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> submitFeedback(
      int bookingIdNum, int rating, String comment) async {
    final token = await getToken();
    if (token == null) throw Exception('Not authenticated');
    final res = await _client.post(
      Uri.parse('$baseUrl/api/feedback'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: jsonEncode({
        'booking_id':        bookingIdNum,
        'overall_rating':    rating,
        'feedback_comments': comment.isEmpty ? null : comment,
      }),
    ).timeout(const Duration(seconds: 15));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<List<BranchModel>> getBranches({String? pincode, String? city}) async {
    final params = <String, String>{};
    if (pincode != null && pincode.isNotEmpty) params['pincode'] = pincode;
    if (city != null && city.isNotEmpty) params['city'] = city;
    final uri = Uri.parse('$baseUrl/api/branches')
        .replace(queryParameters: params.isEmpty ? null : params);
    final res = await http.get(uri).timeout(const Duration(seconds: 15));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['success'] == true) {
      return (body['data'] as List).map((b) => BranchModel(
        id: b['id'].toString(),
        name: b['name'] as String,
        address: b['address'] as String,
        location: b['location'] as String?,
        pincode: b['pincode']?.toString(),
        // Used by the Lab Test sheet to sort branches by distance.
        lat: double.tryParse(b['latitude']?.toString() ?? ''),
        lng: double.tryParse(b['longitude']?.toString() ?? ''),
      )).toList();
    }
    return [];
  }

  static Future<Map<String, dynamic>?> getLetterhead() async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/api/letterhead'))
          .timeout(const Duration(seconds: 10));
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['success'] == true) return data;
    } catch (_) {}
    return null;
  }
}

// Intercepts every HTTP response that carries an Authorization header.
// If the server returns 401, the stored session is cleared and the app
// is sent back to the onboarding/login screen.
class _AuthClient extends http.BaseClient {
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    if (response.statusCode == 401 &&
        request.headers.containsKey('Authorization')) {
      ApiService._handle401();
    }
    return response;
  }
}
