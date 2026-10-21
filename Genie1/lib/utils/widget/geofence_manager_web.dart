import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:geofence_service/geofence_service.dart' show GeofenceStatus;
import '../platform/browser_notifications.dart';

/// The same event radius, monitored only while browser GPS can execute.
class GeofenceManager {
  GeofenceManager._();
  static final instance = GeofenceManager._();
  StreamSubscription<Position>? _stream;
  Timer? _dwell;
  bool? _inside;
  bool get isRunning => _stream != null;
  void Function(String eventId, GeofenceStatus status)? onStatusChange;
  static Future<void> initialize() async {}
  Future<void> startMonitoring({
    required String eventId,
    required double latitude,
    required double longitude,
    double radiusMeters = 200,
  }) async {
    await stopMonitoring();
    _stream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(
      (position) {
        if (position.isMocked || position.accuracy > 100) return;
        final inside =
            Geolocator.distanceBetween(
              latitude,
              longitude,
              position.latitude,
              position.longitude,
            ) <=
            radiusMeters;
        if (inside == _inside) return;
        _inside = inside;
        _dwell?.cancel();
        final status = inside ? GeofenceStatus.ENTER : GeofenceStatus.EXIT;
        onStatusChange?.call(eventId, status);
        unawaited(
          showBrowserNotification(
            inside ? 'Entered Event Zone' : 'Left Event Zone',
            inside
                ? 'You have entered the event location area.'
                : 'You have left the event location area.',
          ),
        );
        if (inside) {
          _dwell = Timer(const Duration(seconds: 60), () {
            if (_inside == true && isRunning)
              {
              onStatusChange?.call(eventId, GeofenceStatus.DWELL);
              unawaited(showBrowserNotification('Still in Event Zone', 'You are still within the event location area.'));
            }
          });
        }
      },
      onError: (Object _) {
        unawaited(stopMonitoring());
      },
    );
  }

  Future<void> stopMonitoring() async {
    _dwell?.cancel();
    _dwell = null;
    final stream = _stream;
    _stream = null;
    _inside = null;
    await stream?.cancel();
  }
}
