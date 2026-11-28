import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:microlab/constants/app_constants.dart';

/// A point on the map.
typedef GeoPoint = ({double lat, double lng});

/// Finds the map point of a typed address, the same Google lookup the
/// location sheet's "Enter Address Manually" uses. Tries the full address
/// with its pincode first (closer to the house), then the pincode alone
/// (the centre of the pincode area). Returns null when nothing is found or
/// there is no connection — the caller decides what to do then.
Future<GeoPoint?> geocodeAddress({String? address, String? pincode, String? city}) async {
  final pin = (pincode ?? '').trim();
  final queries = <String>[
    if ((address ?? '').trim().isNotEmpty)
      [address!.trim(), if ((city ?? '').trim().isNotEmpty) city!.trim(), if (pin.isNotEmpty) pin, 'India'].join(', '),
    if (pin.length == 6) '$pin, India',
  ];
  for (final q in queries) {
    final point = await _lookup(q, pin);
    if (point != null) return point;
  }
  return null;
}

/// What a 6-digit pincode resolves to: the area from India Post and the
/// map point (centre of the pincode area) from Google — the same two
/// lookups as the location sheet's "Enter Address Manually".
typedef PincodeInfo = ({String? area, String? district, String? state, GeoPoint? point});

/// Returns null when the pincode is not found at all.
Future<PincodeInfo?> lookupPincode(String pincode) async {
  final pin = pincode.trim();
  if (pin.length != 6) return null;
  String? area, district, state;
  try {
    final res = await http
        .get(Uri.parse('https://api.postalpincode.in/pincode/$pin'))
        .timeout(const Duration(seconds: 8));
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body) as List;
      if (data.isNotEmpty && data[0]['Status'] == 'Success') {
        final offices = data[0]['PostOffice'] as List;
        if (offices.isNotEmpty) {
          final po = offices[0] as Map;
          area     = po['Name']?.toString();
          district = po['District']?.toString();
          state    = po['State']?.toString();
        }
      }
    }
  } catch (e) {
    debugPrint('[geocode] pincode area lookup failed: $e');
  }
  final point = await _lookup('$pin, India', pin);
  if (point == null && district == null) return null;
  return (area: area, district: district, state: state, point: point);
}

Future<GeoPoint?> _lookup(String query, String pin) async {
  try {
    final uri = Uri.parse('https://maps.googleapis.com/maps/api/geocode/json').replace(
      queryParameters: {
        'address': query,
        // Keep results inside India and, when known, inside that pincode.
        'components': pin.length == 6 ? 'country:IN|postal_code:$pin' : 'country:IN',
        'key': AppConstants.googleMapsApiKey,
      },
    );
    final res = await http.get(uri).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return null;
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (data['status'] != 'OK') return null;
    final results = data['results'] as List;
    if (results.isEmpty) return null;
    final loc = (results[0]['geometry'] as Map)['location'] as Map;
    return (lat: (loc['lat'] as num).toDouble(), lng: (loc['lng'] as num).toDouble());
  } catch (e) {
    debugPrint('[geocode] lookup failed: $e');
    return null;
  }
}
