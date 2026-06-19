import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:microlab/models.dart';

class ApiService {
  static const String baseUrl = 'http://microlab.neuralarc.com:30008';

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
        .timeout(const Duration(seconds: 15));
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
        .get(Uri.parse('$baseUrl/api/packages'))
        .timeout(const Duration(seconds: 15));
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['success'] == true) {
      return (body['data'] as List)
          .map((p) => TestModel.fromJson(p as Map<String, dynamic>))
          .toList();
    }
    return [];
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
