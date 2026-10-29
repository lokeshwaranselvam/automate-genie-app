import 'package:homegenie/utils/theme/brand_theme.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:adaptive_action_sheet/adaptive_action_sheet.dart';
import 'package:geolocator/geolocator.dart';
import 'package:homegenie/utils/api/check_in_out.dart';
import 'package:homegenie/utils/api/event.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as maps;
import 'package:shared_preferences/shared_preferences.dart';
import 'warning.dart';
import '../widget/live_location_service.dart';
import '../widget/battery_optimization_helper.dart';
import '../api/face_auth_api.dart';
import '../face/face_auth_flow.dart';
import '../face/face_performance_trace.dart';
import '../live_tracking_access.dart';
import '../mock_location_guard.dart';

class Action_Bottom {
  static Future<bool> _handleLocationPermission(
    BuildContext context, {
    required bool startingTracking,
  }) async {
    if (Platform.isAndroid &&
        startingTracking &&
        await LiveTrackingAccess.canTrack(requireCheckIn: false)) {
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

  /// ERP returns numbers as num or String depending on the field type.
  static double? _readDouble(dynamic value) {
    final parsed =
        value is num
            ? value.toDouble()
            : double.tryParse('${value ?? ''}'.trim());
    return parsed != null && parsed.isFinite ? parsed : null;
  }

  /// Frappe may return message as a String, Map or List; never pass a
  /// non-String to Warning.show.
  static String _responseMessage(dynamic response) {
    final message = response is Map ? response['message'] : response;
    if (message == null) return 'Something went wrong. Please try again.';
    if (message is String) return message;
    if (message is Map && message['message'] != null) {
      return _responseMessage(message);
    }
    if (message is List) return message.map((e) => '$e').join('\n');
    return message.toString();
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
    Future<bool?> Function()? resolveAttendanceAction,
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
                    var currentCheckedIn = isCheckedIn;
                    if (!context.mounted) return;
                    if (option == "Head Office") {
                      List<dynamic> officeList;
                      try {
                        officeList = await Event.head_office_list(context);
                      } catch (error) {
                        if (context.mounted) {
                          Warning.show(context, error.toString(), 'Head Office');
                        }
                        return;
                      }

                      if (!context.mounted) return;
                      List<String> officeNames =
                          officeList.map((e) => e.toString()).toList();

                      Action_Bottom_Secondary(
                        context: context,
                        title: option,
                        options: officeNames,
                        isCheckedIn: currentCheckedIn,
                        resolveAttendanceAction: resolveAttendanceAction,
                        onTrackingStarted: onTrackingStarted,
                        onTrackingStopped: onTrackingStopped,
                        onApiStart: onApiStart,
                        onApiEnd: onApiEnd,
                        onStatusUpdate: onStatusUpdate,
                      );
                    } else {
                      if (resolveAttendanceAction != null) {
                        final resolved = await resolveAttendanceAction();
                        if (resolved == null || !context.mounted) return;
                        currentCheckedIn = resolved;
                      }
                      final SharedPreferences prefs =
                          await SharedPreferences.getInstance();
                      final email = prefs.getString('email');

                      bool hasPermission = await _handleLocationPermission(
                        context,
                        startingTracking: !currentCheckedIn,
                      );
                      if (!hasPermission) return;

                      final lastCheckoutAddress =
                          prefs.getString('last_checkout_address') ?? '';

                      final faceReceipt = await _captureAttendancePhoto(
                        context,
                        checkingOut: currentCheckedIn,
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
                      if (currentCheckedIn) {
                        onTrackingStopped?.call();
                        // The server computes the checkout distance itself
                        // (Google Distance Matrix from last_lat_lng) and
                        // ignores client distance/location logs, so none are
                        // sent instead of a misleading "0.00 m".
                        response = await Check.checkout(
                          email,
                          position.latitude,
                          position.longitude,
                          address,
                          lastCheckoutAddress.isNotEmpty
                              ? lastCheckoutAddress
                              : "",
                          null,
                          option,
                          const [],
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
                        onStatusUpdate?.call(!currentCheckedIn);
                        String? trackingError;
                        if (currentCheckedIn) {
                          await _stopEmployeeLiveLocationTracking();
                          await prefs.setBool('is_employee_checked_in', false);
                        } else {
                          await prefs.setBool('is_employee_checked_in', true);
                          trackingError =
                              await _startEmployeeLiveLocationTracking();
                          if (trackingError == null &&
                              LiveLocationService().isTracking) {
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
                        Warning.show(context, _responseMessage(response), 'Warning');
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
    Future<bool?> Function()? resolveAttendanceAction,
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
                    if (!context.mounted) return;
                    try {
                      // Both reads must finish before GPS/face verification;
                      // neither needs to wait for the other to start.
                      final preparation = await Future.wait<dynamic>([
                        resolveAttendanceAction != null
                            ? resolveAttendanceAction()
                            : Future<bool?>.value(isCheckedIn),
                        const FacePerformanceTrace().measure(
                          'Head Office details before camera',
                          () => Event.Head_office_details(option, context),
                        ),
                      ]);
                      final currentCheckedIn = preparation[0] as bool?;
                      if (currentCheckedIn == null || !context.mounted) return;
                      final officeDetails = preparation[1] as Map<String, dynamic>;
                      final SharedPreferences prefs =
                          await SharedPreferences.getInstance();

                      final radius = _readDouble(
                        officeDetails['allowd_distance_meters'],
                      );
                      final latitude = _readDouble(officeDetails['latitude']);
                      final longitude = _readDouble(
                        officeDetails['longitude'],
                      );
                      if (radius == null ||
                          latitude == null ||
                          longitude == null) {
                        Warning.show(
                          context,
                          'The location or allowed distance for "$option" is '
                              'not configured in ERP. Contact your administrator.',
                          'Head Office',
                        );
                        return;
                      }
                      final double geofenceRadius = radius;

                      maps.LatLng geofenceCenter = maps.LatLng(
                        latitude,
                        longitude,
                      );

                      bool hasPermission = await _handleLocationPermission(
                        context,
                        startingTracking: !currentCheckedIn,
                      );
                      if (!hasPermission) return;

                      Position position;
                      onApiStart?.call();
                      try {
                        position = requireRealPosition(
                          await const FacePerformanceTrace().measure(
                            'Head Office GPS before camera',
                            () => Geolocator.getCurrentPosition(
                              desiredAccuracy: LocationAccuracy.high,
                              timeLimit: const Duration(seconds: 15),
                            ),
                          ),
                        );
                      } on TimeoutException {
                        onApiEnd?.call();
                        if (context.mounted) {
                          Warning.show(
                            context,
                            'Could not get your GPS location in time. Move to an open area and try again.',
                            'Location',
                          );
                        }
                        return;
                      } catch (_) {
                        onApiEnd?.call();
                        rethrow;
                      }
                      onApiEnd?.call();
                      if (!context.mounted) return;
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
                          checkingOut: currentCheckedIn,
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
                        if (currentCheckedIn) {
                          // LocationTrackerService.stopTracking();
                          // onTrackingStopped?.call();

                          // Distance is computed server-side; see above.
                          response = await Check.checkout(
                            email,
                            position.latitude,
                            position.longitude,
                            address,
                            lastCheckoutAddress.isNotEmpty
                                ? lastCheckoutAddress
                                : "",
                            null,
                            option,
                            const [],
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
                          onStatusUpdate?.call(!currentCheckedIn);
                          String? trackingError;
                          if (currentCheckedIn) {
                            await _stopEmployeeLiveLocationTracking();
                            await prefs.setBool(
                              'is_employee_checked_in',
                              false,
                            );
                          } else {
                            await prefs.setBool('is_employee_checked_in', true);
                            trackingError =
                                await _startEmployeeLiveLocationTracking();
                            if (trackingError == null &&
                                LiveLocationService().isTracking) {
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
                          Warning.show(context, _responseMessage(response), 'Warning');
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
