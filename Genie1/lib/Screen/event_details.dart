import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:homegenie/Screen/login.dart';

import '../utils/api/event.dart';
import '../utils/api/image_upload_api.dart';
import '../utils/api/session_auth.dart';
import '../utils/widget/camera_service.dart';
import '../utils/widget/glass_card.dart';
import '../utils/widget/geofence_manager.dart';
import '../utils/widget/warning.dart';
// Import geofence_service but hide conflicting types
import 'package:geofence_service/geofence_service.dart'
    hide LocationAccuracy, LocationPermission;
import 'package:flutter/services.dart';
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
import 'package:homegenie/utils/widget/battery_optimization_helper.dart';
import '../utils/widget/home_back_button.dart';

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

        // Then request background location for persistent tracking
        final backgroundStatus = await Permission.locationAlways.request();

        if (backgroundStatus.isGranted) {
          print(
            "✅ Background location permission granted - TRACKING WILL WORK EVEN WHEN APP CLOSED",
          );
        } else if (backgroundStatus.isDenied) {
          print(
            "⚠️ Background location denied - tracking may stop when app closes",
          );
        }
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

  String _formatCapturedOn(DateTime dateTime) {
    final day = dateTime.day.toString().padLeft(2, '0');
    final month = dateTime.month.toString().padLeft(2, '0');
    final year = dateTime.year.toString();
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$day-$month-$year $hour:$minute';
  }

  String _buildGpsStampText({
    required DateTime capturedOn,
    required double lat,
    required double lng,
    required String address,
  }) {
    final normalizedAddress = address.replaceAll(RegExp(r'\s+'), ' ').trim();
    return 'Captured on: ${_formatCapturedOn(capturedOn)}\n'
        'Latitude: ${lat.toStringAsFixed(6)}\n'
        'Longitude: ${lng.toStringAsFixed(6)}\n'
        'Address: $normalizedAddress';
  }

  TextPainter _buildGpsTextPainter({
    required String text,
    required double maxWidth,
    required double maxHeight,
  }) {
    for (double fontSize = 18; fontSize >= 10; fontSize -= 1) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            height: 1.12,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
        maxLines: 6,
        ellipsis: '...',
      )..layout(maxWidth: maxWidth);

      if (painter.height <= maxHeight) {
        return painter;
      }
    }

    return TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1.12,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
      maxLines: 6,
      ellipsis: '...',
    )..layout(maxWidth: maxWidth);
  }

  Future<File> _createGpsStampedImage({
    required File file,
    required double lat,
    required double lng,
    required String address,
  }) async {
    final bytes = await file.readAsBytes();
    final ui.Image originalImage = await decodeImageFromList(bytes);
    final capturedOn = await file.lastModified();
    final Uint8List? mapBytes = await LocationHelper.getStaticMapImageBytes(
      lat,
      lng,
    );
    ui.Image? mapImage;

    if (mapBytes != null) {
      mapImage = await decodeImageFromList(mapBytes);
    }

    const maxOutputDimension = 960.0;
    final scale =
        math.max(originalImage.width, originalImage.height) > maxOutputDimension
            ? maxOutputDimension /
                math.max(originalImage.width, originalImage.height)
            : 1.0;
    final int targetWidth =
        math.max(1, (originalImage.width * scale).round()).toInt();
    final int targetHeight =
        math.max(1, (originalImage.height * scale).round()).toInt();

    final stampText = _buildGpsStampText(
      capturedOn: capturedOn,
      lat: lat,
      lng: lng,
      address: address,
    );

    final footerHeight = math.max(120.0, targetHeight * 0.28);
    final footerTop = targetHeight.toDouble() - footerHeight;
    final horizontalPadding = targetWidth * 0.02;
    final verticalPadding = footerHeight * 0.08;
    final mapSize =
        mapImage == null
            ? 0.0
            : math.min(
              footerHeight - (verticalPadding * 2),
              targetWidth * 0.26,
            );
    final textStartX =
        mapImage == null
            ? horizontalPadding
            : horizontalPadding + mapSize + horizontalPadding;
    final textWidth = math.max(
      1.0,
      targetWidth.toDouble() - textStartX - horizontalPadding,
    );
    final textHeight = math.max(1.0, footerHeight - (verticalPadding * 2));
    final textPainter = _buildGpsTextPainter(
      text: stampText,
      maxWidth: textWidth,
      maxHeight: textHeight,
    );

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawImageRect(
      originalImage,
      Rect.fromLTWH(
        0,
        0,
        originalImage.width.toDouble(),
        originalImage.height.toDouble(),
      ),
      Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
      Paint(),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, footerTop, targetWidth.toDouble(), footerHeight),
      Paint()..color = Colors.black.withOpacity(0.70),
    );

    if (mapImage != null) {
      final mapRect = Rect.fromLTWH(
        horizontalPadding,
        footerTop + verticalPadding,
        mapSize,
        mapSize,
      );
      canvas.drawRect(
        mapRect.inflate(2),
        Paint()..color = Colors.white.withOpacity(0.95),
      );
      paintImage(
        canvas: canvas,
        rect: mapRect,
        image: mapImage,
        fit: BoxFit.cover,
      );
    }

    final safeTextTop = math.max(
      footerTop + verticalPadding,
      footerTop + ((footerHeight - textPainter.height) / 2),
    );

    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(textStartX, footerTop, textWidth, footerHeight),
    );
    textPainter.paint(canvas, Offset(textStartX, safeTextTop));
    canvas.restore();

    final stampedImage = await recorder.endRecording().toImage(
      targetWidth,
      targetHeight,
    );
    final byteData = await stampedImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    final stampedBytes = byteData?.buffer.asUint8List();

    if (stampedBytes == null) {
      return file;
    }

    final stampedPath = file.path.replaceFirst(
      RegExp(r'(\.[^.]*)?$'),
      '_gps.png',
    );
    final stampedFile = File(stampedPath);
    await stampedFile.writeAsBytes(stampedBytes, flush: true);
    return stampedFile;
  }

  Future<void> _uploadCapturedPhotosAfterCheckout({
    required double lat,
    required double lng,
    required String address,
  }) async {
    if (_capturedPhotos.isEmpty) return;

    if (mounted) setState(() => _isUploadingPhoto = true);

    int successCount = 0;

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
            successCount++;
          }
        } catch (e) {
          debugPrint('[EventDetails] Photo upload failed for ${file.path}: $e');
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
        Warning.show(
          context,
          successCount == _capturedPhotos.length
              ? 'Photo uploaded to Event successfully!'
              : 'Uploaded $successCount/${_capturedPhotos.length} photos. Some photos failed to upload.',
          successCount == _capturedPhotos.length ? 'Success' : 'Warning',
        );
      }

      if (successCount == _capturedPhotos.length && mounted) {
        setState(() {
          _capturedPhotos.clear();
          capturedImage = null;
        });
      }
    } finally {
      if (mounted) setState(() => _isUploadingPhoto = false);
    }
  }

  void showLocationDialog(VoidCallback onSuccess) {
    String? tempSelectedLocationType = selectedLocationType;
    final locationOptions = _getAvailableLocationTypes();

    if (_requiresLocationBeforeCheckIn() && locationOptions.isEmpty) {
      Warning.show(
        context,
        'No saved customer location has valid coordinates. Add a customer location before checking in.',
        'Location Required',
      );
      return;
    }

    if (locationOptions.length == 1) {
      setState(() {
        selectedLocationType = locationOptions.single;
      });
      onSuccess();
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return PopScope(
          canPop: false,
          child: StatefulBuilder(
            builder: (statefulContext, dialogSetState) {
              return AlertDialog(
                title: const Text("Select Location Type"),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButton<String>(
                      value: tempSelectedLocationType,
                      hint: const Text("Select Location"),
                      isExpanded: true,
                      items:
                          locationOptions
                              .map(
                                (e) =>
                                    DropdownMenuItem(value: e, child: Text(e)),
                              )
                              .toList(),
                      onChanged: (value) {
                        dialogSetState(() {
                          tempSelectedLocationType = value;
                        });
                      },
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                    },
                    child: const Text("Cancel"),
                  ),
                  TextButton(
                    onPressed: () async {
                      if (tempSelectedLocationType == null) return;

                      setState(() {
                        selectedLocationType = tempSelectedLocationType;
                      });

                      final savedLocation = _getSavedLocationRow(
                        tempSelectedLocationType,
                      );
                      final locationType =
                          savedLocation?['location_type']?.toString().trim() ??
                          '';
                      final shouldUpdateEventLocation =
                          _requiresLocationBeforeCheckout() &&
                          locationType.isNotEmpty;

                      if (shouldUpdateEventLocation) {
                        final isUpdated = await Event.updateEventLocationType(
                          eventId: widget.eventid,
                          locationType: locationType,
                          context: context,
                        );

                        if (!isUpdated) {
                          if (mounted) {
                            Warning.show(
                              context,
                              'Unable to update Event location.',
                              'Error',
                            );
                          }
                          return;
                        }
                      }

                      Navigator.pop(dialogContext);
                      onSuccess();
                    },
                    child: const Text("OK"),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
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

  String _getParticipantReferenceDocname() {
    final participant = _getPrimaryParticipant();
    if (participant == null) return '';

    final directMatch =
        participant['opportunity_from']?.toString() ??
        participant['mention']?.toString() ??
        participant['reference_docname']?.toString();

    if (directMatch != null &&
        RegExp(r'^CRM-OPP-', caseSensitive: false).hasMatch(directMatch)) {
      return directMatch;
    }

    for (final entry in participant.entries) {
      final value = entry.value?.toString();
      if (value != null &&
          RegExp(r'^CRM-OPP-', caseSensitive: false).hasMatch(value)) {
        debugPrint(
          '[EventDetails] Opportunity id inferred from participant field '
          '${entry.key}: $value',
        );
        return value;
      }
    }

    return directMatch ?? '';
  }

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
    return _isSiteVisitEvent();
  }

  bool _hasCapturedCheckoutPhoto() {
    return _capturedPhotos.isNotEmpty || capturedImage != null;
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
    final savedLat = double.tryParse(savedRow?['latitude']?.toString() ?? '');
    final savedLng = double.tryParse(savedRow?['longitude']?.toString() ?? '');

    if (savedLat != null &&
        savedLng != null &&
        savedLat.isFinite &&
        savedLng.isFinite &&
        savedLat >= -90 &&
        savedLat <= 90 &&
        savedLng >= -180 &&
        savedLng <= 180) {
      return LatLng(savedLat, savedLng);
    }

    return null;
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
                      ? 'No saved customer location is available for this event.'
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
                Icon(Icons.location_on, color: Colors.blue),
                SizedBox(width: 8),
                Text(
                  'Customer Location',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            if (locationTypes.length > 1) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: locationType,
                decoration: const InputDecoration(
                  labelText: 'Saved location',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items:
                    locationTypes
                        .map(
                          (type) => DropdownMenuItem<String>(
                            value: type,
                            child: Text(type, overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _mapLocationType = value;
                      _customerRoutePoints = [];
                    });
                  }
                },
              ),
            ] else ...[
              const SizedBox(height: 6),
              Text(locationType, style: const TextStyle(color: Colors.black54)),
            ],
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
                              color: Colors.blue,
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

  bool _isWithinAllowedLocation({
    required double currentLat,
    required double currentLng,
  }) {
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
    if (referenceDocname.isEmpty) {
      if (mounted) {
        setState(() {
          _savedOpportunityLocations = [];
          _mapLocationType = null;
        });
      }
      return;
    }

    final rows = await Event.getOpportunityLocations(
      referenceDocname: referenceDocname,
      context: context,
    );

    if (mounted) {
      debugPrint(
        '[EventDetails] opportunity locations loaded for $referenceDocname: $rows',
      );
      setState(() {
        _savedOpportunityLocations = rows;
        final validLocationTypes = _getAvailableLocationTypes();
        final event = eventData['event'];
        final selectedLink =
            event is Map
                ? (event['custom_location'] ?? event['location'])
                    ?.toString()
                    .trim()
                : null;
        String? linkedLocationType;
        if (selectedLink != null && selectedLink.isNotEmpty) {
          final labels = _getLocationOptionLabels();
          for (var index = 0; index < rows.length; index++) {
            final row = rows[index];
            if (row['name']?.toString() == selectedLink ||
                row['location']?.toString() == selectedLink ||
                row['location_type']?.toString() == selectedLink) {
              if (index < labels.length) linkedLocationType = labels[index];
              break;
            }
          }
        }
        _mapLocationType =
            validLocationTypes.contains(linkedLocationType)
                ? linkedLocationType
                : validLocationTypes.contains(_mapLocationType)
                ? _mapLocationType
                : validLocationTypes.isEmpty
                ? null
                : validLocationTypes.first;
      });
    }
  }

  Future<void> performCheckIn({
    required String? userEmail,
    required String eventId,
    required double lat,
    required double lng,
    required String address,
  }) async {
    if (_requiresLocationBeforeCheckIn()) {
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

    if (!mounted) return;
    try {
      await BatteryOptimizationHelper.showBatteryOptimizationDialog(context);
    } catch (error) {
      debugPrint('Unable to show battery optimization prompt: $error');
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
    bool isOtpRequired = await Event.checkIfOtpRequired(
      widget.eventid,
      context,
    );

    if (isOtpRequired) {
      bool confirmed = await showOTPDialog(context);

      if (!confirmed) {
        Warning.show(
          context,
          "OTP verification failed. Cannot proceed.",
          "Error",
        );
        return;
      }
    }

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
    );
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
    final attendanceCheckedIn = prefs.getBool('is_employee_checked_in') ?? false;
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

    await _uploadCapturedPhotosAfterCheckout(
      lat: lat,
      lng: lng,
      address: address,
    );

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

  String _formatTime(String? dateTime) {
    if (dateTime == null || dateTime.isEmpty) return "--:--";

    try {
      DateTime dt = DateTime.parse(dateTime);
      String period = dt.hour >= 12 ? "pm" : "am";
      int hour =
          dt.hour > 12
              ? dt.hour - 12
              : dt.hour == 0
              ? 12
              : dt.hour;
      String minute = dt.minute.toString().padLeft(2, '0');
      return "$hour:$minute$period";
    } catch (e) {
      return "--:--";
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
      await _loadUserFullNames(response is Map ? response : {});
      await _loadParticipantVisitType();
      await _loadOpportunityLocations();
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

  String _getParticipantsTitles() {
    final participants = eventData['reference_details'];
    if (participants == null || participants is! List) return '';

    List<String> titles =
        participants
            .map<String>((p) => "${p['opportunity_from']}-${p['party_name']}")
            .toList();

    return titles.join(', ');
  }

  Future<String> _getCurrentLocationAddress() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final address = await LocationHelper.getAddressFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (address.isNotEmpty) {
        return address;
      } else {
        return "Unknown location";
      }
    } catch (e) {
      print("Error fetching location: $e");
      return "Error fetching location";
    }
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

  Future<bool> showOTPDialog(BuildContext context) async {
    TextEditingController otpController = TextEditingController();
    int timerSeconds = 30;
    Timer? resendTimer;

    Future<void> sendOtp() async {
      await Event.sendOtp(widget.eventid, context);
    }

    await sendOtp();

    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            void startTimer() {
              resendTimer?.cancel();
              resendTimer = Timer.periodic(Duration(seconds: 1), (timer) {
                if (timerSeconds == 0) {
                  timer.cancel();
                } else {
                  setState(() {
                    timerSeconds--;
                  });
                }
              });
            }

            if (resendTimer == null) {
              startTimer();
            }

            return AlertDialog(
              title: const Text('Enter OTP to Confirm'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: otpController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'OTP'),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    timerSeconds > 0
                        ? 'Resend OTP in $timerSeconds sec'
                        : 'Didn’t receive it?',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  TextButton(
                    onPressed:
                        timerSeconds == 0
                            ? () async {
                              await sendOtp();
                              setState(() {
                                timerSeconds = 30;
                              });
                              startTimer();
                            }
                            : null,
                    child: const Text('Resend OTP'),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    resendTimer?.cancel();
                    Navigator.of(dialogContext).pop(false);
                  },
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final isValid = await Event.verifyOtp(
                      otpController.text,
                      widget.eventid,
                    );
                    if (isValid) {
                      resendTimer?.cancel();
                      Navigator.of(dialogContext).pop(true);

                      Warning.show(context, 'OTP verified.', 'Success');
                    } else {
                      Warning.show(context, 'Invalid OTP', 'Error');
                    }
                  },
                  child: const Text('Submit'),
                ),
              ],
            );
          },
        );
      },
    ).then((value) => value ?? false);
  }

  void _resumeVisitActionAfterLocationSelection() {
    // A single saved location invokes its callback synchronously from the
    // dialog helper. Defer the retry so the current action can clear its lock.
    scheduleMicrotask(() {
      if (mounted) unawaited(_handleVisitCheckInOut());
    });
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

      // Ask for the customer location before waiting for GPS. This also avoids
      // the old retry path obtaining GPS and geocoding the address twice.
      if (startingVisit &&
          _requiresLocationBeforeCheckIn() &&
          selectedLocationType == null) {
        showLocationDialog(_resumeVisitActionAfterLocationSelection);
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
          selectedLocationType == null) {
        showLocationDialog(_resumeVisitActionAfterLocationSelection);
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
      if (mounted) Warning.show(context, error.toString(), 'Error');
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

  Widget _visitChecklistItem(String label, bool checked) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Checkbox(
            value: checked,
            onChanged: null,
            activeColor: const Color(0xFF1768C4),
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: checked ? const Color(0xFF202B3C) : Colors.black54,
                fontSize: 13,
                decoration: checked ? TextDecoration.none : null,
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
                      color: item.$2 ? const Color(0xFF1768C4) : Colors.black26,
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
              activeColor: const Color(0xFF1768C4),
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
      appBar: AppBar(
        leading: const HomeBackButton(color: Color(0xFF1768C4)),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF1768C4)),
        title: const Text(
          'Task Details',
          style: TextStyle(
            color: Color(0xFF202B3C),
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _isLoading ? null : () => _fetchData(),
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF202B3C)),
          ),
        ],
      ),
      body:
          _isLoading
              ? const Center(
                child: CircularProgressIndicator(color: Color(0xFF1768C4)),
              )
              : RefreshIndicator(
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
                                      : const Color(0xFF1768C4),
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
                                    'Department',
                                    department,
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
                          (checkedOut && _requiresPhotoBeforeCheckout()),
                    ),
                    _visitChecklistRow('Customer location verified', checkedIn),
                    _visitChecklistRow('Site visit completed', checkedOut),
                    const Divider(height: 20),
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
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: const Icon(
                                  Icons.add_rounded,
                                  color: Color(0xFF1768C4),
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
                      const SizedBox(height: 14),
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
                                  _isRecording
                                      ? Colors.red
                                      : const Color(0xFF1768C4),
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
                            _visitField(
                              'custom_location',
                              fallback: _visitField('location'),
                            ),
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
                    backgroundColor: const Color(0xFF1768C4),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor:
                        checkedIn ? const Color(0xFFE8F6EF) : Colors.black12,
                    disabledForegroundColor:
                        checkedIn ? const Color(0xFF219653) : Colors.black45,
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
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
                    backgroundColor: const Color(0xFF1768C4),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor:
                        checkedOut ? const Color(0xFFE8F6EF) : Colors.black12,
                    disabledForegroundColor:
                        checkedOut ? const Color(0xFF219653) : Colors.black45,
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
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
