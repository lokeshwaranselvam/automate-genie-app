import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Registered in both the UI engine and Firebase's background Flutter engine.
class EventAssignmentAlarm {
  static const _channel = MethodChannel(
    'ai.automategenie/event_assignment_alarm',
  );

  /// Returns false when Android cannot start playback; callers can fall back
  /// to an alarm-stream notification. Does not change any device volume.
  static Future<bool> play() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await _channel.invokeMethod<bool>('play') == true;
    } on PlatformException catch (error) {
      debugPrint('Event alarm service unavailable: ${error.code}');
      return false;
    } on MissingPluginException {
      debugPrint('Event alarm service is not registered in this engine.');
      return false;
    }
  }
}
