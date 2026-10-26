import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/site_visit_schedule.dart';

void main() {
  final date = DateTime(2026, 10, 12);

  test(
    'API changes slot interval, past-time allowance and earliest booking date',
    () {
      final policy = SiteVisitSchedulePolicy.fromApi({
        'interval_minutes': 30,
        'allow_past': true,
        'earliest_booking_date': '2026-10-10',
      });
      final slots = SiteVisitSchedule.slots(
        date: date,
        now: DateTime(2026, 10, 13),
        policy: policy,
      );
      expect(slots.length, 48);
      expect(slots[1], DateTime(2026, 10, 12, 0, 30));
      expect(
        SiteVisitSchedule.validate(
          start: date,
          end: date.add(const Duration(minutes: 30)),
          now: DateTime(2026, 10, 13),
          policy: policy,
        ),
        isNull,
      );
      expect(
        SiteVisitSchedule.slots(
          date: DateTime(2026, 10, 9),
          now: date,
          policy: policy,
        ),
        isEmpty,
      );
      expect(
        SiteVisitSchedule.validate(
          start: date.add(const Duration(minutes: 15)),
          end: date.add(const Duration(minutes: 30)),
          now: date,
          policy: policy,
        ),
        isNotNull,
      );
    },
  );

  test('invalid API interval cannot create an empty or infinite slot loop', () {
    for (final interval in [0, -1, 7, 90, '30']) {
      expect(
        () => SiteVisitSchedulePolicy.fromApi({
          'interval_minutes': interval,
          'allow_past': false,
          'earliest_booking_date': '',
        }),
        throwsFormatException,
      );
    }
  });

  test('today only offers future quarter-hour slots', () {
    final slots = SiteVisitSchedule.slots(
      date: date,
      now: DateTime(2026, 10, 12, 11, 0, 1),
    );
    expect(slots.first, DateTime(2026, 10, 12, 11, 15));
    expect(slots.last, DateTime(2026, 10, 12, 23, 45));
    expect(slots.every((slot) => slot.minute % 15 == 0), isTrue);
  });

  test('future dates include morning slots and past dates offer none', () {
    expect(
      SiteVisitSchedule.slots(date: date, now: DateTime(2026, 10, 11)).length,
      96,
    );
    expect(
      SiteVisitSchedule.slots(date: date, now: DateTime(2026, 10, 13)),
      isEmpty,
    );
  });

  test('a late start can end at midnight on the following day', () {
    final start = DateTime(2026, 10, 12, 23, 45);
    final slots = SiteVisitSchedule.slots(
      date: date,
      now: date,
      after: start,
      includeMidnight: true,
    );
    expect(slots, [DateTime(2026, 10, 13)]);
    expect(
      SiteVisitSchedule.validate(start: start, end: slots.single, now: date),
      isNull,
    );
  });

  test('rejects elapsed, equal, reversed and non-quarter-hour times', () {
    final start = DateTime(2026, 10, 12, 11);
    final end = DateTime(2026, 10, 12, 11, 15);
    expect(
      SiteVisitSchedule.validate(start: start, end: end, now: start),
      isNull,
    );
    expect(
      SiteVisitSchedule.validate(
        start: start,
        end: end,
        now: start.add(const Duration(seconds: 1)),
      ),
      isNotNull,
    );
    expect(
      SiteVisitSchedule.validate(start: start, end: start, now: date),
      isNotNull,
    );
    expect(
      SiteVisitSchedule.validate(start: end, end: start, now: date),
      isNotNull,
    );
    expect(
      SiteVisitSchedule.validate(
        start: start.add(const Duration(minutes: 1)),
        end: end,
        now: date,
      ),
      isNotNull,
    );
    expect(
      SiteVisitSchedule.validate(
        start: start,
        end: end.add(const Duration(seconds: 1)),
        now: date,
      ),
      isNotNull,
    );
  });
}
