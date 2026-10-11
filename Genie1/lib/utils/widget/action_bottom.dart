import 'dart:io';

import 'package:flutter/material.dart';
import 'package:adaptive_action_sheet/adaptive_action_sheet.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:homegenie/utils/api/check_in_out.dart';
import 'package:homegenie/utils/api/event.dart';
import 'package:homegenie/utils/api/image_upload_api.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as maps;
import 'package:shared_preferences/shared_preferences.dart';
import 'warning.dart';
import '../widget/location_tracker.dart';
import '../widget/live_location_service.dart';
import '../widget/battery_optimization_helper.dart';
import '../widget/camera_service.dart';
import '../widget/gps_photo_stamper.dart';
import '../api/location_api.dart';

class Action_Bottom {
  static Future<bool> _handleLocationPermission(
    BuildContext context, {
    required bool startingTracking,
  }) async {
    if (Platform.isAndroid && startingTracking) {
      final notificationPermission = await Permission.notification.request();
      if (!notificationPermission.isGranted) {
        Warning.show(
          context,
          'Enable notification permission so Android can show the live tracking notification.',
          'Notification permission required',
        );
        return false;
      }
    }

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
        'Location permissions are permanently denied. Please enable them in settings.',
        'Error',
      );
      return false;
    }

    return true;
  }

  /// Mandatory selfie for attendance: capture, GPS-stamp, compress and upload
  /// it before the check-in/check-out request. Returns the uploaded file_url,
  /// or null when the user cancelled or the upload failed (a message is shown
  /// and no attendance request is made).
  static Future<String?> _captureAttendancePhoto(
    BuildContext context, {
    required bool checkingOut,
    required Position position,
    required String address,
    required String? email,
    Function()? onApiStart,
    Function()? onApiEnd,
  }) async {
    final action = checkingOut ? 'Check-out' : 'Check-in';
    final photo = await CameraService.capturePhoto(front: true);
    if (photo == null) {
      Warning.show(
        context,
        'A selfie is required for Employee $action. Please try again and capture a photo.',
        'Photo required',
      );
      return null;
    }

    onApiStart?.call();
    File? stamped;
    try {
      stamped = await GpsPhotoStamper.stamp(
        file: photo,
        lat: position.latitude,
        lng: position.longitude,
        address: address,
        title: 'Employee $action',
      );
      final user = (email ?? 'user')
          .split('@')
          .first
          .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final time = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final fileUrl = await ImageUploadApi.uploadAttendancePhoto(
        filePath: stamped.path,
        fileName: '${checkingOut ? 'checkout' : 'checkin'}_${user}_$time.jpg',
      );
      if (fileUrl == null) {
        onApiEnd?.call();
        Warning.show(
          context,
          'Your photo could not be uploaded. Check your connection and try again. '
              'Employee $action was not recorded.',
          'Photo upload failed',
        );
      }
      return fileUrl;
    } catch (e) {
      onApiEnd?.call();
      Warning.show(
        context,
        'Your photo could not be processed: $e',
        'Photo upload failed',
      );
      return null;
    } finally {
      if (stamped != null &&
          stamped.path != photo.path &&
          stamped.existsSync()) {
        try {
          stamped.deleteSync();
        } catch (_) {}
      }
    }
  }

  static Future<String?> _startEmployeeLiveLocationTracking() async {
    try {
      await LiveLocationService().startTracking();
      return null;
    } catch (e) {
      print("Failed to start employee live location tracking: $e");
      return e.toString();
    }
  }

  static Future<void> _stopEmployeeLiveLocationTracking() async {
    try {
      await LiveLocationService().stopTracking();
    } catch (e) {
      print("Failed to stop employee live location tracking: $e");
    }
  }

  static Future<dynamic> show({
    required BuildContext context,
    required String title,
    required List<String> options,
    required bool isCheckedIn,
    VoidCallback? onTrackingStarted,
    VoidCallback? onTrackingStopped,
    Function(bool isNowCheckedIn)? onStatusUpdate,
    Function()? onApiStart,
    Function()? onApiEnd,
  }) {
    return showAdaptiveActionSheet(
      context: context,
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
          ),
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: const Icon(Icons.close, color: Colors.blueAccent),
          ),
        ],
      ),
      actions:
          options
              .map(
                (option) => BottomSheetAction(
                  title: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(option, style: TextStyle(fontSize: 20)),
                      const Icon(Icons.chevron_right, color: Colors.blueAccent),
                    ],
                  ),
                  onPressed: (_) async {
                    Navigator.pop(context);
                    if (option == "Head Office") {
                      List<dynamic> officeList = await Event.head_office_list(
                        context,
                      );

                      List<String> officeNames =
                          officeList.map((e) => e.toString()).toList();

                      Action_Bottom_Secondary(
                        context: context,
                        title: option,
                        options: officeNames,
                        isCheckedIn: isCheckedIn,
                        onTrackingStarted: onTrackingStarted,
                        onTrackingStopped: onTrackingStopped,
                        onApiStart: onApiStart,
                        onApiEnd: onApiEnd,
                        onStatusUpdate: onStatusUpdate,
                      );
                    } else {
                      final SharedPreferences prefs =
                          await SharedPreferences.getInstance();
                      final email = prefs.getString('email');

                      bool hasPermission = await _handleLocationPermission(
                        context,
                        startingTracking: !isCheckedIn,
                      );
                      if (!hasPermission) return;

                      Position position = await Geolocator.getCurrentPosition(
                        desiredAccuracy: LocationAccuracy.high,
                      );
                      final address =
                          await LocationHelper.getAddressFromCoordinates(
                            position.latitude,
                            position.longitude,
                          );

                      final lastCheckoutAddress =
                          prefs.getString('last_checkout_address') ?? '';

                      final photoUrl = await _captureAttendancePhoto(
                        context,
                        checkingOut: isCheckedIn,
                        position: position,
                        address: address,
                        email: email,
                        onApiStart: onApiStart,
                        onApiEnd: onApiEnd,
                      );
                      if (photoUrl == null) return;

                      var response;
                      onApiStart?.call();
                      if (isCheckedIn) {
                        LocationTrackerService.stopTracking();
                        double returnDistance =
                            LocationTrackerService.calculateTotalDistance();
                        onTrackingStopped?.call();
                        String formattedDistanceWithUnit;

                        if (returnDistance >= 1000) {
                          double km = returnDistance / 1000;
                          formattedDistanceWithUnit =
                              '${km.toStringAsFixed(2)} km';
                        } else {
                          formattedDistanceWithUnit =
                              '${returnDistance.toStringAsFixed(2)} m';
                        }
                        List<LatLng> path =
                            LocationTrackerService.getTrackedPoints();
                        List<Map<String, dynamic>> locationLogs =
                            path
                                .map(
                                  (latLng) => {
                                    'latitude': latLng.latitude,
                                    'longitude': latLng.longitude,
                                  },
                                )
                                .toList();

                        response = await Check.checkout(
                          email,
                          position.latitude,
                          position.longitude,
                          address,
                          lastCheckoutAddress.isNotEmpty
                              ? lastCheckoutAddress
                              : "",
                          formattedDistanceWithUnit,
                          option,
                          locationLogs,
                          photoUrl: photoUrl,
                        );
                      } else {
                        response = await Check.checkin(
                          email,
                          position.latitude,
                          position.longitude,
                          address,
                          option,
                          photoUrl: photoUrl,
                        );
                      }
                      onApiEnd?.call();

                      if (response?['status'] == "Success") {
                        String? trackingError;
                        if (isCheckedIn) {
                          await _stopEmployeeLiveLocationTracking();
                          await prefs.setBool('is_employee_checked_in', false);
                        } else {
                          trackingError =
                              await _startEmployeeLiveLocationTracking();
                          await prefs.setBool('is_employee_checked_in', true);
                          if (trackingError == null) {
                            await BatteryOptimizationHelper.showBatteryOptimizationDialog(
                              context,
                            );
                          }
                        }

                        final checkInMessage =
                            response['message']?.toString() ??
                            'Attendance updated successfully.';
                        if (trackingError == null) {
                          Warning.show(context, checkInMessage, 'Success');
                        } else {
                          Warning.show(
                            context,
                            '$checkInMessage\n\nLive location tracking did not start: $trackingError',
                            'Tracking warning',
                          );
                        }
                        // if (!isCheckedIn) {
                        //   LocationTrackerService.startTracking(
                        //     start: LatLng(
                        //       position.latitude,
                        //       position.longitude,
                        //     ),
                        //   );
                        //   onTrackingStarted?.call();
                        // }
                        await prefs.setString('last_checkout_address', '');
                        await prefs.setString('last_lat_lng', '');
                        await prefs.setBool('with_event', false);

                        await prefs.setString(
                          'last_lat_lng',
                          '${position.latitude},${position.longitude}',
                        );
                        onStatusUpdate?.call(!isCheckedIn);
                        // if (!isCheckedIn) {
                        //   onStatusUpdate?.call(true);
                        // } else {
                        //   onStatusUpdate?.call(false);
                        // }
                      } else {
                        Warning.show(context, response['message'], 'Warning');
                      }
                    }
                  },
                ),
              )
              .toList(),
    );
  }

  static Future<dynamic> Action_Bottom_Secondary({
    required BuildContext context,
    required String title,
    required List<String> options,
    required bool isCheckedIn,
    VoidCallback? onTrackingStarted,
    VoidCallback? onTrackingStopped,
    Function()? onApiStart,
    Function()? onApiEnd,
    Function(bool isNowCheckedIn)? onStatusUpdate,
  }) {
    return showAdaptiveActionSheet(
      context: context,
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w500),
          ),
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: const Icon(Icons.close, color: Colors.blueAccent),
          ),
        ],
      ),
      actions:
          options
              .map(
                (option) => BottomSheetAction(
                  title: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(option),
                      const Icon(Icons.chevron_right, color: Colors.blueAccent),
                    ],
                  ),
                  onPressed: (_) async {
                    Navigator.pop(context);
                    try {
                      final SharedPreferences prefs =
                          await SharedPreferences.getInstance();

                      Map<String, dynamic> officeDetails =
                          await Event.Head_office_details(option, context);

                      double geofenceRadius =
                          officeDetails['allowd_distance_meters'];

                      maps.LatLng geofenceCenter = maps.LatLng(
                        double.parse(officeDetails['latitude']),
                        double.parse(officeDetails['longitude']),
                      );

                      bool hasPermission = await _handleLocationPermission(
                        context,
                        startingTracking: !isCheckedIn,
                      );
                      if (!hasPermission) return;

                      Position? position;
                      position = await Geolocator.getCurrentPosition(
                        desiredAccuracy: LocationAccuracy.high,
                      );
                      double distance = Geolocator.distanceBetween(
                        position.latitude,
                        position.longitude,
                        geofenceCenter.latitude,
                        geofenceCenter.longitude,
                      );

                      if (distance <= geofenceRadius) {
                        final email = prefs.getString('email');
                        final address =
                            await LocationHelper.getAddressFromCoordinates(
                              position.latitude,
                              position.longitude,
                            );

                        final lastCheckoutAddress =
                            prefs.getString('last_checkout_address') ?? '';

                        final photoUrl = await _captureAttendancePhoto(
                          context,
                          checkingOut: isCheckedIn,
                          position: position,
                          address: address,
                          email: email,
                          onApiStart: onApiStart,
                          onApiEnd: onApiEnd,
                        );
                        if (photoUrl == null) return;

                        var response;
                        onApiStart?.call();
                        if (isCheckedIn) {
                          // LocationTrackerService.stopTracking();
                          // onTrackingStopped?.call();

                          double returnDistance =
                              LocationTrackerService.calculateTotalDistance();
                          String formattedDistanceWithUnit;

                          if (returnDistance >= 1000) {
                            double km = returnDistance / 1000;
                            formattedDistanceWithUnit =
                                '${km.toStringAsFixed(2)} km';
                          } else {
                            formattedDistanceWithUnit =
                                '${returnDistance.toStringAsFixed(2)} m';
                          }
                          List<LatLng> path =
                              LocationTrackerService.getTrackedPoints();
                          List<Map<String, dynamic>> locationLogs =
                              path
                                  .map(
                                    (latLng) => {
                                      'latitude': latLng.latitude,
                                      'longitude': latLng.longitude,
                                    },
                                  )
                                  .toList();
                          response = await Check.checkout(
                            email,
                            position.latitude,
                            position.longitude,
                            address,
                            lastCheckoutAddress.isNotEmpty
                                ? lastCheckoutAddress
                                : "",
                            formattedDistanceWithUnit,
                            option,
                            locationLogs,
                            photoUrl: photoUrl,
                          );
                        } else {
                          response = await Check.checkin(
                            email,
                            position.latitude,
                            position.longitude,
                            address,
                            option,
                            photoUrl: photoUrl,
                          );
                        }
                        onApiEnd?.call();

                        if (response?['status'] == "Success") {
                          String? trackingError;
                          if (isCheckedIn) {
                            await _stopEmployeeLiveLocationTracking();
                            await prefs.setBool(
                              'is_employee_checked_in',
                              false,
                            );
                          } else {
                            trackingError =
                                await _startEmployeeLiveLocationTracking();
                            await prefs.setBool('is_employee_checked_in', true);
                            if (trackingError == null) {
                              await BatteryOptimizationHelper.showBatteryOptimizationDialog(
                                context,
                              );
                            }
                          }

                          final checkInMessage =
                              response['message']?.toString() ??
                              'Attendance updated successfully.';
                          if (trackingError == null) {
                            Warning.show(context, checkInMessage, 'Success');
                          } else {
                            Warning.show(
                              context,
                              '$checkInMessage\n\nLive location tracking did not start: $trackingError',
                              'Tracking warning',
                            );
                          }
                          // if (!isCheckedIn) {
                          //   LocationTrackerService.startTracking(
                          //     start: LatLng(
                          //       _position.latitude,
                          //       _position.longitude,
                          //     ),
                          //   );
                          //   onTrackingStarted?.call();
                          // }
                          await prefs.setString('last_checkout_address', '');
                          await prefs.setBool('with_event', false);

                          await prefs.setString(
                            'last_lat_lng',
                            '${position.latitude},${position.longitude}',
                          );
                          onStatusUpdate?.call(!isCheckedIn);
                        } else {
                          Warning.show(context, response['message'], 'Warning');
                        }

                        // setState(() => _checkedIn = !_checkedIn);
                      } else {
                        Warning.show(
                          context,
                          'You are outside the geofence!',
                          'Error',
                        );
                      }
                    } catch (e) {
                      Warning.show(context, 'Error: ${e.toString()}', 'Error');
                    }
                  },
                ),
              )
              .toList(),
    );
  }
}
