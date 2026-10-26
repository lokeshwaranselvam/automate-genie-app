import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../live_tracking_access.dart';

/// Background ("Allow all the time") location is optional: live tracking runs
/// as a foreground service with "While using the app". Android shows the
/// background prompt again on every request while it is not granted, so ask
/// for it only once per install.
class LocationPermissionHelper {
  LocationPermissionHelper._();

  static const _backgroundRequestedKey = 'background_location_requested_v1';

  static Future<void> requestBackgroundOnce() async {
    try {
      if (!await LiveTrackingAccess.canTrack()) return;
      if (await Permission.locationAlways.isGranted) return;
      if (!await Permission.location.isGranted) return;

      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_backgroundRequestedKey) == true) return;
      await prefs.setBool(_backgroundRequestedKey, true);

      final status = await Permission.locationAlways.request();
      debugPrint('Background location permission: ${status.name}');
    } catch (e) {
      debugPrint('Background location request failed: $e');
    }
  }
}
