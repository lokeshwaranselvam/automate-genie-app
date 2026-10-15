import '../utils/widget/pull_to_refresh.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';

import '../utils/widget/glass_card.dart';

class AttendancePage extends StatelessWidget {
  final bool checkedIn;
  final bool previousDayPendingCheckout;
  final bool completedToday;
  final String? statusError;
  final bool loading;
  final bool actionLoading;
  final Map<String, dynamic> status;
  final LatLng? position;
  final double? accuracy;
  final String currentAddress;
  final Future<void> Function() onRefresh;
  final VoidCallback onBack;
  final VoidCallback onOpenHistory;
  final VoidCallback onAttendanceAction;
  final VoidCallback onLeaveApplication;

  const AttendancePage({
    super.key,
    required this.checkedIn,
    required this.previousDayPendingCheckout,
    this.completedToday = false,
    this.statusError,
    required this.loading,
    required this.actionLoading,
    required this.status,
    required this.position,
    required this.accuracy,
    required this.currentAddress,
    required this.onRefresh,
    required this.onBack,
    required this.onOpenHistory,
    required this.onAttendanceAction,
    required this.onLeaveApplication,
  });

  String _firstValue(List<String> keys, {String fallback = '—'}) {
    for (final key in keys) {
      final value = status[key]?.toString().trim() ?? '';
      if (value.isNotEmpty && value.toLowerCase() != 'none') return value;
    }
    return fallback;
  }

  String _timeValue() {
    if (!checkedIn && !previousDayPendingCheckout) {
      return DateFormat('hh:mm a').format(DateTime.now());
    }

    final raw = _firstValue([
      'check_in_time',
      'checkin_time',
      'checked_in_at',
      'check_in_datetime',
      'in_time',
    ], fallback: '');
    if (raw.isEmpty) return DateFormat('hh:mm a').format(DateTime.now());
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) return DateFormat('hh:mm a').format(parsed.toLocal());
    for (final format in ['HH:mm:ss', 'HH:mm']) {
      try {
        return DateFormat('hh:mm a').format(DateFormat(format).parse(raw));
      } catch (_) {}
    }
    return raw;
  }

  String _shift() {
    final direct = _firstValue([
      'shift_time',
      'shift_hours',
      'shift',
      'shift_name',
    ], fallback: '');
    if (direct.isNotEmpty) return direct;

    final start = _firstValue(['shift_start', 'start_time'], fallback: '');
    final end = _firstValue(['shift_end', 'end_time'], fallback: '');
    if (start.isNotEmpty && end.isNotEmpty) return '$start - $end';
    return 'Not assigned';
  }

  bool? _withinGeofence() {
    for (final key in ['within_geofence', 'is_within_geofence']) {
      final value = status[key];
      if (value is bool) return value;
      if (value?.toString().toLowerCase() == 'true') return true;
      if (value?.toString().toLowerCase() == 'false') return false;
    }
    return null;
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Color(0xFF788394), fontSize: 13),
            ),
          ),
          const SizedBox(width: 14),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
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

  @override
  Widget build(BuildContext context) {
    final cameraTarget =
        position ?? const LatLng(13.0827, 80.2707); // Neutral map fallback.
    final hasPosition = position != null;
    final geoStatus = _withinGeofence();
    final locationName = _firstValue([
      'office_type',
      'office_name',
      'location_name',
      'office',
    ], fallback: checkedIn ? 'Office' : 'Select at check-in');
    final address = _firstValue(
      ['check_in_address', 'checkin_address', 'address'],
      fallback:
          currentAddress.isNotEmpty ? currentAddress : 'Location unavailable',
    );
    final checkInMethod = _firstValue([
      'check_in_method',
      'checkin_method',
    ], fallback: 'Mobile App (GPS)');

    return SafeArea(
      child: PullToRefresh(
        enabled: !loading && !actionLoading,
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: ClampingScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          children: [
            Container(
              decoration: BoxDecoration(
                gradient: BrandColors.gradient,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back_rounded),
                    color: Colors.white,
                    tooltip: 'Back to Home',
                  ),
                  const Expanded(
                    child: Text(
                      'Attendance',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onOpenHistory,
                    icon: const Icon(Icons.calendar_month_rounded),
                    color: Colors.white,
                    tooltip: 'Attendance history',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Today',
                        style: TextStyle(
                          color: Color(0xFF7A8799),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        DateFormat('EEE, d MMM yyyy').format(DateTime.now()),
                        style: const TextStyle(
                          color: Color(0xFF1D2A3D),
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                _StatusPill(
                  label:
                      loading
                          ? 'Loading'
                          : completedToday
                          ? 'Completed'
                          : previousDayPendingCheckout
                          ? 'Checkout Pending'
                          : checkedIn || previousDayPendingCheckout
                          ? 'Checked In'
                          : 'Not Checked In',
                  checkedIn:
                      completedToday || checkedIn || previousDayPendingCheckout,
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              _timeValue(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF171D29),
                fontSize: 29,
                fontWeight: FontWeight.w800,
                letterSpacing: .2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              completedToday
                  ? 'Attendance completed for today'
                  : previousDayPendingCheckout
                  ? 'Your previous day check-in is still open'
                  : checkedIn || previousDayPendingCheckout
                  ? 'At $locationName'
                  : 'Ready to check in',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF343F50),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 5),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.location_on_rounded,
                  size: 17,
                  color: Color(0xFF657387),
                ),
                const SizedBox(width: 3),
                Flexible(
                  child: Text(
                    address,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF657387),
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                height: 178,
                child:
                    hasPosition
                        ? GoogleMap(
                          initialCameraPosition: CameraPosition(
                            target: cameraTarget,
                            zoom: 16,
                          ),
                          myLocationEnabled: false,
                          myLocationButtonEnabled: false,
                          zoomControlsEnabled: false,
                          mapToolbarEnabled: false,
                          compassEnabled: false,
                          markers: {
                            Marker(
                              markerId: const MarkerId('employee-location'),
                              position: cameraTarget,
                              infoWindow: const InfoWindow(
                                title: 'Current location',
                              ),
                            ),
                          },
                          circles: {
                            Circle(
                              circleId: const CircleId('location-accuracy'),
                              center: cameraTarget,
                              radius: (accuracy ?? 35).clamp(20, 120),
                              fillColor: const Color(0x331B78D0),
                              strokeColor: const Color(0x553B82C4),
                              strokeWidth: 1,
                            ),
                          },
                        )
                        : Container(
                          color: const Color(0xFFE9F1F7),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.location_searching_rounded,
                            size: 36,
                            color: BrandColors.ink,
                          ),
                        ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _StatusPill(
                  label:
                      geoStatus == true
                          ? 'Within Location'
                          : geoStatus == false
                          ? 'Away from Location'
                          : hasPosition
                          ? 'Location Ready'
                          : 'GPS Unavailable',
                  checkedIn: geoStatus == true && hasPosition,
                ),
                Text(
                  accuracy == null
                      ? 'Accuracy: —'
                      : 'Accuracy: ${accuracy!.round()} m',
                  style: const TextStyle(
                    color: Color(0xFF596779),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
              borderRadius: BorderRadius.circular(14),
              child: Column(
                children: [
                  _detailRow('Shift', _shift()),
                  const Divider(height: 1, color: Color(0xFFE8EDF3)),
                  _detailRow('Location', locationName),
                  const Divider(height: 1, color: Color(0xFFE8EDF3)),
                  _detailRow('Check-in Method', checkInMethod),
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (statusError != null) ...[
              Text(
                statusError!,
                style: const TextStyle(color: Color(0xFFB3261E)),
              ),
            ],
            SizedBox(
              height: 54,
              child: ElevatedButton.icon(
                onPressed:
                    loading ||
                            actionLoading ||
                            completedToday ||
                            statusError != null
                        ? null
                        : onAttendanceAction,
                icon:
                    actionLoading
                        ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                        : Icon(
                          completedToday
                              ? Icons.check_circle_outline_rounded
                              : checkedIn || previousDayPendingCheckout
                              ? Icons.logout_rounded
                              : Icons.login_rounded,
                          size: 20,
                        ),
                label: Text(
                  completedToday
                      ? 'Completed'
                      : previousDayPendingCheckout
                      ? 'Previous Day Checkout'
                      : checkedIn || previousDayPendingCheckout
                      ? 'Check Out'
                      : 'Check In',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      completedToday
                          ? const Color(0xFF168A62)
                          : checkedIn || previousDayPendingCheckout
                          ? const Color(0xFFE7464D)
                          : const Color(0xFF168A62),
                  foregroundColor: Colors.white,
                  shape: const StadiumBorder(),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                onPressed: onLeaveApplication,
                icon: const Icon(Icons.event_available_outlined, size: 19),
                label: const Text(
                  'Leave Application',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: BrandColors.ink,
                  foregroundColor: Colors.white,
                  shape: const StadiumBorder(),
                ).copyWith(backgroundBuilder: BrandColors.buttonBackground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final bool checkedIn;

  const _StatusPill({required this.label, required this.checkedIn});

  @override
  Widget build(BuildContext context) {
    final color = checkedIn ? const Color(0xFF159B66) : const Color(0xFF7F8998);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
