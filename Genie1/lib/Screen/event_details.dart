import '../utils/widget/pull_to_refresh.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:homegenie/Screen/login.dart';

import '../utils/api/event.dart';
import '../utils/event_location_selection.dart';
import '../utils/api/image_upload_api.dart';
import '../utils/api/session_auth.dart';
import '../utils/widget/camera_service.dart';
import '../utils/widget/gps_photo_stamper.dart';
import '../utils/widget/location_permission_helper.dart';
import '../utils/widget/glass_card.dart';
import '../utils/widget/geofence_manager.dart';
import '../utils/widget/warning.dart';
// Import geofence_service but hide conflicting types
import 'package:geofence_service/geofence_service.dart'
    hide LocationAccuracy, LocationPermission;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../utils/api/location_api.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:geolocator/geolocator.dart';
import 'package:phone_state/phone_state.dart';
import '../utils/widget/location_tracker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:homegenie/utils/api/check_in_out.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:homegenie/utils/widget/audio_recording_service.dart';
import 'package:homegenie/utils/widget/live_location_service.dart';
import '../utils/widget/home_back_button.dart';
import '../utils/widget/completed_visit_attachments.dart';

class EventDetails extends StatefulWidget {
  final String eventid;

  const EventDetails({super.key, required this.eventid});

  @override
  State<EventDetails> createState() => _EventDetailsState();
}

class _EventDetailsState extends State<EventDetails> {
  Map<String, dynamic> eventData = {};
  Map<String, String> _userFullNames = {};
  String? _participantVisitType;
  List<Map<String, dynamic>> _savedOpportunityLocations = [];
  String? _mapLocationType;
  Position? _employeeMapPosition;
  GoogleMapController? _customerMapController;
  List<LatLng> _customerRoutePoints = [];
  File? capturedImage;
  String? selectedLocationType;

  bool _isLoading = false;
  bool _isActionInProgress = false;
  bool _isLoadingDirections = false;
  bool _wasRecordingBeforeCall = false;
  bool _shouldStartNewRecordingAfterCall = false;

  bool _isRecording = false;

  // ── Photo capture ──────────────────────────────────────────────────────────
  final List<File> _capturedPhotos = [];
  bool _isUploadingPhoto = false;
  // Photos already uploaded to this Event for checkout.
  int _uploadedCheckoutPhotos = 0;

  // ── Geofence ───────────────────────────────────────────────────────────────
  final AudioPlayer _audioPlayer = AudioPlayer();
  late SharedPreferences prefs;

  @override
  void initState() {
    super.initState();
    _checkPing();
    _listenToPhoneState();
    GeofenceManager.initialize();
    unawaited(
      _requestLocationPermission().then((_) => _loadEmployeeMapPosition()),
    );
    _resumeLiveLocationIfCheckedIn();
  }

  /// Request location permission from user
  Future<void> _requestLocationPermission() async {
    try {
      // First request foreground location
      final status = await Permission.location.request();

      if (status.isDenied) {
        print("❌ Location permission denied");
      } else if (status.isGranted) {
        print("✅ Foreground location permission granted");

        // Background location is asked once per install, not on every
        // screen open; "While using the app" is enough for live tracking.
        await LocationPermissionHelper.requestBackgroundOnce();
      } else if (status.isPermanentlyDenied) {
        print(
          "⚠️ Location permission permanently denied - opening app settings",
        );
        openAppSettings();
      }
    } catch (e) {
      print("Error requesting location permission: $e");
    }
  }

  Future<void> _loadEmployeeMapPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      if (!mounted) return;
      setState(() => _employeeMapPosition = position);
      final mapLocationType =
          _mapLocationType ??
          (_getAvailableLocationTypes().isNotEmpty
              ? _getAvailableLocationTypes().first
              : null);
      final customerPoint = _getLocationCoordinates(mapLocationType);
      if (customerPoint != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _fitCustomerMapToMarkers(customerPoint);
        });
      }
    } catch (error) {
      debugPrint('Unable to get employee position for event map: $error');
    }
  }

  Future<void> _resumeLiveLocationIfCheckedIn() async {
    prefs = await SharedPreferences.getInstance();
    final bool withEvent = prefs.getBool('with_event') ?? false;
    if (withEvent) {
      // Employee already checked in, resume location tracking
      await LiveLocationService().startTracking();
      print(
        "📍 Resumed live location tracking for already checked-in employee",
      );
    }
  }

  Future<void> _startManualRecording() async {
    await AudioRecordingService().startRecording();
    setState(() {
      _isRecording = true;
    });
  }

  Future<void> _stopManualRecording() async {
    await AudioRecordingService().stopRecording();
    setState(() {
      _isRecording = false;
    });
  }

  void _listenToPhoneState() async {
    await Permission.phone.request();

    PhoneState.stream.listen((PhoneState state) async {
      final status = state.status;
      final recordingService = AudioRecordingService();

      if ((status == PhoneStateStatus.CALL_INCOMING ||
          status == PhoneStateStatus.CALL_STARTED)) {
        if (recordingService.isRecording && !recordingService.isPaused) {
          await recordingService.pauseRecording();
          _wasRecordingBeforeCall = true;
        }

        if (status == PhoneStateStatus.CALL_STARTED) {
          _shouldStartNewRecordingAfterCall = true;
        }
      } else if (status == PhoneStateStatus.CALL_ENDED &&
          _wasRecordingBeforeCall) {
        if (_shouldStartNewRecordingAfterCall) {
          await recordingService.stopRecording();

          final path = recordingService.lastRecordingPath;
          if (path != null && File(path).existsSync()) {
            final duration = await _getAudioDuration(path);
            if (duration.inSeconds < 1) {
              File(path).deleteSync();
            }
          }

          await recordingService.startRecording();
        } else {
          await recordingService.resumeRecording();
        }

        _wasRecordingBeforeCall = false;
        _shouldStartNewRecordingAfterCall = false;
      }
    });
  }

  Future<Duration> _getAudioDuration(String path) async {
    final player = AudioPlayer();
    try {
      await player.setFilePath(path);
      return player.duration ?? Duration.zero;
    } catch (_) {
      return Duration.zero;
    } finally {
      await player.dispose();
    }
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return "${twoDigits(d.inHours)}:$minutes:$seconds";
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    GeofenceManager.instance.stopMonitoring();
    super.dispose();
  }

  // ── Geofence ───────────────────────────────────────────────────────────────

  Future<void> _startGeofenceForEvent(double lat, double lng) async {
    if (!_requiresEventGeofence) return;

    GeofenceManager.instance.onStatusChange = (id, status) {
      if (!mounted) return;
      final msg =
          status == GeofenceStatus.ENTER
              ? '📍 You have entered the event zone.'
              : status == GeofenceStatus.EXIT
              ? '🚪 You have left the event zone.'
              : '⏱ You are still within the event zone.';

      Warning.show(
        context,
        msg,
        status == GeofenceStatus.ENTER
            ? 'Success'
            : status == GeofenceStatus.EXIT
            ? 'Warning'
            : 'Info',
      );
    };

    await GeofenceManager.instance.startMonitoring(
      eventId: widget.eventid,
      latitude: lat,
      longitude: lng,
      radiusMeters: 200,
    );
  }

  // ── Photo capture & upload ─────────────────────────────────────────────────

  Future<void> _capturePhotoForCheckout() async {
    final file = await CameraService.capturePhoto();
    if (file == null) return;

    setState(() {
      capturedImage = file;
      _capturedPhotos.add(file);
    });
  }

  void _removeCapturedPhotoAt(int index) {
    if (index < 0 || index >= _capturedPhotos.length) return;

    setState(() {
      final removedFile = _capturedPhotos.removeAt(index);
      if (capturedImage?.path == removedFile.path) {
        capturedImage =
            _capturedPhotos.isNotEmpty ? _capturedPhotos.last : null;
      }
    });
  }

  Future<File> _createGpsStampedImage({
    required File file,
    required double lat,
    required double lng,
    required String address,
  }) {
    return GpsPhotoStamper.stamp(
      file: file,
      lat: lat,
      lng: lng,
      address: address,
      title: 'Visit Check-out',
    );
  }

  /// Uploads pending checkout photos to the Event before the checkout call.
  /// Uploaded photos leave the pending list, so a retry only re-sends the
  /// ones that failed. Returns true once every photo is on the Event and at
  /// least one photo has been uploaded for this visit.
  Future<bool> _uploadCheckoutPhotosBeforeCheckout({
    required double lat,
    required double lng,
    required String address,
  }) async {
    if (_capturedPhotos.isEmpty) return _uploadedCheckoutPhotos > 0;

    if (mounted) setState(() => _isUploadingPhoto = true);

    final failed = <File>[];

    try {
      for (final file in List<File>.from(_capturedPhotos)) {
        File? stampedFile;
        try {
          stampedFile = await _createGpsStampedImage(
            file: file,
            lat: lat,
            lng: lng,
            address: address,
          );

          String? url = await ImageUploadApi.uploadImageToEventWithRetry(
            filePath: stampedFile.path,
            docname: widget.eventid,
            context: context,
          );

          if (url == null && stampedFile.path != file.path) {
            debugPrint(
              '[EventDetails] Retrying upload with original file: ${file.path}',
            );
            url = await ImageUploadApi.uploadImageToEventWithRetry(
              filePath: file.path,
              docname: widget.eventid,
              context: context,
            );
          }

          if (url != null) {
            _uploadedCheckoutPhotos++;
          } else {
            failed.add(file);
          }
        } catch (e) {
          debugPrint('[EventDetails] Photo upload failed for ${file.path}: $e');
          failed.add(file);
        } finally {
          if (stampedFile != null &&
              stampedFile.path != file.path &&
              stampedFile.existsSync()) {
            try {
              stampedFile.deleteSync();
            } catch (_) {}
          }
        }
      }

      if (mounted) {
        setState(() {
          _capturedPhotos
            ..clear()
            ..addAll(failed);
          capturedImage = failed.isEmpty ? null : failed.last;
        });
      }

      if (failed.isNotEmpty) {
        if (mounted) {
          Warning.show(
            context,
            '${failed.length} photo(s) could not be uploaded. Check your '
                'connection and tap Check-out again. You have not been checked out.',
            'Photo upload failed',
          );
        }
        return false;
      }
      return _uploadedCheckoutPhotos > 0;
    } finally {
      if (mounted) setState(() => _isUploadingPhoto = false);
    }
  }

  bool _useSavedEventLocation() {
    final event = eventData['event'];
    if (!eventHasCheckInLocation(
      event is Map ? event : const {},
      _savedOpportunityLocations,
    )) {
      Warning.show(
        context,
        'This event needs a saved location type (Home, Site or Others) and valid coordinates. Update its location before checking in.',
        'Location Required',
      );
      return false;
    }
    selectedLocationType = _getLocationOptionLabels().single;
    return true;
  }

  bool _isSiteVisitEvent() {
    const supportedCategories = <String>{
      'Site Visit',
      'Installation',
      'Complaint Visit',
    };

    final eventCategory =
        eventData['event']?['event_category']?.toString().trim() ?? '';
    return supportedCategories.contains(eventCategory);
  }

  Map<String, dynamic>? _getPrimaryParticipant() {
    final participants = eventData['reference_details'];
    if (participants is List && participants.isNotEmpty) {
      final first = participants.first;
      if (first is Map) {
        return Map<String, dynamic>.from(first);
      }
    }
    return null;
  }

  String _getParticipantReferenceDocname() => eventOpportunityName(eventData);

  String _getParticipantVisitType() {
    if (_participantVisitType != null && _participantVisitType!.isNotEmpty) {
      return _participantVisitType!;
    }

    final participant = _getPrimaryParticipant();
    final localVisitType = participant?['visit_type']?.toString();
    if (localVisitType != null && localVisitType.isNotEmpty) {
      return localVisitType;
    }

    return 'New';
  }

  bool _isNewVisit() => _getParticipantVisitType().toLowerCase() == 'new';

  bool _requiresLocationBeforeCheckout() {
    return _isSiteVisitEvent() && _isNewVisit();
  }

  bool _requiresPhotoBeforeCheckout() {
    // A photo is mandatory before checking out of any event.
    return true;
  }

  bool _hasCapturedCheckoutPhoto() {
    return _capturedPhotos.isNotEmpty || _uploadedCheckoutPhotos > 0;
  }

  bool _requiresLocationBeforeCheckIn() {
    return true;
  }

  List<String> _getAvailableLocationTypes() {
    if (_requiresLocationBeforeCheckIn()) {
      final labels = _getLocationOptionLabels();
      return labels
          .where((label) => _getLocationCoordinates(label) != null)
          .toList();
    }

    return ["Site", "Office", "Home"];
  }

  List<String> _getLocationOptionLabels() {
    if (_savedOpportunityLocations.length == 1) {
      return [
        eventLocationLabel(
          eventData['event'] is Map ? eventData['event'] : {},
          _savedOpportunityLocations,
        ),
      ];
    }
    final baseLabels =
        _savedOpportunityLocations.asMap().entries.map((entry) {
          final row = entry.value;
          final locationType = row['location_type']?.toString().trim() ?? '';
          if (locationType.isNotEmpty) return locationType;

          final location = row['location']?.toString().trim() ?? '';
          if (location.isNotEmpty) return location;

          return 'Customer Location ${entry.key + 1}';
        }).toList();

    final totals = <String, int>{};
    for (final label in baseLabels) {
      totals[label] = (totals[label] ?? 0) + 1;
    }

    final seen = <String, int>{};
    return baseLabels.map((label) {
      if (totals[label] == 1) return label;

      final index = (seen[label] ?? 0) + 1;
      seen[label] = index;
      return '$label ($index)';
    }).toList();
  }

  Map<String, dynamic>? _getSavedLocationRow(String? locationType) {
    if (locationType == null || locationType.isEmpty) return null;

    final labels = _getLocationOptionLabels();
    for (var index = 0; index < labels.length; index++) {
      if (labels[index] == locationType.trim()) {
        return _savedOpportunityLocations[index];
      }
    }
    return null;
  }

  LatLng? _getLocationCoordinates(String? locationType) {
    final savedRow = _getSavedLocationRow(locationType);
    return savedRow == null ? null : eventLocationCoordinates(savedRow);
  }

  Widget _buildCustomerLocationMap() {
    final locationTypes = _getAvailableLocationTypes();
    if (locationTypes.isEmpty) {
      return GlassCard(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              const Icon(Icons.location_off_outlined, color: Colors.black54),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _savedOpportunityLocations.isEmpty
                      ? 'The location selected for this event could not be found.'
                      : 'The saved customer location has no valid coordinates.',
                  style: const TextStyle(color: Colors.black54),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final locationType =
        locationTypes.contains(_mapLocationType)
            ? _mapLocationType!
            : locationTypes.first;
    final point = _getLocationCoordinates(locationType)!;
    final savedRow = _getSavedLocationRow(locationType);
    final markers = <Marker>{
      Marker(
        markerId: const MarkerId('customer-location'),
        position: point,
        infoWindow: InfoWindow(title: 'Customer: $locationType'),
      ),
    };
    final employeePosition = _employeeMapPosition;
    if (employeePosition != null) {
      markers.add(
        Marker(
          markerId: const MarkerId('employee-location'),
          position: LatLng(
            employeePosition.latitude,
            employeePosition.longitude,
          ),
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueAzure,
          ),
          infoWindow: const InfoWindow(title: 'Your current location'),
        ),
      );
    }

    return GlassCard(
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.location_on, color: BrandColors.ink),
                SizedBox(width: 8),
                Text(
                  'Customer Location',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              eventSavedLocationType(_visitEvent, _savedOpportunityLocations) ??
                  'Location type not saved',
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 6),
            Text(
              'Coordinates: ${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}',
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 270,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: GoogleMap(
                  key: ValueKey('${point.latitude},${point.longitude}'),
                  initialCameraPosition: CameraPosition(
                    target: point,
                    zoom: 16,
                  ),
                  markers: markers,
                  polylines:
                      _customerRoutePoints.length > 1
                          ? {
                            Polyline(
                              polylineId: const PolylineId(
                                'customer-bike-route',
                              ),
                              points: _customerRoutePoints,
                              color: BrandColors.ink,
                              width: 6,
                            ),
                          }
                          : const <Polyline>{},
                  zoomControlsEnabled: true,
                  zoomGesturesEnabled: true,
                  scrollGesturesEnabled: true,
                  rotateGesturesEnabled: true,
                  tiltGesturesEnabled: true,
                  mapToolbarEnabled: true,
                  myLocationButtonEnabled: false,
                  onMapCreated: (controller) {
                    _customerMapController = controller;
                    _fitCustomerMapToMarkers(point);
                  },
                ),
              ),
            ),
            if ((savedRow?['location']?.toString().trim().isNotEmpty ??
                false)) ...[
              const SizedBox(height: 10),
              Text(savedRow!['location'].toString()),
            ],
            const SizedBox(height: 4),
            Text(
              '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}',
              style: const TextStyle(color: Colors.black54, fontSize: 12),
            ),
            if (_customerRoutePoints.length > 1)
              Text(
                'Powered by Google, © ${DateTime.now().year}',
                style: const TextStyle(color: Colors.black54, fontSize: 11),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed:
                    _isLoadingDirections
                        ? null
                        : () => _getDirectionsToCustomer(point),
                icon:
                    _isLoadingDirections
                        ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(Icons.directions_outlined),
                label: const Text('Show Bike Route'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _fitCustomerMapToMarkers(LatLng customerPoint) async {
    final controller = _customerMapController;
    final employeePosition = _employeeMapPosition;
    if (controller == null) return;

    if (employeePosition == null) {
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(customerPoint, 16),
      );
      return;
    }

    final employeePoint = LatLng(
      employeePosition.latitude,
      employeePosition.longitude,
    );
    if ((employeePoint.latitude - customerPoint.latitude).abs() < 0.00001 &&
        (employeePoint.longitude - customerPoint.longitude).abs() < 0.00001) {
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(customerPoint, 16),
      );
      return;
    }

    final bounds = LatLngBounds(
      southwest: LatLng(
        math.min(employeePoint.latitude, customerPoint.latitude),
        math.min(employeePoint.longitude, customerPoint.longitude),
      ),
      northeast: LatLng(
        math.max(employeePoint.latitude, customerPoint.latitude),
        math.max(employeePoint.longitude, customerPoint.longitude),
      ),
    );
    try {
      await controller.animateCamera(CameraUpdate.newLatLngBounds(bounds, 56));
    } catch (error) {
      debugPrint('Unable to fit event map bounds: $error');
    }
  }

  Future<void> _getDirectionsToCustomer(LatLng customerPoint) async {
    if (!mounted) return;
    setState(() => _isLoadingDirections = true);
    try {
      if (!await _handleLocationPermission()) return;
      final employeePosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      final routePoints = await LocationHelper.getTwoWheelerRoute(
        origin: LatLng(employeePosition.latitude, employeePosition.longitude),
        destination: customerPoint,
      );
      if (!mounted) return;
      setState(() {
        _employeeMapPosition = employeePosition;
        _customerRoutePoints = routePoints;
      });
      if (routePoints.length > 1) {
        final latitudes = routePoints.map((point) => point.latitude);
        final longitudes = routePoints.map((point) => point.longitude);
        final minLatitude = latitudes.reduce((a, b) => a < b ? a : b);
        final maxLatitude = latitudes.reduce((a, b) => a > b ? a : b);
        final minLongitude = longitudes.reduce((a, b) => a < b ? a : b);
        final maxLongitude = longitudes.reduce((a, b) => a > b ? a : b);
        final bounds = LatLngBounds(
          southwest: LatLng(
            minLatitude - (maxLatitude - minLatitude < 0.00001 ? 0.00001 : 0),
            minLongitude -
                (maxLongitude - minLongitude < 0.00001 ? 0.00001 : 0),
          ),
          northeast: LatLng(
            maxLatitude + (maxLatitude - minLatitude < 0.00001 ? 0.00001 : 0),
            maxLongitude +
                (maxLongitude - minLongitude < 0.00001 ? 0.00001 : 0),
          ),
        );
        await _customerMapController?.animateCamera(
          CameraUpdate.newLatLngBounds(bounds, 48),
        );
      }
    } catch (error) {
      if (mounted) {
        Warning.show(
          context,
          'Could not show the bike route: '
              '${error.toString().replaceFirst('Exception: ', '')}',
          'Error',
        );
      }
    } finally {
      if (mounted) setState(() => _isLoadingDirections = false);
    }
  }

  // The API decides the exception; older responses keep geofencing enabled.
  bool get _requiresEventGeofence => eventData['requires_geofence'] != false;

  bool _isWithinAllowedLocation({
    required double currentLat,
    required double currentLng,
  }) {
    if (!_requiresEventGeofence) return true;

    final target = _getLocationCoordinates(selectedLocationType);
    if (target == null) {
      return false;
    }

    final distance = Geolocator.distanceBetween(
      currentLat,
      currentLng,
      target.latitude,
      target.longitude,
    );

    return distance <= 100;
  }

  void _resetSelectedLocation() {
    selectedLocationType = null;
  }

  Future<void> _loadOpportunityLocations() async {
    final referenceDocname = _getParticipantReferenceDocname();
    final rows =
        referenceDocname.isEmpty
            ? <Map<String, dynamic>>[]
            : await Event.getOpportunityLocations(
              referenceDocname: referenceDocname,
              context: context,
            );

    if (mounted) _applyEventLocations(rows);
  }

  void _applyEventLocations(List<Map<String, dynamic>> rows) {
    final event = eventData['event'];
    final selected = eventSelectedLocations(
      event is Map ? event : const {},
      rows,
    );
    setState(() {
      _savedOpportunityLocations = selected;
      final valid = _getAvailableLocationTypes();
      _mapLocationType = valid.isEmpty ? null : valid.single;
      debugPrint(
        '[EventDetails] location-v2: opportunityFound=${_getParticipantReferenceDocname().isNotEmpty}, '
        'rows=${rows.length}, selected=${selected.length}, coordinates=${valid.length}',
      );
    });
  }

  Future<void> performCheckIn({
    required String? userEmail,
    required String eventId,
    required double lat,
    required double lng,
    required String address,
  }) async {
    if (_requiresLocationBeforeCheckIn()) {
      if (!_useSavedEventLocation()) return;
      if (selectedLocationType == null) {
        Warning.show(
          context,
          'Please select a saved customer location before check-in.',
          'Location Required',
        );
        return;
      }

      if (_getLocationCoordinates(selectedLocationType) == null) {
        Warning.show(
          context,
          'The selected customer location has no valid coordinates. Add its coordinates before checking in.',
          'Location Required',
        );
        return;
      }

      if (!_isWithinAllowedLocation(currentLat: lat, currentLng: lng)) {
        Warning.show(
          context,
          'You must be within 100m of the selected customer location to check in.',
          'Location Restriction',
        );
        return;
      }
    }

    final response = await Event.eventCheckin(
      userEmail,
      eventId,
      lat,
      lng,
      address,
      context,
    );

    if (response['message'] != null) {
      if (response['message']['status'] == "success") {
        _applyLocalVisitStatus(
          checkIn: DateTime.now().toString().split('.').first,
        );
        await prefs.setBool('with_event', true);
        if (mounted) {
          Warning.show(
            context,
            response['message']['message']?.toString() ?? 'Checked in.',
            'Success',
          );
        }

        // Reflect the successful server update immediately. Tracking setup,
        // battery settings and the authoritative refresh continue separately.
        unawaited(_finishCheckInSetup(lat, lng));
        unawaited(_refreshVisitDetailsSilently());
      } else if (response['message']['status'] == "error") {
        if (mounted) {
          Warning.show(context, response['message']['message'], "Error");
        }
      } else if (mounted) {
        Warning.show(
          context,
          'ERP did not confirm that this visit was checked in.',
          'Check-in failed',
        );
      }
    } else if (mounted) {
      Warning.show(
        context,
        'The check-in request did not return a confirmation. Please refresh and try again.',
        'Check-in failed',
      );
    }
  }

  Future<void> _finishCheckInSetup(double lat, double lng) async {
    try {
      await LiveLocationService().startTracking();
    } catch (error) {
      debugPrint('Unable to start live location after check-in: $error');
    }

    try {
      await _startGeofenceForEvent(lat, lng);
    } catch (error) {
      debugPrint('Unable to start event geofence after check-in: $error');
    }
  }

  void _applyLocalVisitStatus({String? checkIn, String? checkOut}) {
    final updatedEvent = Map<String, dynamic>.from(_visitEvent);
    if (checkIn != null) updatedEvent['custom_check_in'] = checkIn;
    if (checkOut != null) updatedEvent['custom_check_out'] = checkOut;
    if (!mounted) return;
    setState(() {
      eventData = {...eventData, 'event': updatedEvent};
    });
  }

  Future<void> _refreshVisitDetailsSilently() async {
    if (!mounted) return;
    try {
      final response = await Event.eventdetails(widget.eventid, context);
      if (!mounted || response is! Map) return;

      final serverEventRaw = response['event'];
      if (serverEventRaw is! Map) return;
      final serverEvent = Map<String, dynamic>.from(serverEventRaw);
      final currentEvent = _visitEvent;

      // Avoid briefly reverting the visible check state if the list API is
      // slower than the successful check-in/check-out write.
      for (final field in ['custom_check_in', 'custom_check_out']) {
        final currentValue = currentEvent[field]?.toString() ?? '';
        final serverValue = serverEvent[field]?.toString() ?? '';
        if (currentValue.isNotEmpty && serverValue.isEmpty) {
          serverEvent[field] = currentValue;
        }
      }

      setState(() {
        eventData = {
          ...Map<String, dynamic>.from(response),
          'event': serverEvent,
        };
      });
      await _loadUserFullNames(response);
    } catch (error) {
      debugPrint('Unable to refresh visit details after status update: $error');
    }
  }

  Future<void> performCheckout({
    required String? userEmail,
    required String eventId,
    required double lat,
    required double lng,
    required String address,
    required String workingHrs,
    required Position position,
  }) async {
    LocationTrackerService.stopTracking();
    double distance = LocationTrackerService.calculateTotalDistance();

    String formattedDistanceWithUnit;

    if (distance >= 1000) {
      double km = distance / 1000;
      formattedDistanceWithUnit = '${km.toStringAsFixed(2)} km';
    } else {
      formattedDistanceWithUnit = '${distance.toStringAsFixed(2)} m';
    }

    List<LatLng> path = LocationTrackerService.getTrackedPoints();

    List<Map<String, dynamic>> locationLogs =
        path
            .map(
              (latLng) => {
                'latitude': latLng.latitude,
                'longitude': latLng.longitude,
              },
            )
            .toList();

    final lastLatLng = prefs.getString('last_lat_lng') ?? '';

    final response = await Event.eventCheckout(
      userEmail,
      eventId,
      lat,
      lng,
      address,
      workingHrs,
      formattedDistanceWithUnit,
      lastLatLng,
      jsonEncode(locationLogs),
      context,
      beforeCheckout: () async {
        if (!mounted) return false;
        final photosUploaded = await _uploadCheckoutPhotosBeforeCheckout(
          lat: lat,
          lng: lng,
          address: address,
        );
        if (!photosUploaded &&
            mounted &&
            _uploadedCheckoutPhotos == 0 &&
            _capturedPhotos.isEmpty) {
          Warning.show(context, 'Capture image before checkout', 'Warning');
        }
        return photosUploaded && mounted;
      },
    );
    if (response['cancelled'] == true) return;
    if (response['message'] != null) {
      if (response['message']['status'] == 'success') {
        await prefs.setBool('with_event', false);
        _applyLocalVisitStatus(
          checkOut: DateTime.now().toString().split('.').first,
        );
        if (mounted) {
          Warning.show(
            context,
            response['message']['message']?.toString() ?? 'Checked out.',
            'Success',
          );
        }

        // Show the completed state immediately; uploads and tracking cleanup
        // continue after the ERP check-out has succeeded.
        unawaited(
          _finishCheckoutAfterSuccess(
            eventId: eventId,
            lat: lat,
            lng: lng,
            address: address,
            position: position,
          ),
        );
        unawaited(_refreshVisitDetailsSilently());
      } else if (mounted) {
        Warning.show(
          context,
          response['message']['message']?.toString() ??
              'The visit could not be checked out.',
          'Check-out failed',
        );
      }
    } else if (mounted) {
      Warning.show(
        context,
        'The check-out request did not return a confirmation. Please refresh and try again.',
        'Check-out failed',
      );
    }
  }

  Future<void> _finishCheckoutAfterSuccess({
    required String eventId,
    required double lat,
    required double lng,
    required String address,
    required Position position,
  }) async {
    // Attendance check-in owns the day's live tracking. Only stop it here when
    // the employee is not checked in for the day, otherwise the rest of the
    // shift would go untracked after a single visit checkout.
    final attendanceCheckedIn =
        prefs.getBool('is_employee_checked_in') ?? false;
    if (!attendanceCheckedIn) {
      try {
        await LiveLocationService().stopTracking();
      } catch (error) {
        debugPrint('Unable to stop live location after checkout: $error');
      }
    }
    try {
      LocationTrackerService.startTracking(
        start: LatLng(position.latitude, position.longitude),
      );
    } catch (error) {
      debugPrint('Unable to restart location tracking after checkout: $error');
    }
    try {
      await prefs.setString('last_checkout_address', address);
      await prefs.setString('last_lat_lng', '$lat,$lng');
    } catch (error) {
      debugPrint('Unable to save checkout location locally: $error');
    }

    if (_requiresLocationBeforeCheckout()) {
      final referenceDocname = _getParticipantReferenceDocname();
      debugPrint(
        '[EventDetails] performCheckout save trigger -> '
        'event_id=$eventId, reference_docname=$referenceDocname',
      );
      if (referenceDocname.isNotEmpty) {
        try {
          await Event.saveCustomerLocationFromVisit(
            eventId: eventId,
            referenceDocname: referenceDocname,
            context: context,
          );
        } catch (error) {
          debugPrint('Unable to save visit customer location: $error');
        }
      }
    }

    try {
      if (AudioRecordingService().isRecording) {
        await AudioRecordingService().stopRecording();
      }
      final paths = AudioRecordingService().getAllRecordingPaths();
      for (final path in paths) {
        if (File(path).existsSync()) {
          await uploadAudioToERPNext(
            filePath: path,
            doctype: 'Event',
            docname: eventId,
            baseUrl: dotenv.env['SITE_URL'] ?? '',
          );
        } else {
          debugPrint('Skipping missing audio recording: $path');
        }
      }
      if (paths.isNotEmpty) AudioRecordingService().resetRecordings();
    } catch (error) {
      debugPrint('Unable to stop or upload visit audio after checkout: $error');
    }
  }

  Future<void> _checkPing() async {
    try {
      var connectivity = await Connectivity().checkConnectivity();

      bool noInternet = false;

      if (connectivity == ConnectivityResult.none) {
        noInternet = true;
      }

      if (connectivity.contains(ConnectivityResult.none)) {
        noInternet = true;
      }

      if (noInternet) {
        Warning.show(
          context,
          'No Internet Connection! Please check your network.',
          'Error',
        );
        return;
      }
      var pingResult = await Check.pingpong();
      if (pingResult == false) {
        Warning.show(
          context,
          'ERP Site is not in working condition! Please try again later.',
          'Error',
        );
      } else {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('token') ?? "";
        final email = prefs.getString('email') ?? "";

        final sessionValid = await Check.sessionActive(token, email);

        if (!sessionValid) {
          Warning.show(
            context,
            'Session expired. Please log in again.',
            'Error',
          );
          await LiveLocationService.stopForSignOut();
          await prefs.clear();
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const Login()),
            (route) => false,
          );
          return;
        }
        if (!mounted) return;
        setState(() {
          _isLoading = false;
        });
        _init();
      }
    } catch (e) {
      print('Error during ping: $e');
    }
  }

  Future<void> _init() async {
    prefs = await SharedPreferences.getInstance();
    await _fetchData();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _fetchData() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _resetSelectedLocation();
      _participantVisitType = null;
      _savedOpportunityLocations = [];
      _mapLocationType = null;
    });

    await Future.wait([_fetchEventDetails()]);

    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _loadParticipantVisitType() async {
    final participant = _getPrimaryParticipant();
    final referenceDocname = _getParticipantReferenceDocname();
    final referenceDoctype =
        participant?['reference_doctype']?.toString() ?? 'Opportunity';

    debugPrint(
      '[EventDetails] participant reference resolved -> '
      'reference_docname=$referenceDocname, reference_doctype=$referenceDoctype, '
      'participant=$participant',
    );

    if (referenceDocname.isEmpty) {
      debugPrint(
        '[EventDetails] No participant reference found. Defaulting visit type to New.',
      );
      if (mounted) {
        setState(() {
          _participantVisitType = 'New';
        });
      }
      return;
    }

    final visitType = await Event.getParticipantVisitType(
      eventName: widget.eventid,
      referenceDocname: referenceDocname,
      referenceDoctype: referenceDoctype,
      context: context,
    );

    if (mounted) {
      debugPrint(
        '[EventDetails] visit type resolved for ${widget.eventid}: '
        '${visitType ?? _getParticipantVisitType()}',
      );
      setState(() {
        _participantVisitType = visitType ?? _getParticipantVisitType();
      });
    }
  }

  String _calculateWorkingHours(String? checkIn, String? checkOut) {
    if (checkIn == null || checkOut == null) return "--:--";

    try {
      DateTime inTime = DateTime.parse(checkIn);
      DateTime outTime = DateTime.parse(checkOut);

      Duration difference = outTime.difference(inTime);

      int hours = difference.inHours;
      int minutes = difference.inMinutes.remainder(60);

      return "${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}";
    } catch (e) {
      return "--:--";
    }
  }

  Future<void> _fetchEventDetails() async {
    final response = await Event.eventdetails(widget.eventid, context);
    if (!mounted) return;
    if (response != Null) {
      setState(() {
        eventData = response;
      });
      // Show the Event's saved coordinate URL immediately. An ancillary user
      // or visit-type lookup must not prevent the map from being initialized.
      _applyEventLocations([]);
      await _loadOpportunityLocations();
      await _loadUserFullNames(response is Map ? response : {});
      await _loadParticipantVisitType();
    }
  }

  Future<void> _loadUserFullNames(Map response) async {
    final rawEvent = response['event'];
    if (rawEvent is! Map) return;
    final event = Map<String, dynamic>.from(rawEvent);
    final userIds = <String>{
      event['owner']?.toString().trim() ?? '',
      event['assigned_to']?.toString().trim() ?? '',
    }..removeWhere((id) => id.isEmpty || id.toLowerCase() == 'null');

    final resolved = <String, String>{};
    await Future.wait(
      userIds.map((userId) async {
        final fullName = await SessionAuthApi.getUserFullName(userId);
        if (fullName != null && fullName.isNotEmpty) {
          resolved[userId.toLowerCase()] = fullName;
        }
      }),
    );
    if (mounted && resolved.isNotEmpty) {
      setState(() => _userFullNames = {..._userFullNames, ...resolved});
    }
  }

  String _displayUserName(String userId) {
    final value = userId.trim();
    if (value.isEmpty) return value;
    return _userFullNames[value.toLowerCase()] ??
        (value.contains('@') ? 'User' : value);
  }

  Future<bool> _handleLocationPermission() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      Warning.show(context, 'Location services are disabled.', 'Error');
      return false;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        Warning.show(context, 'Location permission denied.', 'Error');
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      Warning.show(
        context,
        'Location permission permanently denied. Please enable it from settings.',
        'Error',
      );
      return false;
    }

    return true;
  }

  Future<void> uploadAudioToERPNext({
    required String filePath,
    required String doctype,
    required String docname,
    required String baseUrl,
  }) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? token = prefs.getString('token');

      if (token == null) {
        print("❌ No token found in SharedPreferences.");
        return;
      }

      String url = '$baseUrl/api/method/upload_file';
      var request = http.MultipartRequest('POST', Uri.parse(url));

      request.fields['doctype'] = doctype;
      request.fields['docname'] = docname;
      request.headers['Authorization'] = token;
      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          filePath,
          filename: 'event.mp3',
        ),
      );

      var response = await request.send();
      var responseData = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        var jsonResponse = jsonDecode(responseData);
        print("✅ File uploaded successfully: $jsonResponse");
      } else {
        print("❌ Upload failed: ${response.statusCode} - $responseData");
      }
    } catch (e) {
      print("❌ Upload error: $e");
    }
  }

  void launchDialer(String phoneNumber) async {
    final Uri dialUri = Uri(scheme: 'tel', path: phoneNumber);
    if (await canLaunchUrl(dialUri)) {
      await launchUrl(dialUri, mode: LaunchMode.externalApplication);
    } else {
      print('Cannot launch $dialUri');
    }
  }

  void openWhatsAppChat(String phoneNumber) async {
    final cleanedNumber = phoneNumber.replaceAll(RegExp(r'\D'), '');
    final formattedNumber =
        cleanedNumber.startsWith('91') ? cleanedNumber : '91$cleanedNumber';

    final uri = Uri.parse('whatsapp://send?phone=$formattedNumber');

    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      Warning.show(context, 'WhatsApp not installed or cannot open.', 'Error');
    }
  }

  bool _isTodayEvent() {
    final startsOn = eventData['event']?['starts_on']?.toString();
    if (startsOn == null || startsOn.isEmpty) {
      debugPrint(
        '[EventDetails] starts_on missing for event ${widget.eventid}: ${eventData['event']}',
      );
      return false;
    }

    try {
      final eventDate = DateTime.parse(startsOn);
      final today = DateTime.now();

      // Extract date only (ignore time) - like DATE() in SQL
      final eventDateOnly = DateTime(
        eventDate.year,
        eventDate.month,
        eventDate.day,
      );
      final todayOnly = DateTime(today.year, today.month, today.day);

      debugPrint(
        '[EventDetails] Comparing dates for event ${widget.eventid}: '
        'eventDate=$eventDateOnly, today=$todayOnly',
      );

      return eventDateOnly.isAtSameMomentAs(todayOnly);
    } catch (e) {
      debugPrint(
        '[EventDetails] invalid starts_on for event ${widget.eventid}: $startsOn, error=$e',
      );
      return false;
    }
  }

  Future<Position> _getCurrentVisitPosition() async {
    final cached = _employeeMapPosition;
    if (cached != null) {
      final age = DateTime.now().difference(cached.timestamp);
      if (!age.isNegative &&
          age <= const Duration(seconds: 15) &&
          cached.accuracy <= 50) {
        return cached;
      }
    }

    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
    if (mounted) setState(() => _employeeMapPosition = position);
    return position;
  }

  Future<void> _handleVisitCheckInOut() async {
    if (_isActionInProgress) return;
    setState(() => _isActionInProgress = true);
    var timeoutStage = 'GPS location lookup';
    try {
      if (!_isTodayEvent()) {
        Warning.show(
          context,
          'You can only check in/out on the event day.',
          'Invalid Date',
        );
        return;
      }

      final event = _visitEvent;
      final checkIn = event['custom_check_in']?.toString().trim() ?? '';
      final checkOut = event['custom_check_out']?.toString().trim() ?? '';
      final startingVisit = checkIn.isEmpty && checkOut.isEmpty;
      final endingVisit = checkIn.isNotEmpty && checkOut.isEmpty;
      if (!startingVisit && !endingVisit) {
        Warning.show(
          context,
          'This visit is already complete.',
          'Visit complete',
        );
        return;
      }

      // A visit check-in is only allowed after the employee's attendance
      // check-in for the day, verified against the server's current status.
      if (startingVisit) {
        timeoutStage = 'attendance status check';
        final blockReason = await Check.eventCheckinBlockReason(
          prefs.getString('email'),
        );
        if (blockReason != null) {
          if (mounted) {
            Warning.show(context, blockReason, 'Employee Check-in required');
          }
          return;
        }
        timeoutStage = 'GPS location lookup';
      }

      // Use only the location saved when creating the Event; no chooser.
      if (startingVisit &&
          _requiresLocationBeforeCheckIn() &&
          !_useSavedEventLocation()) {
        return;
      }
      if (endingVisit &&
          _requiresPhotoBeforeCheckout() &&
          !_hasCapturedCheckoutPhoto()) {
        Warning.show(context, 'Capture image before checkout', 'Warning');
        return;
      }
      if (endingVisit &&
          _requiresLocationBeforeCheckout() &&
          !_useSavedEventLocation()) {
        return;
      }

      if (!await _handleLocationPermission()) return;

      final position = await _getCurrentVisitPosition();
      final fallbackAddress =
          'Coordinates: ${position.latitude}, ${position.longitude}';
      final address = await LocationHelper.getAddressFromCoordinates(
        position.latitude,
        position.longitude,
      ).timeout(const Duration(seconds: 4), onTimeout: () => fallbackAddress);

      if (startingVisit) {
        timeoutStage = 'ERP check-in request';
        await performCheckIn(
          userEmail: prefs.getString('email'),
          eventId: widget.eventid,
          lat: position.latitude,
          lng: position.longitude,
          address:
              address.isEmpty || address.startsWith('Error')
                  ? fallbackAddress
                  : address,
        );
      } else {
        timeoutStage = 'ERP check-out request';
        await performCheckout(
          userEmail: prefs.getString('email'),
          eventId: widget.eventid,
          lat: position.latitude,
          lng: position.longitude,
          address:
              address.isEmpty || address.startsWith('Error')
                  ? fallbackAddress
                  : address,
          workingHrs: _calculateWorkingHours(
            checkIn,
            DateTime.now().toString(),
          ),
          position: position,
        );
      }
    } on TimeoutException {
      if (mounted) {
        Warning.show(
          context,
          '$timeoutStage did not finish in time. Please try again.',
          '$timeoutStage timed out',
        );
      }
    } catch (error) {
      debugPrint('Visit check-in/out failed: $error');
      if (mounted) {
        Warning.show(context, error.toString(), 'Error');
      }
    } finally {
      if (mounted) setState(() => _isActionInProgress = false);
    }
  }

  Map<String, dynamic> get _visitEvent {
    final event = eventData['event'];
    return event is Map ? Map<String, dynamic>.from(event) : {};
  }

  List<Map<String, dynamic>> get _visitParticipants {
    final raw = eventData['reference_details'];
    if (raw is! List) return [];
    return raw.whereType<Map>().map(Map<String, dynamic>.from).toList();
  }

  String _visitField(String key, {String fallback = ''}) {
    final value = _visitEvent[key]?.toString().trim() ?? '';
    return value.isEmpty || value.toLowerCase() == 'null' ? fallback : value;
  }

  String get _visitCustomer {
    final participants = _visitParticipants;
    final party =
        participants.isNotEmpty
            ? participants.first['party_name']?.toString().trim() ?? ''
            : '';
    return party.isNotEmpty
        ? party
        : _visitField('subject', fallback: 'Site Visit');
  }

  bool get _visitCheckedIn =>
      (_visitEvent['custom_check_in']?.toString().trim() ?? '').isNotEmpty;

  bool get _visitCheckedOut =>
      (_visitEvent['custom_check_out']?.toString().trim() ?? '').isNotEmpty;

  Widget _detailInfo(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(
              label,
              style: const TextStyle(color: Colors.black54, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: const TextStyle(
                color: Color(0xFF202B3C),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _capturedPhotoTile(int index) {
    final file = _capturedPhotos[index];
    return Stack(
      children: [
        Container(
          width: 84,
          height: 84,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            image: DecorationImage(image: FileImage(file), fit: BoxFit.cover),
          ),
        ),
        Positioned(
          top: 3,
          right: 11,
          child: InkWell(
            onTap: () => _removeCapturedPhotoAt(index),
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, color: Colors.white, size: 14),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showVisitChecklist() async {
    final checkIn = _visitEvent['custom_check_in']?.toString() ?? '';
    final checkOut = _visitEvent['custom_check_out']?.toString() ?? '';
    final items = <(String, bool, String)>[
      ('Site visit started', checkIn.isNotEmpty, checkIn),
      (
        'Photos captured',
        _capturedPhotos.isNotEmpty ||
            (_visitCheckedOut && _requiresPhotoBeforeCheckout()),
        _capturedPhotos.isNotEmpty
            ? '${_capturedPhotos.length} photo(s) ready'
            : '',
      ),
      ('Customer location verified', _visitCheckedIn, ''),
      ('Site visit completed', checkOut.isNotEmpty, checkOut),
    ];
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder:
          (context) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Visit checklist',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
                for (final item in items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      item.$2
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: item.$2 ? BrandColors.ink : Colors.black26,
                    ),
                    title: Text(item.$1),
                    subtitle: item.$3.isEmpty ? null : Text(item.$3),
                  ),
              ],
            ),
          ),
    );
  }

  Widget _visitInfoPair(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.black54, fontSize: 11),
          ),
          const SizedBox(height: 3),
          Text(
            value.isEmpty ? '—' : value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF202B3C),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _visitChecklistRow(String label, bool checked) {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Checkbox(
              value: checked,
              onChanged: null,
              activeColor: BrandColors.ink,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: checked ? const Color(0xFF202B3C) : Colors.black54,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final checkedIn = _visitCheckedIn;
    final checkedOut = _visitCheckedOut;
    final due = DateTime.tryParse(_visitField('starts_on'))?.toLocal();
    final participants = _visitParticipants;
    final participant =
        participants.isEmpty ? <String, dynamic>{} : participants.first;
    final customer = _visitCustomer;
    final subject = _visitField('subject', fallback: 'Site Visit');
    final department = _visitField(
      'department',
      fallback: participant['department']?.toString() ?? '',
    );
    final assignedTo = _displayUserName(
      _visitField('assigned_to', fallback: _visitField('owner')),
    );
    final description =
        _visitField('description')
            .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
            .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n')
            .replaceAll(RegExp(r'<[^>]*>'), '')
            .trim();
    final completedChecklistCount =
        [
          checkedIn,
          _capturedPhotos.isNotEmpty ||
              (checkedOut && _requiresPhotoBeforeCheckout()),
          checkedIn,
          checkedOut,
        ].where((value) => value).length;
    final priority = _visitField('priority', fallback: 'Normal');

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: brandAppBar(
        leading: const HomeBackButton(color: Colors.white),
        elevation: 0,
        title: const Text(
          'Task Details',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body:
          _isLoading
              ? const Center(child: AgPathLoadingIndicator())
              : PullToRefresh(
                onRefresh: () async {
                  await _checkPing();
                  await _fetchData();
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                  children: [
                    Text(
                      subject,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF202B3C),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color:
                                priority.toLowerCase() == 'high' ||
                                        priority.toLowerCase() == 'urgent'
                                    ? const Color(0xFFFFE8E8)
                                    : const Color(0xFFEAF3FF),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            priority,
                            style: TextStyle(
                              color:
                                  priority.toLowerCase() == 'high' ||
                                          priority.toLowerCase() == 'urgent'
                                      ? const Color(0xFFD94343)
                                      : BrandColors.ink,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          due == null
                              ? 'Due date not set'
                              : '${DateUtils.isSameDay(due, DateTime.now()) ? 'Due Today' : DateFormat('d MMM').format(due)} • ${DateFormat('hh:mm a').format(due)}',
                          style: const TextStyle(
                            color: Color(0xFF7B8492),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Card(
                      margin: EdgeInsets.zero,
                      color: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: _visitInfoPair('Customer', customer),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: _visitInfoPair(
                                    checkedOut
                                        ? 'Visit Category'
                                        : 'Department',
                                    checkedOut
                                        ? _visitField(
                                          'event_category',
                                          fallback: _visitField(
                                            'custom_event_category',
                                          ),
                                        )
                                        : department,
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              children: [
                                Expanded(
                                  child: _visitInfoPair(
                                    'Assigned To',
                                    assignedTo,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: _visitInfoPair(
                                    'Visit Type',
                                    _visitField('event_type'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Description',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF202B3C),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      description.isEmpty
                          ? 'No description provided.'
                          : description,
                      style: const TextStyle(
                        color: Color(0xFF4E5968),
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 17),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Checklist ($completedChecklistCount/4)',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF202B3C),
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _showVisitChecklist,
                          child: const Text('View All'),
                        ),
                      ],
                    ),
                    _visitChecklistRow('Site visit started', checkedIn),
                    _visitChecklistRow(
                      'Photos captured',
                      _capturedPhotos.isNotEmpty ||
                          _uploadedCheckoutPhotos > 0 ||
                          (checkedOut && _requiresPhotoBeforeCheckout()),
                    ),
                    _visitChecklistRow('Customer location verified', checkedIn),
                    _visitChecklistRow('Site visit completed', checkedOut),
                    const Divider(height: 20),
                    if (checkedOut)
                      CompletedVisitAttachments(
                        key: ValueKey(widget.eventid),
                        eventId: widget.eventid,
                      )
                    else ...[
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Attachments (${_capturedPhotos.length})',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF202B3C),
                              ),
                            ),
                          ),
                          if (_isUploadingPhoto)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 82,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            for (var i = 0; i < _capturedPhotos.length; i++)
                              _capturedPhotoTile(i),
                            if (checkedIn && !checkedOut)
                              SizedBox(
                                width: 82,
                                height: 82,
                                child: OutlinedButton(
                                  onPressed:
                                      _isUploadingPhoto
                                          ? null
                                          : _capturePhotoForCheckout,
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(
                                      color: Color(0xFFDCE2E8),
                                    ),
                                    shape: const StadiumBorder(),
                                  ),
                                  child: const Icon(
                                    Icons.add_rounded,
                                    color: BrandColors.ink,
                                    size: 28,
                                  ),
                                ),
                              ),
                            if (_capturedPhotos.isEmpty &&
                                (!checkedIn || checkedOut))
                              const Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'No attachments yet',
                                  style: TextStyle(
                                    color: Color(0xFF7B8492),
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                    if (checkedIn &&
                        !checkedOut &&
                        _requiresPhotoBeforeCheckout()) ...[
                      const SizedBox(height: 5),
                      const Text(
                        'Capture the required visit photo(s) before checking out.',
                        style: TextStyle(
                          color: Color(0xFF7B8492),
                          fontSize: 11,
                        ),
                      ),
                    ],
                    if (checkedIn && !checkedOut) ...[
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _isRecording
                                  ? 'Recording visit audio'
                                  : 'Visit audio recording',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (_isRecording)
                            StreamBuilder<Duration>(
                              stream:
                                  AudioRecordingService()
                                      .timerService
                                      .timerStream,
                              builder:
                                  (context, snapshot) => Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: Text(
                                      _formatDuration(
                                        snapshot.data ?? Duration.zero,
                                      ),
                                    ),
                                  ),
                            ),
                          IconButton(
                            tooltip:
                                _isRecording
                                    ? 'Stop recording'
                                    : 'Start recording',
                            onPressed:
                                _isRecording
                                    ? _stopManualRecording
                                    : _startManualRecording,
                            icon: Icon(
                              _isRecording
                                  ? Icons.stop_circle_outlined
                                  : Icons.mic_none_rounded,
                              color:
                                  _isRecording ? Colors.red : BrandColors.ink,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 10),
                    Card(
                      margin: EdgeInsets.zero,
                      color: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: ExpansionTile(
                        title: const Text(
                          'Details',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          14,
                          0,
                          14,
                          16,
                        ),
                        children: [
                          _detailInfo('Visit ID', _visitField('name')),
                          _detailInfo(
                            'Contact',
                            participant['contact_mobile']?.toString() ?? '',
                          ),
                          _detailInfo(
                            'Location',
                            eventSavedLocationType(
                                  _visitEvent,
                                  _savedOpportunityLocations,
                                ) ??
                                'Not specified',
                          ),
                          _detailInfo(
                            'Event Owner',
                            _displayUserName(_visitField('owner')),
                          ),
                          _buildCustomerLocationMap(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed:
                      !checkedIn && !checkedOut && !_isActionInProgress
                          ? _handleVisitCheckInOut
                          : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: BrandColors.ink,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor:
                        checkedIn ? const Color(0xFFE8F6EF) : Colors.black12,
                    disabledForegroundColor:
                        checkedIn ? const Color(0xFF219653) : Colors.black45,
                    minimumSize: const Size.fromHeight(46),
                    shape: const StadiumBorder(),
                  ).copyWith(backgroundBuilder: BrandColors.buttonBackground),
                  child: const Text(
                    'Check In',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: ElevatedButton(
                  onPressed:
                      checkedIn && !checkedOut && !_isActionInProgress
                          ? _handleVisitCheckInOut
                          : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: BrandColors.ink,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor:
                        checkedOut ? const Color(0xFFE8F6EF) : Colors.black12,
                    disabledForegroundColor:
                        checkedOut ? const Color(0xFF219653) : Colors.black45,
                    minimumSize: const Size.fromHeight(46),
                    shape: const StadiumBorder(),
                  ).copyWith(backgroundBuilder: BrandColors.buttonBackground),
                  child:
                      _isActionInProgress
                          ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                          : const Text(
                            'Check Out',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RecordingWaveAnimation extends StatefulWidget {
  final bool isRecording;

  const RecordingWaveAnimation({super.key, required this.isRecording});

  @override
  _RecordingWaveAnimationState createState() => _RecordingWaveAnimationState();
}

class _RecordingWaveAnimationState extends State<RecordingWaveAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<Animation<double>> _barAnimations;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);

    _barAnimations = List.generate(5, (index) {
      final delay = index * 0.1;
      return Tween<double>(begin: 5, end: 20).animate(
        CurvedAnimation(
          parent: _controller,
          curve: Interval(delay, 1.0, curve: Curves.easeInOut),
        ),
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant RecordingWaveAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRecording && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isRecording && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children:
                _barAnimations.map((anim) {
                  return Container(
                    width: 6,
                    height: anim.value,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: Colors.grey,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }).toList(),
          );
        },
      ),
    );
  }
}
