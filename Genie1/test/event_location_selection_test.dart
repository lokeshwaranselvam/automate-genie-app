import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/event_location_selection.dart';

void main() {
  final rows = <Map<String, dynamic>>[
    {
      'name': 'HOME-1',
      'location': 'Home address',
      'location_type': 'Home',
      'latitude': 13.05,
      'longitude': 80.2,
    },
    {
      'name': 'SITE-1',
      'location': 'https://maps.google.com/?q=13.1,80.3',
      'location_type': 'Site',
      'latitude': 13.1,
      'longitude': 80.3,
    },
    {
      'name': 'SITE-2',
      'location': 'Another site',
      'location_type': 'Site',
      'latitude': 14.1,
      'longitude': 81.3,
    },
  ];

  test('backend response resolves arbitrary Opportunity names, never Lead', () {
    expect(
      eventOpportunityName({
        'reference_details': [
          {
            'doctype': 'Opportunity',
            'name': 'OPP-1',
            'opportunity_from': 'Lead',
            'party_name': 'Customer',
          },
        ],
      }),
      'OPP-1',
    );
    expect(
      eventOpportunityName({
        'reference_details': [
          {
            'doctype': 'Opportunity',
            'name': 'SALES-2026-42',
            'opportunity_from': 'Lead',
          },
        ],
      }),
      'SALES-2026-42',
    );
    expect(
      eventOpportunityName({
        'reference_details': [
          {'doctype': 'Lead', 'name': 'LEAD-1'},
        ],
      }),
      isEmpty,
    );
  });

  test(
    'event participants resolve missing reference details without prefixes',
    () {
      expect(
        eventOpportunityName({
          'event': {
            'event_participants': [
              {'reference_doctype': 'Lead', 'reference_docname': 'LEAD-1'},
              {
                'reference_doctype': 'Opportunity',
                'reference_docname': 'OPP-2',
              },
            ],
          },
        }),
        'OPP-2',
      );
      expect(eventOpportunityName({}), isEmpty);
    },
  );

  test(
    'Event URL still supplies map coordinates without participant or type',
    () {
      final selected = eventSelectedLocations({
        'custom_location':
            'https://www.google.com/maps/search/?api=1&query=13.0549252,80.1559815',
      }, []);
      expect(selected, hasLength(1));
      expect(eventLocationCoordinates(selected.single)!.latitude, 13.0549252);
      expect(eventLocationLabel({}, selected), 'Selected location');
    },
  );

  test('equivalent map URLs recover the actual Home/Site type', () {
    final selected = eventSelectedLocations({
      'custom_location':
          'https://www.google.com/maps/search/?api=1&query=13.1,80.3',
    }, rows);
    expect(selected, [rows[1]]);
    expect(eventLocationLabel({}, selected), 'Site');
  });

  test('three duplicate matching rows cannot clear a valid Event map', () {
    const link =
        'https://www.google.com/maps/search/?api=1&query=13.0549252,80.1559815';
    final duplicateRows = [
      {
        'name': 'A',
        'location': link,
        'location_type': 'Home',
        'latitude': 13.0549252,
        'longitude': 80.1559815,
      },
      {
        'name': 'B',
        'location': link,
        'location_type': 'Site',
        'latitude': 13.0549252,
        'longitude': 80.1559815,
      },
      {
        'name': 'C',
        'location': link,
        'location_type': 'Site',
        'latitude': 13.0549252,
        'longitude': 80.1559815,
      },
    ];
    for (final event in [
      {'custom_location': link},
      {'custom_location': link, 'custom_location_type': 'Site'},
      {'custom_location': link, 'location': 'Home'},
    ]) {
      final before = eventSelectedLocations(event, []);
      final after = eventSelectedLocations(event, duplicateRows);
      expect(before, hasLength(1));
      expect(after, hasLength(1));
      expect(
        eventLocationCoordinates(after.single),
        eventLocationCoordinates(before.single),
      );
      expect(
        eventLocationLabel(event, after),
        eventLocationLabel(event, before),
      );
    }
    expect(
      eventSelectedLocations({
        'custom_location': link,
        'location': 'Home',
      }, duplicateRows).single['name'],
      'A',
    );
  });

  test('coordinate-equivalent duplicate URLs retain the Event destination', () {
    final duplicates = [
      rows[1],
      {...rows[1], 'name': 'SITE-COPY'},
    ];
    final selected = eventSelectedLocations({
      'custom_location':
          'https://www.google.com/maps/search/?api=1&query=13.1,80.3',
      'custom_location_type': 'Site',
    }, duplicates);
    expect(selected, hasLength(1));
    expect(eventLocationCoordinates(selected.single)!.latitude, 13.1);
    expect(eventLocationLabel({}, selected), 'Site');
  });

  test(
    'map coordinates alone do not authorize check-in without a saved type',
    () {
      final event = {'custom_location': rows[1]['location']};
      final mapOnly = eventSelectedLocations(event, []);
      expect(eventLocationCoordinates(mapOnly.single), isNotNull);
      expect(eventSavedLocationType(event, mapOnly), isNull);
      expect(eventHasCheckInLocation(event, mapOnly), isFalse);
    },
  );

  test('saved Home Site and Others allow check-in only with coordinates', () {
    for (final type in ['Home', 'Site', 'Others']) {
      final event = {
        'custom_location_type': type,
        'custom_location': rows[1]['location'],
      };
      final selected = eventSelectedLocations(event, []);
      expect(eventSavedLocationType(event, selected), type);
      expect(eventHasCheckInLocation(event, selected), isTrue);
      expect(eventHasCheckInLocation(event, []), isFalse);
      expect(
        eventHasCheckInLocation(event, [
          {'location_type': type, 'location': 'No coordinates'},
        ]),
        isFalse,
      );
    }
  });

  test('the resolved customer row supplies the saved read-only type', () {
    final event = {'custom_location': rows[0]['location']};
    final selected = eventSelectedLocations(event, rows);
    expect(eventSavedLocationType(event, selected), 'Home');
    expect(eventHasCheckInLocation(event, selected), isTrue);
    expect(eventHasCheckInLocation(event, rows), isFalse);
  });

  test(
    'standard Event location retains Home without the optional custom field',
    () {
      final event = {
        'location': 'Home',
        'custom_validate': rows[1]['location'],
        'custom_location': 'Employee current address',
      };
      final selected = eventSelectedLocations(event, [
        {...rows[1], 'name': 'HOME-A', 'location_type': 'Home'},
        {...rows[1], 'name': 'HOME-B', 'location_type': 'Home'},
        rows[1],
      ]);
      expect(eventSavedLocationType(event, selected), 'Home');
      expect(eventHasCheckInLocation(event, selected), isTrue);
      expect(
        eventSavedLocationType(event, [
          {...selected.single, 'location_type': 'Selected location'},
        ]),
        'Home',
      );
    },
  );

  test('creation-selected address excludes every other customer location', () {
    final selected = eventSelectedLocations({
      'custom_location': rows[1]['location'],
      'location': rows[1]['location'],
      'custom_location_type': 'Site',
    }, rows);
    expect(selected, [rows[1]]);
    // The original row and coordinates must be preserved for the geofence.
    expect(identical(selected.single, rows[1]), isTrue);
  });

  test('check-in address cannot replace the destination saved at creation', () {
    expect(
      eventSelectedLocations({
        'custom_validate': rows[1]['location'],
        'location': 'Site',
        'custom_location': 'Current GPS street address',
      }, rows),
      [rows[1]],
    );
    expect(
      eventSelectedLocations({
        'location': rows[1]['location'],
        'custom_location': 'Current GPS street address',
      }, rows),
      [rows[1]],
    );
  });

  test('type label is shown instead of the saved map URL', () {
    expect(
      eventLocationLabel({'custom_location_type': 'Home'}, [rows[0]]),
      'Home',
    );
    expect(
      eventLocationLabel({'custom_location': rows[1]['location']}, [rows[1]]),
      'Site',
    );
    expect(
      eventLocationLabel({'location': rows[1]['location']}, []),
      'Selected location',
    );
  });

  test('different ERP location table names return saved rows only', () {
    expect(
      opportunityLocationRows({
        'locations': rows,
        'participants': [
          {'name': 'USER-1'},
        ],
      }),
      rows,
    );
    expect(opportunityLocationRows({'custom_location': rows}), rows);
  });

  test('type and map URL are separate and URL identifies the exact site', () {
    expect(
      eventSelectedLocations({
        'custom_validate': 1,
        'location': 'Site',
        'custom_location': rows[1]['location'],
        'custom_location_type': 'Site',
      }, rows),
      [rows[1]],
    );
  });

  test('saved Event URL recovers coordinates without Opportunity rows', () {
    const link =
        'https://www.google.com/maps/search/?api=1&query=13.0549252,80.1559815';
    final selected = eventSelectedLocations({
      'custom_location_type': 'Home',
      'custom_location': link,
    }, []);
    expect(selected.single['location_type'], 'Home');
    final point = eventLocationCoordinates(selected.single)!;
    expect(point.latitude, 13.0549252);
    expect(point.longitude, 80.1559815);
    expect(eventLocationLabel({}, selected), 'Home');
  });

  test(
    'row coordinates remain authoritative; missing ones use its own URL',
    () {
      expect(eventLocationCoordinates(rows[1])!.longitude, 80.3);
      final point = eventLocationCoordinates({...rows[1], 'latitude': null})!;
      expect(point.latitude, 13.1);
      expect(point.longitude, 80.3);
      expect(
        eventLocationCoordinates({'location': 'https://maps.app.goo.gl/short'}),
        isNull,
      );
      expect(
        eventLocationCoordinates({
          'location': 'https://maps.google.com/?q=200,300',
        }),
        isNull,
      );
    },
  );

  test('child-row identity wins over an unrelated matching address', () {
    expect(eventSelectedLocations({'custom_location': 'SITE-2'}, rows), [
      rows[2],
    ]);
  });

  test('blank custom location uses the saved standard location', () {
    expect(
      eventSelectedLocations({
        'custom_location': '  ',
        'location': ' Home address ',
      }, rows),
      [rows[0]],
    );
  });

  test('legacy reporting URL resolves the selected address', () {
    expect(
      eventSelectedLocations({'custom_validate': rows[1]['location']}, rows),
      [rows[1]],
    );
  });

  test('legacy type-only selection requires a unique location', () {
    expect(eventSelectedLocations({'custom_location_type': 'Home'}, rows), [
      rows[0],
    ]);
    expect(
      eventSelectedLocations({'custom_location_type': 'Site'}, rows),
      isEmpty,
    );
    expect(eventSelectedLocations({'location': 'Home'}, rows), [rows[0]]);
  });

  test('deleted or missing selection never falls back to another address', () {
    expect(eventSelectedLocations({}, rows), isEmpty);
    expect(
      eventSelectedLocations({
        'custom_location': 'Deleted address',
        'custom_location_type': 'Home',
      }, rows),
      isEmpty,
    );
    expect(eventSelectedLocations({'location': 'Home address'}, []), isEmpty);
  });

  test('same address can be disambiguated using the saved location type', () {
    final shared = [
      {...rows[0], 'location': 'Shared address'},
      {...rows[1], 'location': 'Shared address'},
    ];
    expect(
      eventSelectedLocations({
        'custom_location': 'Shared address',
        'custom_location_type': 'Site',
      }, shared),
      [shared[1]],
    );
    expect(
      eventSelectedLocations({'location': 'Shared address'}, shared),
      isEmpty,
    );
  });

  test('invalid selected coordinates do not select a different valid row', () {
    final invalid = {...rows[1], 'latitude': null};
    expect(
      eventSelectedLocations(
        {'location': invalid['location']},
        [rows[0], invalid],
      ),
      [invalid],
    );
  });
  test('a direct Event resolves custom_validate without Opportunity rows', () {
    final event = {
      'event_category': 'Bank',
      'location': 'Others',
      'custom_validate':
          'https://www.google.com/maps/search/?api=1&query=13.085,80.21',
    };
    final selected = eventSelectedLocations(event, []);
    expect(selected.single['latitude'], 13.085);
    expect(selected.single['longitude'], 80.21);
    expect(eventHasCheckInLocation(event, selected), isTrue);
    expect(eventLocationLabel(event, selected), 'Others');
  });
}
