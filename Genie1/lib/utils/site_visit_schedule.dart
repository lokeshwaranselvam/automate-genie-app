class SiteVisitSchedulePolicy {
  const SiteVisitSchedulePolicy({
    this.intervalMinutes = 15,
    this.allowPast = false,
    this.earliestBookingDate,
  });
  final int intervalMinutes;
  final bool allowPast;
  final DateTime? earliestBookingDate;

  factory SiteVisitSchedulePolicy.fromApi(Object? raw) {
    if (raw == null) return const SiteVisitSchedulePolicy();
    if (raw is! Map ||
        raw['interval_minutes'] is! int ||
        raw['interval_minutes'] < 1 ||
        raw['interval_minutes'] > 60 ||
        60 % raw['interval_minutes'] != 0 ||
        raw['allow_past'] is! bool) {
      throw const FormatException(
        'ERP returned invalid visit scheduling rules.',
      );
    }
    final text = raw['earliest_booking_date']?.toString() ?? '';
    final earliest = text.isEmpty ? null : DateTime.tryParse(text);
    if (text.isNotEmpty &&
        (earliest == null ||
            earliest.toIso8601String().substring(0, 10) != text)) {
      throw const FormatException(
        'ERP returned an invalid earliest visit date.',
      );
    }
    return SiteVisitSchedulePolicy(
      intervalMinutes: raw['interval_minutes'],
      allowPast: raw['allow_past'],
      earliestBookingDate: earliest,
    );
  }

  DateTime firstDate(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final configured = earliestBookingDate;
    if (!allowPast) {
      return configured != null && configured.isAfter(today)
          ? configured
          : today;
    }
    return configured ?? DateTime(1900);
  }
}

class SiteVisitSchedule {
  static List<DateTime> slots({
    required DateTime date,
    required DateTime now,
    DateTime? after,
    bool includeMidnight = false,
    SiteVisitSchedulePolicy policy = const SiteVisitSchedulePolicy(),
  }) =>
      [
            for (
              var minute = 0;
              minute <=
                  (includeMidnight ? 1440 : 1440 - policy.intervalMinutes);
              minute += policy.intervalMinutes
            )
              DateTime(date.year, date.month, date.day, 0, minute),
          ]
          .where(
            (slot) =>
                (policy.allowPast || !slot.isBefore(now)) &&
                !slot.isBefore(policy.firstDate(now)) &&
                (after == null || slot.isAfter(after)),
          )
          .toList();

  static String? validate({
    required DateTime? start,
    required DateTime? end,
    required DateTime now,
    SiteVisitSchedulePolicy policy = const SiteVisitSchedulePolicy(),
  }) {
    if (start == null) return 'Select a start time.';
    if (end == null) return 'Select an end time.';
    for (final time in [start, end]) {
      if (time.minute % policy.intervalMinutes != 0 ||
          time.second != 0 ||
          time.millisecond != 0 ||
          time.microsecond != 0) {
        return 'Choose times in ${policy.intervalMinutes}-minute intervals.';
      }
    }
    if (!policy.allowPast && start.isBefore(now)) {
      return 'The start time cannot be in the past.';
    }
    if (start.isBefore(policy.firstDate(now))) {
      return 'Choose a date on or after ${policy.firstDate(now).toIso8601String().substring(0, 10)}.';
    }
    if (!end.isAfter(start)) {
      return 'The end time must be after the start time.';
    }
    return null;
  }
}
