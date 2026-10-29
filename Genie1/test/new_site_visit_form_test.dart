import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/Screen/new_site_visit_page.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_visit_map_platform.dart';

Finder field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Finder dropdown(String label) =>
    label == 'Assigned to *'
        ? field(label)
        : find.byWidgetPredicate(
          (widget) =>
              widget is DropdownButtonFormField<String> &&
              widget.decoration.labelText == label,
        );

Future<void> withForm(
  WidgetTester tester,
  List<Map<String, String>> opportunities,
  Future<void> Function() check, {
  bool selectInitialCategory = true,
  Map<String, Object?>? categoryRules,
  Map<String, Object?>? businessPolicy,
  List<String>? eventLocationTypes,
  Future<http.Response> Function(http.Request)? onReferences,
  Future<http.Response> Function(http.Request)? onSearch,
  Future<http.Response> Function(http.Request)? onOpportunitySearch,
  List<http.Request>? requests,
  Future<http.Response> Function(http.Request)? onMapRequest,
  Future<http.Response> Function(http.Request)? onLocationSearch,
  Future<http.Response> Function(http.Request)? onPlaceDetails,
}) async {
  final previousMapPlatform = GoogleMapsFlutterPlatform.instance;
  GoogleMapsFlutterPlatform.instance = FakeVisitMapPlatform();
  const user = 'sales@example.test';
  SharedPreferences.setMockInitialValues({
    'session_sid': 'test-session',
    'session_username': user,
  });
  dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
  final client = MockClient((request) async {
    requests?.add(request);
    if (request.url.path.endsWith('frappe.auth.get_logged_user')) {
      return http.Response(jsonEncode({'message': user}), 200);
    }
    if (request.url.host == 'places.googleapis.com' &&
        request.url.path == '/v1/places:autocomplete' &&
        onLocationSearch != null) {
      return onLocationSearch(request);
    }
    if (request.url.host == 'places.googleapis.com' &&
        request.url.path.startsWith('/v1/places/')) {
      if (onPlaceDetails != null) return onPlaceDetails(request);
      final madurai = request.url.path.endsWith('/madurai');
      return http.Response(
        jsonEncode({
          'location': {
            'latitude': madurai ? 9.9252 : 13.085,
            'longitude': madurai ? 78.1198 : 80.21,
          },
        }),
        200,
      );
    }
    if (request.url.host == 'maps.google.com' ||
        request.url.host == 'maps.app.goo.gl') {
      return onMapRequest == null
          ? http.Response('', 200)
          : onMapRequest(request);
    }
    if (request.url.queryParameters['action'] == 'get_references' &&
        onReferences != null) {
      return onReferences(request);
    }
    if (request.url.queryParameters['action'] == 'search_by_mobile' &&
        onSearch != null) {
      return onSearch(request);
    }
    if (request.url.queryParameters['action'] == 'search_opportunities' &&
        onOpportunitySearch != null) {
      return onOpportunitySearch(request);
    }
    final body =
        request.method == 'POST' ? request.bodyFields : <String, String>{};
    return http.Response(
      jsonEncode({
        'message': {
          'status': 'success',
          'current_user': user,
          'csrf_token': 'test-token',
          if (request.method == 'GET') ...{
            'opportunities': opportunities,
            'product_enquired_options': ["D'sign Doors", 'Windows'],
            if (categoryRules != null) 'event_category_rules': categoryRules,
            'event_categories':
                categoryRules?.keys.toList() ??
                [
                  'Installation',
                  'Measurement',
                  'Site Visit',
                  'Client Visit',
                  'Meeting',
                  'Call',
                  'Other',
                  'Bank',
                  'Head Office CH',
                  'Timbe / Bioman Office CH',
                  'Collection',
                ],
            'location_types': ['Site', 'Home', 'Others'],
            if (businessPolicy != null) 'business_policy': businessPolicy,
            if (eventLocationTypes != null)
              'event_location_types': eventLocationTypes,
            'users': [
              {'name': user, 'full_name': 'Sales'},
              {'name': 'installer@example.test', 'full_name': 'Installer'},
            ],
          },
          if (body['action'] == 'save_location') 'location_row': 'LOC-1',
        },
      }),
      200,
    );
  });
  try {
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(home: NewSiteVisitPage()));
      await tester.pumpAndSettle();
      if (selectInitialCategory) {
        await tester.tap(find.widgetWithText(ListTile, "Site Visit"));
        await tester.pumpAndSettle();
      }
      await check();
    }, () => client);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    GoogleMapsFlutterPlatform.instance = previousMapPlatform;
  }
}

http.Response searchResponse(List<Map<String, String>> opportunities) =>
    http.Response(
      jsonEncode({
        'message': {
          'status': 'success',
          'current_user': 'sales@example.test',
          'csrf_token': 'test-token',
          'opportunities': opportunities,
        },
      }),
      200,
    );

String? selectedValue(WidgetTester tester, String label) {
  if (label == 'Assigned to *') {
    final value = tester.widget<TextField>(field(label)).controller!.text;
    return RegExp(r'^Assign to me \((.+)\)$').firstMatch(value)?.group(1) ??
        (value.isEmpty ? null : value);
  }
  return tester
      .widget<DropdownButton<String>>(
        find.descendant(
          of: dropdown(label),
          matching: find.byType(DropdownButton<String>),
        ),
      )
      .value;
}

Future<void> submitMapSearch(WidgetTester tester) async {
  await tester.pump();
  final button = find.byTooltip('Search map location');
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
}

Future<void> continueToEvent(
  WidgetTester tester, {
  String? mapLink = 'https://maps.google.com/?q=13,80',
}) async {
  if (mapLink != null) {
    await tester.enterText(field('Customer map link *'), mapLink);
  }
  await tester.ensureVisible(dropdown('Location type'));
  await tester.tap(dropdown('Location type'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Site').last);
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('Save location and continue'));
  await tester.tap(find.text('Save location and continue'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('location can be saved without type while map remains required', (
    tester,
  ) async {
    final requests = <http.Request>[];
    await withForm(
      tester,
      [
        {'name': 'OPP-1', 'title': 'Customer'},
      ],
      () async {
        expect(dropdown('Location type'), findsOneWidget);
        await tester.ensureVisible(find.text('Save location and continue'));
        await tester.tap(find.text('Save location and continue'));
        await tester.pumpAndSettle();
        expect(find.text('Map link is required.'), findsOneWidget);
        expect(requests.where((r) => r.method == 'POST'), isEmpty);

        await tester.ensureVisible(field('Customer map link *'));
        await tester.enterText(
          field('Customer map link *'),
          'https://maps.google.com/?q=13,80',
        );
        await tester.ensureVisible(find.text('Save location and continue'));
        await tester.tap(find.text('Save location and continue'));
        await tester.pumpAndSettle();
        final saved = requests.singleWhere(
          (r) =>
              r.method == 'POST' && r.bodyFields['action'] == 'save_location',
        );
        expect(saved.bodyFields['location_type'], '');
        expect(saved.bodyFields['latitude'], '13.0');
        expect(saved.bodyFields['longitude'], '80.0');
        expect(find.text('Event Details'), findsOneWidget);
      },
      requests: requests,
    );
  });

  testWidgets('API supplies event location type choices', (tester) async {
    await withForm(
      tester,
      [],
      () async {
        await tester.tap(find.widgetWithText(ListTile, 'Other'));
        await tester.pumpAndSettle();
        final location = dropdown('Location type *');
        await tester.ensureVisible(location);
        await tester.tap(location);
        await tester.pumpAndSettle();
        expect(find.text('Warehouse'), findsWidgets);
        expect(find.text('Home'), findsNothing);
      },
      selectInitialCategory: false,
      eventLocationTypes: ['Warehouse'],
      categoryRules: {
        'Other': {
          'reference_mode': 'document',
          'reference_doctype': 'Measurement',
          'required_fields': ['reference_name', 'location_type'],
        },
      },
      onReferences:
          (_) async => http.Response(
            jsonEncode({
              'message': {
                'status': 'success',
                'current_user': 'sales@example.test',
                'reference_doctype': 'Measurement',
                'references': [],
              },
            }),
            200,
          ),
    );
  });

  testWidgets('API can route Site Visit directly without Opportunity', (
    tester,
  ) async {
    await withForm(
      tester,
      [],
      () async {
        expect(find.text('Event Details'), findsOneWidget);
        expect(field('Opportunity *'), findsNothing);
        expect(field('Customer map link *'), findsNothing);
      },
      categoryRules: {
        'Site Visit': {
          'reference_mode': 'none',
          'reference_doctype': '',
          'required_fields': [
            'category',
            'summary',
            'starts_on',
            'ends_on',
            'assigned_to',
          ],
        },
      },
    );
  });

  testWidgets('Maintenance API rule opens Event Details without Opportunity', (
    tester,
  ) async {
    await withForm(
      tester,
      [],
      () async {
        await tester.tap(find.widgetWithText(ListTile, 'Maintenance'));
        await tester.pumpAndSettle();
        expect(find.text('Event Details'), findsOneWidget);
        expect(field('Opportunity *'), findsNothing);
        expect(field('Customer map link *'), findsNothing);
      },
      selectInitialCategory: false,
      categoryRules: {
        'Maintenance': {
          'reference_mode': 'none',
          'reference_doctype': '',
          'required_fields': [
            'category',
            'summary',
            'starts_on',
            'ends_on',
            'assigned_to',
          ],
        },
      },
    );
  });

  testWidgets('API can route Other to a Measurement document selector', (
    tester,
  ) async {
    await withForm(
      tester,
      [],
      () async {
        await tester.tap(find.widgetWithText(ListTile, 'Other'));
        await tester.pumpAndSettle();
        expect(field('Measurement *'), findsOneWidget);
        expect(field('Opportunity *'), findsNothing);
        expect(field('Customer map link *'), findsOneWidget);
      },
      selectInitialCategory: false,
      categoryRules: {
        'Other': {
          'reference_mode': 'document',
          'reference_doctype': 'Measurement',
          'required_fields': [
            'category',
            'summary',
            'starts_on',
            'ends_on',
            'assigned_to',
            'reference_name',
            'map_link',
            'latitude',
            'longitude',
            'location_type',
          ],
        },
      },
      onReferences:
          (_) async => http.Response(
            jsonEncode({
              'message': {
                'status': 'success',
                'current_user': 'sales@example.test',
                'reference_doctype': 'Measurement',
                'references': [],
              },
            }),
            200,
          ),
    );
  });

  testWidgets('invalid API category rule blocks the creation form', (
    tester,
  ) async {
    await withForm(
      tester,
      [],
      () async {
        expect(
          find.textContaining('invalid event category rule'),
          findsOneWidget,
        );
        expect(find.text('Create site visit'), findsNothing);
      },
      selectInitialCategory: false,
      categoryRules: {
        'Other': {'reference_mode': 'unknown'},
      },
    );
  });

  testWidgets(
    'Opportunity ID search displays Opportunity ID and own contact number',
    (tester) async {
      final requests = <http.Request>[];
      await withForm(
        tester,
        [
          {'name': 'OPP-1', 'title': 'First'},
          {'name': 'OPP-2', 'title': 'Second'},
        ],
        () async {
          await tester.enterText(field('Opportunity *'), '28718');
          await tester.pump(const Duration(milliseconds: 450));
          await tester.pumpAndSettle();
          expect(find.text('Ankit'), findsOneWidget);
          expect(find.text('CRM-OPP-2026-28718 · 9873823617'), findsOneWidget);
          expect(find.textContaining('CRM-LEAD-2026-50209'), findsNothing);
          await tester.tap(find.text('Ankit'));
          await tester.pumpAndSettle();
          await continueToEvent(tester);
          final save = requests.singleWhere(
            (request) =>
                request.method == 'POST' &&
                request.bodyFields['action'] == 'save_location',
          );
          expect(save.bodyFields['opportunity'], 'CRM-OPP-2026-28718');
        },
        requests: requests,
        onOpportunitySearch: (request) async {
          expect(request.url.queryParameters['query'], '28718');
          return http.Response(
            jsonEncode({
              'message': {
                'status': 'success',
                'current_user': 'sales@example.test',
                'opportunities': [
                  {
                    'name': 'CRM-OPP-2026-28718',
                    'title': 'Ankit',
                    'party_name': 'CRM-LEAD-2026-50209',
                    'contact_mobile': '9873823617',
                  },
                ],
              },
            }),
            200,
          );
        },
      );
    },
  );

  testWidgets('Opportunity ID search ignores stale server results', (
    tester,
  ) async {
    final oldSearch = Completer<http.Response>();
    await withForm(
      tester,
      [
        {'name': 'OPP-1', 'title': 'First'},
        {'name': 'OPP-2', 'title': 'Second'},
      ],
      () async {
        await tester.enterText(field('Opportunity *'), 'old');
        await tester.pump(const Duration(milliseconds: 450));
        await tester.enterText(field('Opportunity *'), 'new');
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pumpAndSettle();
        oldSearch.complete(
          http.Response(
            jsonEncode({
              'message': {
                'status': 'success',
                'current_user': 'sales@example.test',
                'opportunities': [
                  {'name': 'OLD-OPP', 'title': 'Old match'},
                ],
              },
            }),
            200,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('New match'), findsOneWidget);
        expect(find.text('Old match'), findsNothing);
      },
      onOpportunitySearch: (request) async {
        if (request.url.queryParameters['query'] == 'old')
          return oldSearch.future;
        return http.Response(
          jsonEncode({
            'message': {
              'status': 'success',
              'current_user': 'sales@example.test',
              'opportunities': [
                {'name': 'NEW-OPP', 'title': 'New match'},
              ],
            },
          }),
          200,
        );
      },
    );
  });

  const initialOpportunities = [
    {
      'name': 'OPP-1',
      'title': 'Lokesh',
      'party_name': 'LEAD-1',
      'product_enquired': "D'sign Doors",
    },
    {
      'name': 'OPP-2',
      'title': 'Nami',
      'party_name': 'LEAD-2',
      'product_enquired': '',
    },
  ];
  const phoneMatch = {
    'name': 'OPP-PHONE',
    'title': 'Phone match',
    'party_name': 'LEAD-PHONE',
    'product_enquired': 'Windows',
    'assigned_to': 'installer@example.test',
  };

  http.Response locationResults() => http.Response(
    jsonEncode({
      'suggestions': [
        {
          'placePrediction': {
            'placeId': 'chennai',
            'text': {'text': 'Anna Nagar, Chennai'},
          },
        },
        {
          'placePrediction': {
            'placeId': 'madurai',
            'text': {'text': 'Anna Nagar, Madurai'},
          },
        },
      ],
    }),
    200,
  );

  for (final category in ['Measurement', 'Installation']) {
    testWidgets(
      '$category selects its own document by phone and creates a linked Event',
      (tester) async {
        final doctype =
            category == 'Measurement' ? 'Measurement' : 'Installation Note';
        const detailLabel = 'Company';
        const detailKey = 'company';
        final requests = <http.Request>[];
        await withForm(
          tester,
          [],
          () async {
            await tester.ensureVisible(find.widgetWithText(ListTile, category));
            await tester.tap(find.widgetWithText(ListTile, category));
            await tester.pumpAndSettle();
            expect(field('Opportunity *'), findsNothing);
            expect(dropdown('Product enquired'), findsNothing);
            expect(field('$doctype *'), findsOneWidget);
            await tester.enterText(field('Mobile number'), '98765');
            await tester.pump(const Duration(milliseconds: 600));
            await tester.pumpAndSettle();
            expect(
              tester.widget<TextField>(field('$doctype *')).controller!.text,
              'Phone result (SOURCE-PHONE)',
            );
            final detail = tester.widget<TextField>(field(detailLabel));
            expect(detail.controller!.text, 'Selected detail');
            expect(detail.readOnly, isTrue);
            await tester.ensureVisible(field('Customer map link *'));
            await tester.enterText(
              field('Customer map link *'),
              'https://www.google.com/maps?q=13.085,80.21',
            );
            if (category != 'Measurement') {
              await tester.ensureVisible(dropdown('Location type'));
              await tester.tap(dropdown('Location type'));
              await tester.pumpAndSettle();
              await tester.tap(find.text('Site').last);
              await tester.pumpAndSettle();
            }
            await tester.ensureVisible(find.text('Continue to event details'));
            await tester.tap(find.text('Continue to event details'));
            await tester.pumpAndSettle();
            expect(find.text('Event Details'), findsOneWidget);
            expect(find.text('Selected detail'), findsOneWidget);
            expect(requests.where((r) => r.method == 'POST'), isEmpty);
            await tester.ensureVisible(find.text('Select visit date'));
            await tester.tap(find.text('Select visit date'));
            await tester.pumpAndSettle();
            tester
                .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
                .onDateChanged(
                  DateUtils.dateOnly(
                    DateTime.now(),
                  ).add(const Duration(days: 1)),
                );
            await tester.pumpAndSettle();
            await tester.tap(find.text('OK'));
            await tester.pumpAndSettle();
            for (final label in ['Start time *', 'End time *']) {
              final input = find.byWidgetPredicate(
                (widget) =>
                    widget is InputDecorator &&
                    widget.decoration.labelText == label,
              );
              await tester.ensureVisible(input);
              await tester.tap(input);
              await tester.pumpAndSettle();
              await tester.tap(find.byType(ListTile).first);
              await tester.pumpAndSettle();
            }
            await tester.ensureVisible(field('Summary *'));
            await tester.enterText(field('Summary *'), 'Source visit');
            await tester.ensureVisible(find.text('Create site visit'));
            await tester.tap(find.text('Create site visit'));
            await tester.pumpAndSettle();
            final post =
                requests.singleWhere((r) => r.method == 'POST').bodyFields;
            expect(post['reference_doctype'], doctype);
            expect(
              post['location_type'],
              category == 'Measurement' ? isNull : 'Site',
            );
            expect(post['reference_name'], 'SOURCE-PHONE');
            expect(post['opportunity'], '');
            expect(post['location_row'], '');
            expect(post['category'], category);
            expect(post['latitude'], '13.085');
            expect(post['longitude'], '80.21');
            expect(post, isNot(contains('product_enquired')));
            expect(post, isNot(contains('company')));
            expect(post, isNot(contains('custom_brand')));
          },
          selectInitialCategory: false,
          requests: requests,
          onReferences: (request) async {
            expect(request.url.queryParameters['category'], category);
            final byPhone = request.url.queryParameters['mobile'] == '98765';
            return http.Response(
              jsonEncode({
                'message': {
                  'status': 'success',
                  'current_user': 'sales@example.test',
                  'reference_doctype': doctype,
                  'references':
                      byPhone
                          ? [
                            {
                              'name': 'SOURCE-PHONE',
                              'title': 'Phone result',
                              detailKey: 'Selected detail',
                            },
                          ]
                          : [
                            {
                              'name': 'SOURCE-1',
                              'title': 'First',
                              detailKey: 'First detail',
                            },
                            {
                              'name': 'SOURCE-2',
                              'title': 'Second',
                              detailKey: 'Second detail',
                            },
                          ],
                },
              }),
              200,
            );
          },
        );
      },
    );
  }

  for (final category in [
    'Other',
    'Bank',
    'Head Office CH',
    'Timbe / Bioman Office CH',
    'Collection',
  ]) {
    testWidgets('$category creates without Opportunity or location controls', (
      tester,
    ) async {
      final requests = <http.Request>[];
      await withForm(
        tester,
        [],
        () async {
          expect(field('Opportunity *'), findsNothing);
          expect(field('Search location'), findsNothing);
          final tile = find.widgetWithText(ListTile, category);
          await tester.ensureVisible(tile);
          await tester.tap(tile);
          await tester.pumpAndSettle();
          expect(find.text('Event Details'), findsOneWidget);
          expect(field('Opportunity *'), findsNothing);
          expect(dropdown('Product enquired'), findsNothing);
          expect(field('Search location'), findsNothing);
          expect(field('Customer map link *'), findsNothing);
          expect(dropdown('Location type'), findsNothing);
          expect(find.byType(GoogleMap), findsNothing);
          await tester.ensureVisible(find.text('Select visit date'));
          await tester.tap(find.text('Select visit date'));
          await tester.pumpAndSettle();
          tester
              .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
              .onDateChanged(
                DateUtils.dateOnly(DateTime.now()).add(const Duration(days: 1)),
              );
          await tester.pumpAndSettle();
          await tester.tap(find.text('OK'));
          await tester.pumpAndSettle();
          for (final label in ['Start time *', 'End time *']) {
            final input = find.byWidgetPredicate(
              (widget) =>
                  widget is InputDecorator &&
                  widget.decoration.labelText == label,
            );
            await tester.ensureVisible(input);
            await tester.tap(input);
            await tester.pumpAndSettle();
            await tester.tap(find.byType(ListTile).first);
            await tester.pumpAndSettle();
          }
          await tester.ensureVisible(field('Summary *'));
          await tester.enterText(field('Summary *'), 'Office visit');
          await tester.ensureVisible(find.text('Create site visit'));
          await tester.tap(find.text('Create site visit'));
          await tester.pumpAndSettle();
          final post =
              requests.singleWhere((r) => r.method == 'POST').bodyFields;
          expect(post['category'], category);
          for (final key in [
            'map_link',
            'latitude',
            'longitude',
            'location_type',
          ]) {
            expect(post, isNot(contains(key)));
          }
        },
        requests: requests,
        selectInitialCategory: false,
      );
    });
  }

  testWidgets(
    'typing debounces Google suggestions and keeps the keyboard focused',
    (tester) async {
      final queries = <String>[];
      await withForm(
        tester,
        [initialOpportunities.first],
        () async {
          await tester.ensureVisible(field('Search location'));
          await tester.enterText(field('Search location'), 'An');
          await tester.pump(const Duration(milliseconds: 600));
          expect(queries, isEmpty);
          await tester.enterText(field('Search location'), 'Anna');
          await tester.pump(const Duration(milliseconds: 250));
          await tester.enterText(field('Search location'), 'Anna Nagar');
          await tester.pump(const Duration(milliseconds: 399));
          expect(queries, isEmpty);
          await tester.pump(const Duration(milliseconds: 1));
          await tester.pumpAndSettle();
          expect(queries, ['Anna Nagar']);
          expect(
            find.widgetWithText(ListTile, 'Anna Nagar, Chennai'),
            findsOneWidget,
          );
          final editable = tester.widget<EditableText>(
            find.descendant(
              of: field('Search location'),
              matching: find.byType(EditableText),
            ),
          );
          expect(editable.focusNode.hasFocus, isTrue);
          await tester.enterText(field('Search location'), '');
          await tester.pump(const Duration(milliseconds: 600));
          expect(
            find.widgetWithText(ListTile, 'Anna Nagar, Chennai'),
            findsNothing,
          );
          expect(queries.length, 1);
        },
        onLocationSearch: (request) async {
          queries.add(jsonDecode(request.body)['input'] as String);
          return locationResults();
        },
      );
    },
  );

  testWidgets(
    'autocomplete shares a session with details and renews after selection',
    (tester) async {
      final tokens = <String>[];
      String? detailsToken;
      await withForm(
        tester,
        [initialOpportunities.first],
        () async {
          await tester.ensureVisible(field('Search location'));
          for (final query in ['Anna', 'Anna Nagar']) {
            await tester.enterText(field('Search location'), query);
            await tester.pump(const Duration(milliseconds: 400));
            await tester.pumpAndSettle();
          }
          final tile = find.widgetWithText(ListTile, 'Anna Nagar, Chennai');
          await tester.ensureVisible(tile);
          await tester.tap(tile);
          await tester.pumpAndSettle();
          expect(tokens[0], tokens[1]);
          expect(detailsToken, tokens[1]);
          await tester.enterText(field('Search location'), 'Next location');
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          expect(tokens[2], isNot(tokens[1]));
        },
        onLocationSearch: (request) async {
          tokens.add(jsonDecode(request.body)['sessionToken'] as String);
          expect(request.headers['x-goog-fieldmask'], contains('placeId'));
          return locationResults();
        },
        onPlaceDetails: (request) async {
          detailsToken = request.url.queryParameters['sessionToken'];
          expect(request.headers['x-goog-fieldmask'], 'location');
          return http.Response(
            jsonEncode({
              'location': {'latitude': 13.085, 'longitude': 80.21},
            }),
            200,
          );
        },
      );
    },
  );

  testWidgets(
    'a pending debounce is cancelled when the user selects a map point',
    (tester) async {
      var requests = 0;
      await withForm(
        tester,
        [initialOpportunities.first],
        () async {
          await tester.ensureVisible(field('Search location'));
          await tester.enterText(field('Search location'), 'Anna Nagar');
          await tester.pump(const Duration(milliseconds: 200));
          tester.widget<GoogleMap>(find.byType(GoogleMap)).onTap!(
            const LatLng(12, 77),
          );
          await tester.pump(const Duration(milliseconds: 500));
          expect(requests, 0);
        },
        onLocationSearch: (_) async {
          requests++;
          return locationResults();
        },
      );
    },
  );

  testWidgets(
    'a failed place detail lookup keeps the previous point and allows retry',
    (tester) async {
      var attempts = 0;
      await withForm(
        tester,
        [initialOpportunities.first],
        () async {
          tester.widget<GoogleMap>(find.byType(GoogleMap)).onTap!(
            const LatLng(12, 77),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(field('Search location'));
          await tester.enterText(field('Search location'), 'Anna Nagar');
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          final tile = find.widgetWithText(ListTile, 'Anna Nagar, Chennai');
          await tester.ensureVisible(tile);
          await tester.tap(tile);
          await tester.pumpAndSettle();
          expect(
            find.text(
              'Google Maps returned invalid coordinates for this place.',
            ),
            findsOneWidget,
          );
          expect(
            tester
                .widget<GoogleMap>(find.byType(GoogleMap))
                .markers
                .single
                .position,
            const LatLng(12, 77),
          );
          await tester.ensureVisible(tile);
          await tester.tap(tile);
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<GoogleMap>(find.byType(GoogleMap))
                .markers
                .single
                .position,
            const LatLng(13.085, 80.21),
          );
        },
        onLocationSearch: (_) async => locationResults(),
        onPlaceDetails: (_) async {
          attempts++;
          return http.Response(
            jsonEncode({
              'location': {
                'latitude': attempts == 1 ? 100 : 13.085,
                'longitude': 80.21,
              },
            }),
            200,
          );
        },
      );
    },
  );

  testWidgets(
    'a late place detail response cannot replace a manually chosen point',
    (tester) async {
      final pending = Completer<http.Response>();
      await withForm(
        tester,
        [initialOpportunities.first],
        () async {
          await tester.ensureVisible(field('Search location'));
          await tester.enterText(field('Search location'), 'Anna Nagar');
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          final tile = find.widgetWithText(ListTile, 'Anna Nagar, Chennai');
          await tester.ensureVisible(tile);
          await tester.tap(tile);
          await tester.pump();
          tester.widget<GoogleMap>(find.byType(GoogleMap)).onTap!(
            const LatLng(12, 77),
          );
          pending.complete(
            http.Response(
              jsonEncode({
                'location': {'latitude': 13.085, 'longitude': 80.21},
              }),
              200,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<GoogleMap>(find.byType(GoogleMap))
                .markers
                .single
                .position,
            const LatLng(12, 77),
          );
          expect(
            tester
                .widget<TextField>(field('Customer map link *'))
                .controller!
                .text,
            contains('query=12.0,77.0'),
          );
          expect(tester.takeException(), isNull);
        },
        onLocationSearch: (_) async => locationResults(),
        onPlaceDetails: (_) => pending.future,
      );
    },
  );

  testWidgets(
    'typing during a detail lookup starts a new session and ignores its late result',
    (tester) async {
      final pending = Completer<http.Response>();
      final tokens = <String>[];
      await withForm(
        tester,
        [initialOpportunities.first],
        () async {
          await tester.ensureVisible(field('Search location'));
          await tester.enterText(field('Search location'), 'Anna Nagar');
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          final tile = find.widgetWithText(ListTile, 'Anna Nagar, Chennai');
          await tester.ensureVisible(tile);
          await tester.tap(tile);
          await tester.pump();
          await tester.enterText(field('Search location'), 'Next query');
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pumpAndSettle();
          expect(tokens.length, 2);
          expect(tokens[1], isNot(tokens[0]));
          pending.complete(
            http.Response(
              jsonEncode({
                'location': {'latitude': 13.085, 'longitude': 80.21},
              }),
              200,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.widget<GoogleMap>(find.byType(GoogleMap)).markers,
            isEmpty,
          );
          expect(
            tester.widget<TextField>(field('Search location')).controller!.text,
            'Next query',
          );
        },
        onLocationSearch: (request) async {
          tokens.add(jsonDecode(request.body)['sessionToken'] as String);
          return locationResults();
        },
        onPlaceDetails: (_) => pending.future,
      );
    },
  );

  testWidgets(
    'location search results move the map and save the selected address coordinates',
    (tester) async {
      final requests = <http.Request>[];
      await withForm(
        tester,
        [initialOpportunities.first],
        () async {
          await tester.ensureVisible(field('Search location'));
          await tester.enterText(field('Search location'), 'Anna Nagar');
          await submitMapSearch(tester);
          await tester.pumpAndSettle();
          expect(
            find.widgetWithText(ListTile, 'Anna Nagar, Chennai'),
            findsOneWidget,
          );
          await tester.ensureVisible(
            find.widgetWithText(ListTile, 'Anna Nagar, Madurai'),
          );
          await tester.tap(
            find.widgetWithText(ListTile, 'Anna Nagar, Madurai'),
          );
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<GoogleMap>(find.byType(GoogleMap))
                .markers
                .single
                .position,
            const LatLng(9.9252, 78.1198),
          );
          expect(
            tester.widget<TextField>(field('Search location')).controller!.text,
            'Anna Nagar, Madurai',
          );
          final map =
              GoogleMapsFlutterPlatform.instance as FakeVisitMapPlatform;
          expect(
            map.calls.any((call) => call.method == 'camera#animate'),
            isTrue,
          );
          await continueToEvent(tester, mapLink: null);
          final saved = requests.singleWhere(
            (request) =>
                request.method == 'POST' &&
                request.url.host == 'erp.example.test' &&
                request.bodyFields['action'] == 'save_location',
          );
          expect(saved.bodyFields['latitude'], '9.9252');
          expect(saved.bodyFields['longitude'], '78.1198');
          expect(
            saved.bodyFields['map_link'],
            contains('query=9.9252,78.1198'),
          );
          expect(
            requests
                .where((request) => request.url.host == 'places.googleapis.com')
                .length,
            2,
          );
          expect(tester.takeException(), isNull);
        },
        requests: requests,
        onLocationSearch: (request) async {
          expect(jsonDecode(request.body)['input'], 'Anna Nagar');
          return locationResults();
        },
      );
    },
  );

  testWidgets(
    'location search without matches leaves the existing pin intact',
    (tester) async {
      await withForm(
        tester,
        [initialOpportunities.first],
        () async {
          tester.widget<GoogleMap>(find.byType(GoogleMap)).onTap!(
            const LatLng(13, 80),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(field('Search location'));
          await tester.enterText(field('Search location'), 'Unknown address');
          await submitMapSearch(tester);
          await tester.pumpAndSettle();
          expect(
            find.text('No locations found. Try a more specific address.'),
            findsOneWidget,
          );
          expect(
            tester
                .widget<GoogleMap>(find.byType(GoogleMap))
                .markers
                .single
                .position,
            const LatLng(13, 80),
          );
          expect(tester.takeException(), isNull);
        },
        onLocationSearch:
            (_) async => http.Response(jsonEncode({'suggestions': []}), 200),
      );
    },
  );

  testWidgets('location-search timeout and service errors allow a retry', (
    tester,
  ) async {
    var attempts = 0;
    await withForm(
      tester,
      [initialOpportunities.first],
      () async {
        await tester.ensureVisible(field('Search location'));
        await tester.enterText(field('Search location'), 'Anna Nagar');
        await submitMapSearch(tester);
        await tester.pumpAndSettle();
        expect(
          find.text('Location search timed out. Please try again.'),
          findsOneWidget,
        );
        await submitMapSearch(tester);
        await tester.pumpAndSettle();
        expect(
          find.text('Location search is unavailable. Please try again.'),
          findsOneWidget,
        );
        await submitMapSearch(tester);
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(ListTile, 'Anna Nagar, Chennai'),
          findsOneWidget,
        );
        expect(attempts, 3);
        expect(tester.takeException(), isNull);
      },
      onLocationSearch: (_) async {
        attempts++;
        if (attempts == 1) throw TimeoutException('Simulated server delay');
        if (attempts == 2) {
          return http.Response(
            jsonEncode({
              'error': {'status': 'PERMISSION_DENIED'},
            }),
            403,
          );
        }
        return locationResults();
      },
    );
  });

  testWidgets('changing a location-search query ignores the older response', (
    tester,
  ) async {
    final oldSearch = Completer<http.Response>();
    await withForm(
      tester,
      [initialOpportunities.first],
      () async {
        await tester.ensureVisible(field('Search location'));
        await tester.enterText(field('Search location'), 'Old address');
        await submitMapSearch(tester);
        await tester.pump();
        await tester.enterText(field('Search location'), 'Anna Nagar');
        await tester.pump();
        await submitMapSearch(tester);
        await tester.pumpAndSettle();
        oldSearch.complete(
          http.Response(
            jsonEncode({
              'status': 'OK',
              'results': [
                {
                  'formatted_address': 'Old address result',
                  'geometry': {
                    'location': {'lat': 10, 'lng': 70},
                  },
                },
              ],
            }),
            200,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Old address result'), findsNothing);
        expect(
          find.widgetWithText(ListTile, 'Anna Nagar, Chennai'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
      onLocationSearch:
          (request) =>
              jsonDecode(request.body)['input'] == 'Old address'
                  ? oldSearch.future
                  : Future.value(locationResults()),
    );
  });

  testWidgets(
    'choosing a map pin cancels pending location-search suggestions',
    (tester) async {
      final pendingSearch = Completer<http.Response>();
      await withForm(tester, [initialOpportunities.first], () async {
        await tester.ensureVisible(field('Search location'));
        await tester.enterText(field('Search location'), 'Anna Nagar');
        await submitMapSearch(tester);
        await tester.pump();
        tester.widget<GoogleMap>(find.byType(GoogleMap)).onTap!(
          const LatLng(12, 77),
        );
        await tester.pump();
        pendingSearch.complete(locationResults());
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(ListTile, 'Anna Nagar, Chennai'),
          findsNothing,
        );
        expect(
          tester
              .widget<GoogleMap>(find.byType(GoogleMap))
              .markers
              .single
              .position,
          const LatLng(12, 77),
        );
        expect(tester.takeException(), isNull);
      }, onLocationSearch: (_) => pendingSearch.future);
    },
  );

  testWidgets(
    'empty location search prompts for an address without requesting data',
    (tester) async {
      final requests = <http.Request>[];
      await withForm(tester, [initialOpportunities.first], () async {
        await tester.ensureVisible(field('Search location'));
        await submitMapSearch(tester);
        await tester.pumpAndSettle();
        expect(find.text('Enter an address, area or city.'), findsOneWidget);
        expect(
          requests.any(
            (request) => request.url.host == 'places.googleapis.com',
          ),
          isFalse,
        );
      }, requests: requests);
    },
  );

  testWidgets(
    'assignee recommendations filter by username and save the selected user',
    (tester) async {
      final requests = <http.Request>[];
      await withForm(tester, [initialOpportunities.first], () async {
        await continueToEvent(tester);
        expect(selectedValue(tester, 'Assigned to *'), 'sales@example.test');
        final requestCount = requests.length;
        await tester.ensureVisible(field('Assigned to *'));
        await tester.tap(field('Assigned to *'));
        await tester.pumpAndSettle();
        final firstSuggestion =
            tester.widget<ListTile>(find.byType(ListTile).first).title as Text;
        expect(firstSuggestion.data, 'Assign to me (sales@example.test)');
        await tester.enterText(field('Search username'), 'INSTALLER');
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(ListTile, 'installer@example.test'),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(ListTile, 'Assign to me (sales@example.test)'),
          findsNothing,
        );
        await tester.tap(
          find.widgetWithText(ListTile, 'installer@example.test'),
        );
        await tester.pumpAndSettle();
        expect(
          selectedValue(tester, 'Assigned to *'),
          'installer@example.test',
        );
        expect(requests.length, requestCount);
        expect(tester.takeException(), isNull);
      }, requests: requests);
    },
  );

  testWidgets(
    'an unmatched assignee search and cancellation retain the prefilled user',
    (tester) async {
      await withForm(tester, [phoneMatch], () async {
        await continueToEvent(tester);
        expect(
          selectedValue(tester, 'Assigned to *'),
          'installer@example.test',
        );
        await tester.ensureVisible(field('Assigned to *'));
        await tester.tap(field('Assigned to *'));
        await tester.pumpAndSettle();
        await tester.enterText(field('Search username'), 'no-such-user');
        await tester.pumpAndSettle();
        expect(find.text('No matching users.'), findsOneWidget);
        expect(find.byType(ListTile), findsNothing);
        Navigator.of(tester.element(find.text('No matching users.'))).pop();
        await tester.pumpAndSettle();
        expect(
          selectedValue(tester, 'Assigned to *'),
          'installer@example.test',
        );
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'map tap and dragged pin save coordinates and display login usernames',
    (tester) async {
      final requests = <http.Request>[];
      await withForm(tester, [initialOpportunities.first], () async {
        var map = tester.widget<GoogleMap>(find.byType(GoogleMap));
        expect(map.zoomGesturesEnabled, isTrue);
        expect(map.zoomControlsEnabled, isTrue);
        expect(map.scrollGesturesEnabled, isTrue);
        map.onTap!(const LatLng(13.12, 80.25));
        await tester.pumpAndSettle();
        map = tester.widget<GoogleMap>(find.byType(GoogleMap));
        expect(map.markers.single.position, const LatLng(13.12, 80.25));
        expect(map.markers.single.draggable, isTrue);
        map.markers.single.onDragEnd!(const LatLng(13.12345, 80.25678));
        await tester.pumpAndSettle();
        final link =
            tester
                .widget<TextField>(field('Customer map link *'))
                .controller!
                .text;
        expect(Uri.parse(link).queryParameters['query'], '13.12345,80.25678');
        await continueToEvent(tester, mapLink: null);
        final saved = requests.singleWhere(
          (request) =>
              request.method == 'POST' &&
              request.bodyFields['action'] == 'save_location',
        );
        expect(saved.bodyFields['latitude'], '13.12345');
        expect(saved.bodyFields['longitude'], '80.25678');
        expect(saved.bodyFields['map_link'], link);
        expect(
          requests.any((request) => request.url.host.contains('google.com')),
          isFalse,
        );
        await tester.ensureVisible(dropdown('Assigned to *'));
        await tester.tap(dropdown('Assigned to *'));
        await tester.pumpAndSettle();
        expect(find.text('installer@example.test'), findsWidgets);
        expect(find.text('Assign to me (sales@example.test)'), findsWidgets);
        expect(find.text('Installer'), findsNothing);
        await tester.tap(find.text('installer@example.test').last);
        await tester.pumpAndSettle();
        expect(
          selectedValue(tester, 'Assigned to *'),
          'installer@example.test',
        );
        expect(tester.takeException(), isNull);
      }, requests: requests);
    },
  );

  testWidgets(
    'pasted coordinate link places a pin, centers the map and saves the same location',
    (tester) async {
      final requests = <http.Request>[];
      await withForm(tester, [initialOpportunities.first], () async {
        const link = 'https://maps.google.com/?q=12.95,77.61';
        await tester.enterText(field('Customer map link *'), link);
        await tester.ensureVisible(find.text('Show link on map'));
        await tester.tap(find.text('Show link on map'));
        await tester.pumpAndSettle();
        final map = tester.widget<GoogleMap>(find.byType(GoogleMap));
        expect(map.markers.single.position, const LatLng(12.95, 77.61));
        final platform =
            GoogleMapsFlutterPlatform.instance as FakeVisitMapPlatform;
        expect(
          platform.calls.any((call) => call.method == 'camera#animate'),
          isTrue,
        );
        await continueToEvent(tester, mapLink: null);
        final saved = requests.singleWhere(
          (request) =>
              request.method == 'POST' &&
              request.bodyFields['action'] == 'save_location',
        );
        expect(saved.bodyFields['latitude'], '12.95');
        expect(saved.bodyFields['longitude'], '77.61');
        expect(saved.bodyFields['map_link'], link);
        expect(
          requests.any((request) => request.url.host.contains('google.com')),
          isFalse,
        );
        expect(tester.takeException(), isNull);
      }, requests: requests);
    },
  );

  testWidgets(
    'editing a link invalidates the selected pin and saves new coordinates',
    (tester) async {
      final requests = <http.Request>[];
      await withForm(tester, [initialOpportunities.first], () async {
        tester.widget<GoogleMap>(find.byType(GoogleMap)).onTap!(
          const LatLng(13, 80),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          field('Customer map link *'),
          'https://maps.google.com/?q=12,77',
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<GoogleMap>(find.byType(GoogleMap)).markers,
          isEmpty,
        );
        await continueToEvent(tester, mapLink: null);
        final saved = requests.singleWhere(
          (request) =>
              request.method == 'POST' &&
              request.bodyFields['action'] == 'save_location',
        );
        expect(saved.bodyFields['latitude'], '12.0');
        expect(saved.bodyFields['longitude'], '77.0');
        expect(tester.takeException(), isNull);
      }, requests: requests);
    },
  );

  testWidgets(
    'a shortened map link is resolved once and its original URL is saved',
    (tester) async {
      final requests = <http.Request>[];
      await withForm(
        tester,
        [initialOpportunities.first],
        () async {
          const link = 'https://maps.app.goo.gl/test-location';
          await tester.enterText(field('Customer map link *'), link);
          await tester.ensureVisible(find.text('Show link on map'));
          await tester.tap(find.text('Show link on map'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<GoogleMap>(find.byType(GoogleMap))
                .markers
                .single
                .position,
            const LatLng(13, 80),
          );
          await continueToEvent(tester, mapLink: null);
          final saved = requests.singleWhere(
            (request) =>
                request.method == 'POST' &&
                request.bodyFields['action'] == 'save_location',
          );
          expect(saved.bodyFields['map_link'], link);
          expect(saved.bodyFields['latitude'], '13.0');
          expect(
            requests
                .where((request) => request.url.host == 'maps.app.goo.gl')
                .length,
            1,
          );
          expect(
            requests
                .where((request) => request.url.host == 'maps.google.com')
                .length,
            1,
          );
          expect(tester.takeException(), isNull);
        },
        requests: requests,
        onMapRequest:
            (request) async =>
                request.url.host == 'maps.app.goo.gl'
                    ? http.Response(
                      '',
                      302,
                      headers: {'location': 'https://maps.google.com/?q=13,80'},
                    )
                    : http.Response('', 200),
      );
    },
  );

  testWidgets('a delayed link preview cannot overwrite a newer map selection', (
    tester,
  ) async {
    final oldPreview = Completer<http.Response>();
    await withForm(
      tester,
      [initialOpportunities.first],
      () async {
        await tester.enterText(
          field('Customer map link *'),
          'https://maps.app.goo.gl/old-location',
        );
        await tester.ensureVisible(find.text('Show link on map'));
        await tester.tap(find.text('Show link on map'));
        await tester.pump();
        tester.widget<GoogleMap>(find.byType(GoogleMap)).onTap!(
          const LatLng(12, 77),
        );
        await tester.pump();
        oldPreview.complete(
          http.Response(
            '',
            302,
            headers: {'location': 'https://maps.google.com/?q=13,80'},
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<GoogleMap>(find.byType(GoogleMap))
              .markers
              .single
              .position,
          const LatLng(12, 77),
        );
        expect(
          tester
              .widget<TextField>(field('Customer map link *'))
              .controller!
              .text,
          contains('query=12.0,77.0'),
        );
        expect(tester.takeException(), isNull);
      },
      onMapRequest:
          (request) =>
              request.url.host == 'maps.app.goo.gl'
                  ? oldPreview.future
                  : Future.value(http.Response('', 200)),
    );
  });

  testWidgets('phone lookup prefills without extra session-check requests', (
    tester,
  ) async {
    final requests = <http.Request>[];
    await withForm(
      tester,
      initialOpportunities,
      () async {
        await tester.enterText(field('Mobile number'), '8667733611');
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(field('Opportunity *')).controller!.text,
          'Phone match',
        );
        expect(selectedValue(tester, 'Product enquired'), 'Windows');
        expect(
          requests
              .where(
                (request) =>
                    request.url.queryParameters['action'] == 'search_by_mobile',
              )
              .length,
          1,
        );
        expect(
          requests.any(
            (request) =>
                request.url.path.endsWith('frappe.auth.get_logged_user'),
          ),
          isFalse,
        );
        await continueToEvent(tester);
        expect(
          selectedValue(tester, 'Assigned to *'),
          'installer@example.test',
        );
      },
      requests: requests,
      onSearch: (_) async => searchResponse([phoneMatch]),
    );
  });

  testWidgets('failed phone search hides unrelated suggestions and can retry', (
    tester,
  ) async {
    var attempts = 0;
    await withForm(
      tester,
      initialOpportunities,
      () async {
        await tester.tap(field('Opportunity *'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(ListTile, 'Lokesh'), findsOneWidget);
        await tester.enterText(field('Mobile number'), '8667733611');
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        expect(
          find.text('Phone search timed out. Swipe down to try again.'),
          findsOneWidget,
        );
        await tester.tap(field('Opportunity *'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(ListTile, 'Lokesh'), findsNothing);
        expect(selectedValue(tester, 'Product enquired'), isNull);
        await tester
            .widget<RefreshIndicator>(find.byType(RefreshIndicator))
            .onRefresh();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(field('Opportunity *')).controller!.text,
          'Phone match',
        );
        expect(selectedValue(tester, 'Product enquired'), 'Windows');
        expect(attempts, 2);
      },
      onSearch: (_) async {
        if (++attempts == 1) throw TimeoutException('Simulated slow server');
        return searchResponse([phoneMatch]);
      },
    );
  });

  testWidgets('older phone response cannot overwrite a newly entered number', (
    tester,
  ) async {
    final oldSearch = Completer<http.Response>();
    final newSearch = Completer<http.Response>();
    await withForm(
      tester,
      initialOpportunities,
      () async {
        await tester.enterText(field('Mobile number'), '86677');
        await tester.pump(const Duration(milliseconds: 600));
        await tester.enterText(field('Mobile number'), '8667733611');
        oldSearch.complete(searchResponse([initialOpportunities.first]));
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          tester.widget<TextField>(field('Opportunity *')).controller!.text,
          '',
        );
        expect(selectedValue(tester, 'Product enquired'), isNull);
        await tester.pump(const Duration(milliseconds: 600));
        newSearch.complete(searchResponse([phoneMatch]));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(field('Opportunity *')).controller!.text,
          'Phone match',
        );
        expect(selectedValue(tester, 'Product enquired'), 'Windows');
      },
      onSearch:
          (request) =>
              request.url.queryParameters['mobile'] == '86677'
                  ? oldSearch.future
                  : newSearch.future,
    );
  });

  testWidgets('opportunity product prefills and can be changed for the event', (
    tester,
  ) async {
    await withForm(
      tester,
      [
        {
          'name': 'OPP-1',
          'title': 'Lokesh',
          'party_name': 'LEAD-1',
          'product_enquired': "D'sign Doors",
          'assigned_to': 'installer@example.test',
        },
        {
          'name': 'OPP-2',
          'title': 'Nami',
          'party_name': 'LEAD-2',
          'product_enquired': '',
          'assigned_to': 'sales@example.test',
        },
      ],
      () async {
        await tester.enterText(field('Opportunity *'), 'Lokesh');
        await tester.pumpAndSettle();
        expect(find.text('OPP-1'), findsOneWidget);
        await tester.tap(find.widgetWithText(ListTile, 'Lokesh'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<DropdownButtonFormField<String>>(
                dropdown('Product enquired'),
              )
              .initialValue,
          "D'sign Doors",
        );

        await tester.ensureVisible(dropdown('Product enquired'));
        await tester.tap(dropdown('Product enquired'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Windows').last);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<DropdownButtonFormField<String>>(
                dropdown('Product enquired'),
              )
              .initialValue,
          'Windows',
        );

        await continueToEvent(tester);
        expect(find.text('Event Details'), findsOneWidget);
        expect(find.text('Windows'), findsOneWidget);
        expect(
          selectedValue(tester, 'Assigned to *'),
          'installer@example.test',
        );
        await tester.ensureVisible(dropdown('Assigned to *'));
        await tester.tap(dropdown('Assigned to *'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Assign to me (sales@example.test)').last);
        await tester.pumpAndSettle();
        expect(selectedValue(tester, 'Assigned to *'), 'sales@example.test');
        expect(find.text('Site Visit'), findsOneWidget);

        await tester.ensureVisible(find.text('Edit customer location'));
        await tester.tap(find.text('Edit customer location'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(field('Opportunity *'));
        await tester.enterText(field('Opportunity *'), 'Nami');
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, 'Nami'));
        await tester.pumpAndSettle();
        expect(selectedValue(tester, 'Product enquired'), isNull);
        await continueToEvent(tester);
        expect(selectedValue(tester, 'Assigned to *'), 'sales@example.test');
        expect(tester.takeException(), isNull);
      },
    );
  });

  testWidgets(
    'a single opportunity automatically supplies its user and product',
    (tester) async {
      await withForm(
        tester,
        [
          {
            'name': 'OPP-1',
            'title': 'Lokesh',
            'party_name': 'LEAD-1',
            'product_enquired': "D'sign Doors",
            'assigned_to': 'installer@example.test',
          },
        ],
        () async {
          expect(selectedValue(tester, 'Product enquired'), "D'sign Doors");
          await continueToEvent(tester);
          expect(
            selectedValue(tester, 'Assigned to *'),
            'installer@example.test',
          );
          expect(tester.takeException(), isNull);
        },
      );
    },
  );

  testWidgets(
    'opportunity without a product prompts selection and allows a choice',
    (tester) async {
      await withForm(
        tester,
        [
          {
            'name': 'OPP-2',
            'title': 'Nami',
            'party_name': 'LEAD-2',
            'product_enquired': '',
          },
        ],
        () async {
          final product = dropdown('Product enquired');
          expect(
            tester
                .widget<DropdownButtonFormField<String>>(product)
                .initialValue,
            isNull,
          );
          expect(find.text('Select product enquired'), findsWidgets);
          await tester.tap(product);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Windows').last);
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<DropdownButtonFormField<String>>(product)
                .initialValue,
            'Windows',
          );
          expect(tester.takeException(), isNull);
        },
      );
    },
  );
}
