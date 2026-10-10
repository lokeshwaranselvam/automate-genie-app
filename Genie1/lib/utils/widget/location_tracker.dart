import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class LocationTrackerService {
  static final List<LatLng> _locationPoints = [];
  static LatLng? _startPoint;
  static final bool _isTracking = false;
  static LatLng? getStartPoint() => _startPoint;
  static List<LatLng> getTrackedPoints() => List.unmodifiable(_locationPoints);

  static bool get isTracking => _isTracking;

  static Future<void> startTracking({required LatLng start}) async {
    _startPoint = start;
    _locationPoints.clear();
  }

  static Future<void> stopTracking() async {
    print("🛑 BG Tracking stopped");
  }

  static double calculateTotalDistance() {
    double totalDistance = 0.0;
    for (int i = 0; i < _locationPoints.length - 1; i++) {
      final segment = Geolocator.distanceBetween(
        _locationPoints[i].latitude,
        _locationPoints[i].longitude,
        _locationPoints[i + 1].latitude,
        _locationPoints[i + 1].longitude,
      );
      if (segment >= 5) {
        totalDistance += segment;
      }
    }
    print("📏 Total distance: $totalDistance meters");
    return totalDistance;
  }


  static void clear() {
    _locationPoints.clear();
    _startPoint = null;
  }
}
