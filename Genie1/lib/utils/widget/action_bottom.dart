import 'package:homegenie/utils/theme/brand_theme.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:adaptive_action_sheet/adaptive_action_sheet.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:homegenie/utils/api/check_in_out.dart';
import 'package:homegenie/utils/api/event.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as maps;
import 'package:shared_preferences/shared_preferences.dart';
import 'warning.dart';
import '../widget/location_tracker.dart';
import '../widget/live_location_service.dart';
import '../widget/battery_optimization_helper.dart';
import '../api/face_auth_api.dart';
import '../face/face_auth_flow.dart';
import '../face/face_performance_trace.dart';

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

  /// Match the temporary blink selfie locally; submit only a verification receipt.
  static Future<FaceVerifiedResult?> _captureAttendancePhoto(
    BuildContext context, {
    required bool checkingOut,
    required Future<FaceLocation> Function() refreshLocation,
    bool overlapLocationWithMatching = true,
    Function()? onApiStart,
    Function()? onApiEnd,
  }) async {
    onApiStart?.call();
    try {
      final receipt = await FaceAuthFlow.instance.verify(
        context: context,
        action: checkingOut ? 'attendance_out' : 'attendance_in',
        refreshLocation: refreshLocation,
        overlapLocationWithMatching: overlapLocationWithMatching,
      );
      if (receipt != null) {
        await FaceAuthApi.instance.assertSessionUser(receipt.currentUser);
      }
      if (!context.mounted) return null;
      if (receipt == null) onApiEnd?.call();
      return receipt;
    } catch (error) {
      onApiEnd?.call();
      if (context.mounted) {
        Warning.show(context, error.toString(), 'Face verification failed');
      }
      return null;
    }
  }

  static Future<String?> _startEmployeeLiveLocationTracking() async {
    try {
      await const FacePerformanceTrace().measure(
        'live tracking start',
        LiveLocationService().startTracking,
      );
      return null;
    } catch (e) {
      print("Failed to start employee live location tracking: $e");
      return e.toString();
    }
  }

  static Future<void> _stopEmployeeLiveLocationTracking() async {
    try {
      await const FacePerformanceTrace().measure(
        'live tracking stop',
        LiveLocationService().stopTracking,
      );
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
            child: const Icon(Icons.close, color: BrandColors.ink),
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
                      const Icon(Icons.chevron_right, color: BrandColors.ink),
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

                      final lastCheckoutAddress =
                          prefs.getString('last_checkout_address') ?? '';

                      final faceReceipt = await _captureAttendancePhoto(
                        context,
                        checkingOut: isCheckedIn,
                        refreshLocation: FaceAuthFlow.freshLocation,
                        onApiStart: onApiStart,
                        onApiEnd: onApiEnd,
                      );
                      if (faceReceipt == null || !context.mounted) return;
                      final position = faceReceipt.position;
                      final address = faceReceipt.address;

                      var response;
                      onApiStart?.call();
                      final saveClock = Stopwatch()..start();
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
                          faceVerification: faceReceipt.recordId,
                        );
                      } else {
                        response = await Check.checkin(
                          email,
                          position.latitude,
                          position.longitude,
                          address,
                          option,
                          faceVerification: faceReceipt.recordId,
                        );
                      }
                      FacePerformanceTrace.logDuration(
                        'attendance save',
                        saveClock.elapsed,
                      );
                      onApiEnd?.call();

                      if (response?['status'] == "Success") {
                        onStatusUpdate?.call(!isCheckedIn);
                        String? trackingError;
                        if (isCheckedIn) {
                          await _stopEmployeeLiveLocationTracking();
                          await prefs.setBool('is_employee_checked_in', false);
                        } else {
                          trackingError =
                              await _startEmployeeLiveLocationTracking();
                          await prefs.setBool('is_employee_checked_in', true);
                          if (trackingError == null) {
                            await const FacePerformanceTrace().measure(
                              'battery guidance (includes user wait)',
                              () =>
                                  BatteryOptimizationHelper.showBatteryOptimizationDialog(
                                    context,
                                  ),
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
            child: const Icon(Icons.close, color: BrandColors.ink),
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
                      const Icon(Icons.chevron_right, color: BrandColors.ink),
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
                        final lastCheckoutAddress =
                            prefs.getString('last_checkout_address') ?? '';

                        final faceReceipt = await _captureAttendancePhoto(
                          context,
                          checkingOut: isCheckedIn,
                          // Preserve both Head Office GPS/geofence checks at
                          // their original points, including after matching.
                          overlapLocationWithMatching: false,
                          refreshLocation:
                              () => FaceAuthFlow.freshLocation(
                                isAllowed:
                                    (fresh) =>
                                        Geolocator.distanceBetween(
                                          fresh.latitude,
                                          fresh.longitude,
                                          geofenceCenter.latitude,
                                          geofenceCenter.longitude,
                                        ) <=
                                        geofenceRadius,
                                restrictionMessage:
                                    'You are outside the geofence!',
                              ),
                          onApiStart: onApiStart,
                          onApiEnd: onApiEnd,
                        );
                        if (faceReceipt == null || !context.mounted) return;
                        position = faceReceipt.position;
                        final address = faceReceipt.address;

                        var response;
                        onApiStart?.call();
                        final saveClock = Stopwatch()..start();
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
                            faceVerification: faceReceipt.recordId,
                          );
                        } else {
                          response = await Check.checkin(
                            email,
                            position.latitude,
                            position.longitude,
                            address,
                            option,
                            faceVerification: faceReceipt.recordId,
                          );
                        }
                        FacePerformanceTrace.logDuration(
                          'attendance save',
                          saveClock.elapsed,
                        );
                        onApiEnd?.call();

                        if (response?['status'] == "Success") {
                          onStatusUpdate?.call(!isCheckedIn);
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
                              await const FacePerformanceTrace().measure(
                                'battery guidance (includes user wait)',
                                () =>
                                    BatteryOptimizationHelper.showBatteryOptimizationDialog(
                                      context,
                                    ),
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
