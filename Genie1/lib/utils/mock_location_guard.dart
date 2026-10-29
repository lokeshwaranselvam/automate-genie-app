import 'package:geolocator/geolocator.dart';

const mockLocationMessage =
    'A mock location app is active on this phone. Turn it off in Developer '
    'options and try again.';

/// Rejects a fix supplied by a mock-location app before it is used for
/// attendance, geofence or visit check-in decisions.
Position requireRealPosition(Position position) {
  if (position.isMocked) throw StateError(mockLocationMessage);
  return position;
}
