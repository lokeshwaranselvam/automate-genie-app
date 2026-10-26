import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'geofence_manager.dart';
import '../live_tracking_access.dart';
import 'location_permission_helper.dart';

class LiveLocationService {
  static final LiveLocationService _instance = LiveLocationService._internal();

  factory LiveLocationService() => _instance;

  LiveLocationService._internal();

  static const platform = MethodChannel('com.example.homegenieapp/tracking');

  bool _isTracking = false;
  Future<void> _trackingOperations = Future<void>.value();
  late SharedPreferences prefs;
  final String baseUrl = dotenv.env['URL'] ?? '';

  /// Start tracking live location through the Android foreground service.
  Future<void> startTracking() => _serialize(_startTracking);

  /// Restore tracking after a confirmed active attendance read, including when
  /// the native service has stopped while the Dart session stayed open.
  Future<void> ensureTracking() => _serialize(() async {
    final saved = await SharedPreferences.getInstance();
    if (saved.getBool('is_employee_checked_in') != true ||
        !await LiveTrackingAccess.canTrack()) {
      await _stopTracking();
      return;
    }
    final active = await platform.invokeMethod<bool>('isLocationTracking', {
      'userId': saved.getString('email')?.trim(),
      'authToken': saved.getString('token')?.trim(),
      'siteUrl': dotenv.env['SITE_URL']?.trim(),
    });
    if (active == true) {
      _isTracking = true;
      return;
    }
    await _startTracking();
  });

  Future<void> _startTracking() async {
    // Reconcile with native state even when Dart thinks tracking is active.
    // Android may have stopped the service since the last check-in.
    prefs = await SharedPreferences.getInstance();
    // Event screens may request a restart, but only today's employee
    // attendance can authorize the shared live-tracking service.
    if (prefs.getBool('is_employee_checked_in') != true) {
      await _stopTracking();
      return;
    }
    final userEmail = prefs.getString('email')?.trim();
    final sid = prefs.getString('session_sid')?.trim();
    final token = prefs.getString('token')?.trim();
    final siteUrl = dotenv.env['SITE_URL']?.trim() ?? '';

    if (userEmail == null || userEmail.isEmpty) {
      throw StateError(
        'Cannot start live tracking: signed-in email is missing.',
      );
    }
    if (sid == null || sid.isEmpty) {
      throw StateError(
        'Cannot start live tracking: Frappe session has expired.',
      );
    }
    if (token == null ||
        !RegExp(r'^token\s+[^\s:]+:[^\s:]+$').hasMatch(token)) {
      throw StateError(
        'Cannot start live tracking: API credentials are missing. Sign in again.',
      );
    }
    if (siteUrl.isEmpty) {
      throw StateError(
        'Cannot start live tracking: SITE_URL is not configured.',
      );
    }
    if (!await LiveTrackingAccess.canTrack()) {
      await _stopTracking();
      return;
    }

    try {
      await LocationPermissionHelper.requestBackgroundOnce();
      if (!await LiveTrackingAccess.canTrack() ||
          prefs.getString('email')?.trim() != userEmail ||
          prefs.getString('session_sid')?.trim() != sid ||
          prefs.getString('token')?.trim() != token ||
          dotenv.env['SITE_URL']?.trim() != siteUrl) {
        await _stopTracking();
        return;
      }
      await _startAndroidBackgroundService(userEmail, token, siteUrl);
      _isTracking = true;
      print('Live Location Tracking Started');
    } catch (e) {
      _isTracking = false;
      await _stopAndroidBackgroundService();
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
  Future<void> stopTracking() => _serialize(_stopTracking);

  Future<void> _stopTracking() async {
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
        {
          'userId': userId,
          'authToken': authToken,
          'siteUrl': siteUrl,
          'trackingAllowed': true,
        },
      );
      // The method-channel call only launches a service. Confirm that GPS
      // registration succeeded rather than reporting a silently stopped service.
      for (var attempt = 0; attempt < 15; attempt++) {
        if (await platform.invokeMethod<bool>('isLocationTracking') == true) {
          print('Android background service started: $result');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      throw StateError(
        'Android could not start live location updates. Check location permissions and retry.',
      );
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

  Future<void> _serialize(Future<void> Function() operation) {
    final result = _trackingOperations.then((_) => operation());
    _trackingOperations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }
}
