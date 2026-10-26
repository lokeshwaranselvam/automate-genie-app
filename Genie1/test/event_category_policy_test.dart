import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/event_category_policy.dart';

void main() {
  test(
    'API switches disable geofencing and mandatory photos independently',
    () {
      expect(
        eventGeofencingEnabled({'visit_geofencing_enabled': false}),
        isFalse,
      );
      expect(
        eventRequiresCheckoutPhoto({'requires_checkout_photo': false}),
        isFalse,
      );
      for (final value in [null, true, 'false', 0]) {
        expect(
          eventGeofencingEnabled({'visit_geofencing_enabled': value}),
          isTrue,
        );
        expect(
          eventRequiresCheckoutPhoto({'requires_checkout_photo': value}),
          isTrue,
        );
      }
    },
  );

  test(
    'API checkout lists preserve the previous default category/type rule',
    () {
      final policy = {
        'checkout_location_categories': [
          'Site Visit',
          'Installation',
          'Complaint Visit',
        ],
        'checkout_location_visit_types': ['New'],
      };
      for (final category in [
        'Site Visit',
        'Installation',
        'Complaint Visit',
        'Measurement',
        'Other',
      ]) {
        for (final type in ['New', 'new', 'Follow-up', 'Existing']) {
          expect(
            eventRequiresCheckoutLocation(
              policy,
              category: category,
              visitType: type,
              legacyRequired: false,
            ),
            category != 'Measurement' &&
                category != 'Other' &&
                type.toLowerCase() == 'new',
          );
        }
      }
    },
  );

  test(
    'API can change checkout categories and visit types or disable the rule',
    () {
      final policy = {
        'checkout_location_categories': ['Measurement'],
        'checkout_location_visit_types': ['Existing', 'Follow-up'],
      };
      expect(
        eventRequiresCheckoutLocation(
          policy,
          category: 'Measurement',
          visitType: 'Existing',
          legacyRequired: false,
        ),
        isTrue,
      );
      expect(
        eventRequiresCheckoutLocation(
          policy,
          category: 'Measurement',
          visitType: 'New',
          legacyRequired: true,
        ),
        isFalse,
      );
      expect(
        eventRequiresCheckoutLocation(
          policy,
          category: 'Site Visit',
          visitType: 'New',
          legacyRequired: true,
        ),
        isFalse,
      );
      expect(
        eventRequiresCheckoutLocation(
          {
            'checkout_location_categories': [],
            'checkout_location_visit_types': ['New'],
          },
          category: 'Site Visit',
          visitType: 'New',
          legacyRequired: true,
        ),
        isFalse,
      );
    },
  );

  test('missing or invalid checkout policy retains the previous rule', () {
    for (final policy in [
      {},
      {
        'checkout_location_categories': ['Site Visit'],
      },
      {
        'checkout_location_categories': 'Site Visit',
        'checkout_location_visit_types': ['New'],
      },
      {
        'checkout_location_categories': ['Site Visit'],
        'checkout_location_visit_types': [null],
      },
    ]) {
      for (final legacy in [true, false]) {
        expect(
          eventRequiresCheckoutLocation(
            policy,
            category: 'Site Visit',
            visitType: 'New',
            legacyRequired: legacy,
          ),
          legacy,
        );
      }
    }
  });

  test('API independently configures check-in and monitoring radii', () {
    final policy = {
      'visit_checkin_radius_meters': 350,
      'visit_monitoring_radius_meters': 750.5,
      'visit_monitoring_enabled': false,
    };
    expect(eventCheckInRadiusMeters(policy), 350);
    expect(eventMonitoringRadiusMeters(policy), 750.5);
    expect(eventMonitoringEnabled(policy), isFalse);
    expect(
      eventRequiresGeofence({
        'event': {'event_category': 'Site Visit'},
      }),
      isTrue,
    );
  });

  test('missing and invalid distance settings preserve previous defaults', () {
    expect(eventCheckInRadiusMeters({}), 100);
    expect(eventMonitoringRadiusMeters({}), 200);
    expect(eventMonitoringEnabled({}), isTrue);
    for (final invalid in [
      null,
      0,
      -1,
      '500',
      true,
      double.nan,
      double.infinity,
    ]) {
      expect(
        eventCheckInRadiusMeters({'visit_checkin_radius_meters': invalid}),
        100,
      );
      expect(
        eventMonitoringRadiusMeters({
          'visit_monitoring_radius_meters': invalid,
        }),
        200,
      );
      expect(
        eventMonitoringEnabled({'visit_monitoring_enabled': invalid}),
        isTrue,
      );
    }
    expect(eventMonitoringEnabled({'visit_monitoring_enabled': true}), isTrue);
  });

  test(
    'API saved-location flag overrides categories without changing geofence',
    () {
      for (final category in ['Site Visit', 'Installation', 'Other', null]) {
        for (final required in [true, false]) {
          final details = {
            'event': {'event_category': category},
            'requires_saved_location': required,
            'requires_geofence': true,
          };
          expect(eventRequiresSavedLocation(details), required);
          expect(
            eventRequiresGeofence(details),
            !isLocationFreeEventCategory(category),
          );
        }
        for (final invalid in [null, 'false', 0]) {
          expect(
            eventRequiresSavedLocation({
              'event': {'event_category': category},
              'requires_saved_location': invalid,
            }),
            !isLocationFreeEventCategory(category),
          );
        }
        expect(
          eventRequiresSavedLocation({
            'event': {'event_category': category},
          }),
          !isLocationFreeEventCategory(category),
        );
      }
    },
  );

  test('only the specified categories skip saved locations and geofencing', () {
    for (final category in [
      'Other',
      ' Others ',
      'BANK',
      'Head Office CH',
      'Timbe / Bioman Office CH',
      'Collection',
    ]) {
      expect(isLocationFreeEventCategory(category), isTrue);
      for (final flag in [null, true, false]) {
        expect(
          eventRequiresGeofence({
            'event': {'event_category': category},
            'requires_geofence': flag,
          }),
          isFalse,
        );
      }
    }
    for (final category in [
      'Measurement',
      'Installation',
      'Site Visit',
      'Client Visit',
      'Complaint Visit',
      '',
      null,
    ]) {
      expect(isLocationFreeEventCategory(category), isFalse);
      expect(
        eventRequiresGeofence({
          'event': {'event_category': category},
        }),
        isTrue,
      );
      expect(
        eventRequiresGeofence({
          'event': {'event_category': category},
          'requires_geofence': false,
        }),
        isFalse,
      );
    }
  });
}
