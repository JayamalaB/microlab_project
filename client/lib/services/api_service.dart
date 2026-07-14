import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:microlab/models.dart';
import 'package:microlab/constants/app_constants.dart';

class ApiService {
  static const String baseUrl = AppConstants.serverUrl;

  static Future<Map<String, dynamic>> sendOtp(String mobile, String role) async {
    final res = await http
        .post(
          Uri.parse('$baseUrl/api/auth/send-otp'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'mobile': mobile, 'role': role}),
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

  static Future<void> logout(String token) async {
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

  static Future<List<PatientModel>> getPatients() async {
    final token = await getToken();
    if (token == null) return [];
    final res = await http
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
    final res = await http
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
    final res = await http
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
    final res = await http
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
    final streamed = await req.send().timeout(const Duration(seconds: 30));
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
      final res = await http.get(
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
    final res = await http.post(
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

  static Future<String?> uploadFile(List<int> bytes, String fileName) async {
    final token = await getToken();
    if (token == null) return null;
    try {
      final uri = Uri.parse('$baseUrl/api/upload');
      final req = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $token'
        ..files.add(http.MultipartFile.fromBytes('photo', bytes, filename: fileName));
      final streamed = await req.send().timeout(const Duration(seconds: 30));
      final res  = await http.Response.fromStream(streamed);
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
      final res = await http.post(
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
      final res = await http.get(
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
      final res = await http.post(
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
      final res = await http.delete(
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
            'id':       m['id']?.toString() ?? '',
            'name':     m['name']?.toString() ?? '',
            'category': m['category']?.toString() ?? 'General',
            'price':    (m['final_price'] as num?)?.toStringAsFixed(0) ?? '0',
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
      final res = await http.get(
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
      final res = await http.post(
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
      final res = await http.patch(
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
      final res = await http.delete(
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
      final res = await http.post(
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
  static Future<Map<String, dynamic>?> fetchBookingStatus(int bookingId) async {
    try {
      final token = await getToken();
      final res = await http.get(
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
      final res = await http.post(
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

  static Future<Map<String, dynamic>?> updateBookingItems({
    required int bookingId,
    required List<Map<String, dynamic>> items,
    double serviceCharge = 0,
  }) async {
    final token = await getToken();
    if (token == null) return null;
    try {
      final res = await http.put(
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
      final res = await http.post(
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
    final res = await http.post(
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
      final res = await http.get(
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

  static Future<Map<String, dynamic>> submitFeedback(
      int bookingIdNum, int rating, String comment) async {
    final token = await getToken();
    if (token == null) throw Exception('Not authenticated');
    final res = await http.post(
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
      )).toList();
    }
    return [];
  }
}
