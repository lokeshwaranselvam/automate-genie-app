import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'geofence_manager.dart';

/// GPS sync while the PWA is running. Browsers may suspend it when hidden;
/// this does not claim Android foreground-service/background capabilities.
class LiveLocationService {
  static final _instance = LiveLocationService._();
  factory LiveLocationService() => _instance;
  LiveLocationService._();
  StreamSubscription<Position>? _subscription;
  Future<void> _operations = Future.value();
  DateTime? _lastSent;
  bool _sending = false;
  bool get isTracking => _subscription != null;
  Future<void> startTracking() => ensureTracking();
  Future<void> ensureTracking() => _serialize(() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (prefs.getBool('is_employee_checked_in') != true) {
      await _stop();
      return;
    }
    if (_subscription != null) return;
    if (!await hasLocationPermissions() &&
        !await requestLocationPermissions()) {
      throw StateError('Allow location access to track while the PWA is open.');
    }
    final user = prefs.getString('email');
    final marker = prefs.getString('session_sid');
    final token = prefs.getString('token');
    if (user == null ||
        marker == null ||
        token == null ||
        !token.startsWith('token ')) {
      throw StateError('Sign in again before starting location tracking.');
    }
    _subscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(
      (position) {
        unawaited(_sync(position, user, marker, token));
      },
      onError: (Object error) {
        debugPrint('Browser GPS unavailable: $error');
        unawaited(stopTracking());
      },
    );
  });
  Future<void> _sync(
    Position position,
    String user,
    String marker,
    String token,
  ) async {
    if (_sending || position.isMocked || position.accuracy > 100) return;
    final now = DateTime.now();
    if (_lastSent != null &&
        now.difference(_lastSent!) < const Duration(seconds: 15))
      return;
    _sending = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (prefs.getBool('is_employee_checked_in') != true ||
          prefs.getString('session_sid') != marker ||
          prefs.getString('token') != token ||
          prefs.getString('email') != user) {
        unawaited(stopTracking());
        return;
      }
      final site = dotenv.env['SITE_URL']?.trim() ?? '';
      if (site.isEmpty) throw StateError('SITE_URL is missing.');
      _lastSent = now;
      final response = await http
          .post(
            Uri.parse(site).resolve('/api/resource/Live%20Location'),
            headers: {
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'Authorization': token,
            },
            body: jsonEncode({
              'user': user,
              'latitude': position.latitude,
              'longitude': position.longitude,
              'location':
                  '${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}',
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 && response.statusCode != 201) {
        debugPrint('Browser GPS sync returned ${response.statusCode}');
        if (response.statusCode == 401 || response.statusCode == 403)
          unawaited(stopTracking());
      }
    } catch (error) {
      debugPrint('Browser GPS sync failed: ${error.runtimeType}');
    } finally {
      _sending = false;
    }
  }

  Future<void> _stop() async {
    final stream = _subscription;
    _subscription = null;
    await stream?.cancel();
    _lastSent = null;
  }

  Future<void> stopTracking() => _serialize(_stop);
  static Future<void> stopForSignOut() async {
    await _instance.stopTracking();
    await GeofenceManager.instance.stopMonitoring();
  }

  Future<bool> hasLocationPermissions() async {
    final p = await Geolocator.checkPermission();
    return p == LocationPermission.always || p == LocationPermission.whileInUse;
  }

  Future<bool> requestLocationPermissions() async {
    final p = await Geolocator.requestPermission();
    return p == LocationPermission.always || p == LocationPermission.whileInUse;
  }

  Future<Map<String, dynamic>> getBatteryOptimizationStatus() async => {
    'supported': false,
  };
  Future<void> openBatteryOptimizationSettings() async {}
  Future<void> requestIgnoreBatteryOptimization() async {}
  Future<void> _serialize(Future<void> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }
}
