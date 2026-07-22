import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../constants/app_constants.dart';

class AuthService {
  static const _base = AppConstants.serverUrl;

  // POST /api/auth/send-otp
  static Future<Map<String, dynamic>> sendOtp(String mobile, String role) async {
    try {
      final res = await http
          .post(
            Uri.parse('$_base/api/auth/send-otp'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'mobile': mobile, 'role': role}),
          )
          .timeout(const Duration(seconds: 10));

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return {'success': res.statusCode == 200, ...body};
    } catch (e) {
      return {'success': false, 'message': 'Connection failed. Check internet.'};
    }
  }

  // POST /api/auth/verify-otp  →  saves token + user to SharedPreferences
  static Future<Map<String, dynamic>> verifyOtp(
      String mobile, String otp, String role) async {
    try {
      final res = await http
          .post(
            Uri.parse('$_base/api/auth/verify-otp'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'mobile': mobile, 'otp': otp, 'role': role}),
          )
          .timeout(const Duration(seconds: 10));

      final body = jsonDecode(res.body) as Map<String, dynamic>;

      if (res.statusCode == 200 && body['success'] == true) {
        final data = body['data'] as Map<String, dynamic>;
        await _saveSession(mobile, role, data);
      }

      return {'success': res.statusCode == 200 && body['success'] == true, ...body};
    } catch (e) {
      return {'success': false, 'message': 'Connection failed. Check internet.'};
    }
  }

  static Future<void> _saveSession(
      String mobile, String role, Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final user  = data['user'] as Map<String, dynamic>? ?? {};

    await prefs.setString('auth_token',  data['token'] as String? ?? '');
    await prefs.setString('user_role',   role);
    await prefs.setString('user_mobile', mobile);

    if (role == 'technician') {
      await prefs.setInt('user_id',          user['technician_id']  as int?    ?? 0);
      await prefs.setString('user_name',     user['user_name']      as String? ?? mobile);
      await prefs.setString('user_email',    user['user_email']     as String? ?? '');
      await prefs.setInt('branch_id',        user['branch_id']      as int?    ?? 0);
      await prefs.setString('technician_code', user['technician_code'] as String? ?? '');
      await prefs.setString('specialization',  user['specialization']  as String? ?? '');
      await prefs.setString('tech_city',       user['tech_city']       as String? ?? '');
      await prefs.setString('tech_photo',      user['tech_photo']      as String? ?? '');
    } else {
      await prefs.setInt('user_id',    user['patient_id']    as int?    ?? 0);
      await prefs.setString('user_name', user['patient_name'] as String? ?? mobile);
    }
  }

  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }
}
