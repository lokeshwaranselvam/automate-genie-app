class SiteVisitSchedule {
  static List<DateTime> slots({
    required DateTime date,
    required DateTime now,
    DateTime? after,
    bool includeMidnight = false,
  }) =>
      [
            for (
              var minute = 0;
              minute <= (includeMidnight ? 1440 : 1425);
              minute += 15
            )
              DateTime(date.year, date.month, date.day, 0, minute),
          ]
          .where(
            (slot) =>
                !slot.isBefore(now) && (after == null || slot.isAfter(after)),
          )
          .toList();

  static String? validate({
    required DateTime? start,
    required DateTime? end,
    required DateTime now,
  }) {
    if (start == null) return 'Select a start time.';
    if (end == null) return 'Select an end time.';
    for (final time in [start, end]) {
      if (time.minute % 15 != 0 ||
          time.second != 0 ||
          time.millisecond != 0 ||
          time.microsecond != 0) {
        return 'Choose times in 15-minute intervals.';
      }
    }
    if (start.isBefore(now)) return 'The start time cannot be in the past.';
    if (!end.isAfter(start)) {
      return 'The end time must be after the start time.';
    }
    return null;
  }
}
