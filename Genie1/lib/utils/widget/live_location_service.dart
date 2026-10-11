import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'geofence_manager.dart';

class LiveLocationService {
  static final LiveLocationService _instance = LiveLocationService._internal();

  factory LiveLocationService() => _instance;

  LiveLocationService._internal();

  static const platform = MethodChannel('com.example.homegenieapp/tracking');

  bool _isTracking = false;
  late SharedPreferences prefs;
  final String baseUrl = dotenv.env['URL'] ?? '';

  /// Start tracking live location through the Android foreground service.
  Future<void> startTracking() async {
    if (_isTracking) return;

    prefs = await SharedPreferences.getInstance();
    final userEmail = prefs.getString('email')?.trim();
    final token = prefs.getString('session_sid')?.trim();
    final siteUrl = dotenv.env['SITE_URL']?.trim() ?? '';

    if (userEmail == null || userEmail.isEmpty) {
      throw StateError(
        'Cannot start live tracking: signed-in email is missing.',
      );
    }
    if (token == null || token.isEmpty) {
      throw StateError(
        'Cannot start live tracking: Frappe session has expired.',
      );
    }
    if (siteUrl.isEmpty) {
      throw StateError(
        'Cannot start live tracking: SITE_URL is not configured.',
      );
    }

    try {
      await _startAndroidBackgroundService(userEmail, token, siteUrl);
      _isTracking = true;
      print('Live Location Tracking Started');
    } catch (e) {
      _isTracking = false;
      rethrow;
    }
  }

  /// Stops live tracking and the event geofence before local sign-out, so the
  /// native service does not keep uploading GPS under the previous user.
  static Future<void> stopForSignOut() async {
    await LiveLocationService().stopTracking();
    try {
      await GeofenceManager.instance.stopMonitoring();
    } catch (e) {
      print('Warning: Could not stop geofence monitoring: $e');
    }
  }

  /// Stop tracking live location by stopping the Android service.
  Future<void> stopTracking() async {
    _isTracking = false;

    try {
      await _stopAndroidBackgroundService();
    } catch (e) {
      print('Warning: Could not stop Android background service: $e');
    }

    print('Live Location Tracking Stopped');
  }

  Future<void> _startAndroidBackgroundService(
    String userId,
    String authToken,
    String siteUrl,
  ) async {
    try {
      final result = await platform.invokeMethod<String>(
        'startLocationTracking',
        {'userId': userId, 'authToken': authToken, 'siteUrl': siteUrl},
      );
      print('Android background service started: $result');
    } on PlatformException catch (e) {
      print('Failed to start Android service: ${e.message}');
      rethrow;
    }
  }

  Future<void> _stopAndroidBackgroundService() async {
    try {
      final result = await platform.invokeMethod<String>(
        'stopLocationTracking',
      );
      print('Android background service stopped: $result');
    } on PlatformException catch (e) {
      print('Failed to stop Android service: ${e.message}');
    }
  }

  Future<Map<String, dynamic>> getBatteryOptimizationStatus() async {
    try {
      final result = await platform.invokeMethod<Map<dynamic, dynamic>>(
        'isBatteryOptimized',
      );
      return Map<String, dynamic>.from(result ?? {});
    } on PlatformException catch (e) {
      print('Failed to check battery optimization: ${e.message}');
      return {};
    }
  }

  Future<void> openBatteryOptimizationSettings() async {
    try {
      await platform.invokeMethod<void>('openBatteryOptimizationSettings');
      print('Battery optimization settings opened');
    } on PlatformException catch (e) {
      print('Failed to open settings: ${e.message}');
    }
  }

  Future<bool> hasLocationPermissions() async {
    try {
      final result = await platform.invokeMethod<bool>(
        'hasLocationPermissions',
      );
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> requestLocationPermissions() async {
    try {
      final result = await platform.invokeMethod<bool>(
        'requestLocationPermissions',
      );
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> requestIgnoreBatteryOptimization() async {
    try {
      await platform.invokeMethod<void>('requestIgnoreBatteryOptimization');
    } on PlatformException catch (e) {
      print('Failed to request ignore battery optimization: ${e.message}');
    }
  }

  bool get isTracking => _isTracking;
}
