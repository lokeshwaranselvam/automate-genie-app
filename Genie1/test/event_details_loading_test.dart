import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:homegenie/Screen/event_details.dart';
import 'package:homegenie/utils/widget/ag_path_loading_indicator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    SharedPreferences.setMockInitialValues({
      'token': 'token test',
      'email': 'user@example.test',
      'session_sid': 'sid',
      'session_username': 'user@example.test',
    });
    dotenv.testLoad(
      fileInput:
          'SITE_URL=https://erp.example.test\nURL=https://erp.example.test/api/method/example.api',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [
      'flutter.baseflow.com/permissions/methods',
      'PHONE_STATE_STREAM',
      'dexterous.com/flutter/local_notifications',
      'com.ryanheise.just_audio.methods',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), (call) async {
        if (call.method == 'requestPermissions') return <int, int>{3: 0, 8: 0};
        if (call.method == 'initialize') return true;
        return null;
      });
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/geolocator'),
      (_) async => false,
    );
  });

  for (final scenario in [
    'completed-image',
    'completed-document',
    'completed-details',
    'pending',
    'error',
    'invalid',
    'names',
    'Other',
    'Head Office CH',
    'Timbe / Bioman Office CH',
    'Collection',
    'saved-location-enabled',
    'saved-location-disabled',
    'checkin-radius-small',
    'checkin-radius-large',
    'checkin-radius-disabled',
    'checkout-photo-required',
    'checkout-photo-optional',
  ]) {
    testWidgets(
      'task details handles $scenario without enabling premature actions',
      (tester) async {
        final pending = Completer<http.Response>();
        var attempts = 0;
        var checkInRequests = 0;
        var checkOutRequests = 0;
        final client = MockClient((request) async {
          if (request.url.path.endsWith('event_visit_report')) {
            return http.Response(
              jsonEncode({
                'message': {
                  'status': 'success',
                  if (scenario == 'completed-image' ||
                      scenario == 'completed-document') ...{
                    'event_id': 'EVENT-1',
                    'attachments': [
                      {
                        'file_name': 'visit',
                        'file_url':
                            scenario == 'completed-image'
                                ? '/private/files/visit.JPG'
                                : '/private/files/visit.pdf',
                      },
                    ],
                  },
                  if (scenario.startsWith('saved-location-'))
                    'requires_saved_location':
                        scenario == 'saved-location-enabled',
                  if (scenario.startsWith('checkin-radius-'))
                    'visit_checkin_radius_meters':
                        scenario == 'checkin-radius-small' ? 50 : 250,
                  if (scenario == 'checkin-radius-disabled') ...{
                    'visit_checkin_radius_meters': 50,
                    'visit_geofencing_enabled': false,
                  },
                  if (scenario.startsWith('checkout-photo-'))
                    'requires_checkout_photo':
                        scenario == 'checkout-photo-required',
                },
              }),
              200,
            );
          }
          if (request.url.path.endsWith('event_checkin')) {
            checkInRequests++;
            return http.Response(
              '{"message":{"status":"error","message":"Check-in API reached"}}',
              200,
            );
          }
          if (request.url.path.endsWith('event_checkout')) {
            checkOutRequests++;
            return http.Response(
              '{"message":{"status":"error","message":"Check-out API reached"}}',
              200,
            );
          }
          if (request.url.path.endsWith('/ping')) {
            return http.Response('{"message":"pong"}', 200);
          }
          if (request.url.path.endsWith('get_logged_user')) {
            return http.Response('{"message":"user@example.test"}', 200);
          }
          if (request.url.path.endsWith('event_details')) {
            attempts++;
            if (attempts == 1 && scenario == 'pending') return pending.future;
            if (attempts == 1 && scenario == 'error') {
              return http.Response('{}', 500);
            }
            if (attempts == 1 && scenario == 'invalid') {
              return http.Response('{"message":[]}', 200);
            }
            return http.Response(
              jsonEncode({
                'message': {
                  'event': {
                    'name': 'EVENT-1',
                    'subject': 'Bank task loaded',
                    'event_category':
                        [
                              'Other',
                              'Head Office CH',
                              'Timbe / Bioman Office CH',
                              'Collection',
                            ].contains(scenario)
                            ? scenario
                            : scenario.startsWith('saved-location-') ||
                                scenario.startsWith('checkin-radius-')
                            ? 'Site Visit'
                            : 'Bank',
                    if (scenario.startsWith('checkin-radius-')) ...{
                      'custom_location_type': 'Site',
                      'custom_validate':
                          'https://maps.google.com/?q=13.05,80.2',
                    },
                    'owner': 'owner@example.test',
                    if (scenario == 'completed-image' ||
                        scenario == 'completed-document') ...{
                      'custom_check_in': '2026-10-26 09:00:00',
                      'custom_check_out': '2026-10-26 10:00:00',
                    },
                    if (scenario.startsWith('checkout-photo-'))
                      'custom_check_in': '2026-10-26 09:00:00',
                    'starts_on': DateTime.now().toIso8601String(),
                  },
                  'reference_details': [],
                },
              }),
              200,
            );
          }
          if (scenario == 'names') return pending.future;
          return http.Response('{"message":null}', 200);
        });
        await http.runWithClient(() async {
          await tester.pumpWidget(
            MaterialApp(
              home: EventDetails(
                eventid: 'EVENT-1',
                hideVisitActions: scenario.startsWith('completed-'),
              ),
            ),
          );
          for (var i = 0; i < 12; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          final checkIn = find.widgetWithText(
            ElevatedButton,
            scenario.startsWith('checkout-photo-') ? 'Check Out' : 'Check In',
          );
          if (scenario.startsWith('completed-')) {
            expect(find.text('Check In'), findsNothing);
            expect(find.text('Check Out'), findsNothing);
          } else {
            expect(find.text('Check In'), findsOneWidget);
            expect(find.text('Check Out'), findsOneWidget);
          }
          if (scenario == 'pending') {
            expect(tester.widget<ElevatedButton>(checkIn).onPressed, isNull);
            await tester.pump(const Duration(seconds: 26));
            await tester.pump();
          } else {
            await tester.pump(const Duration(milliseconds: 300));
          }
          expect(find.byType(AgPathLoadingIndicator), findsNothing);
          if ([
            'completed-image',
            'completed-document',
            'completed-details',
            'names',
            'Other',
            'Head Office CH',
            'Timbe / Bioman Office CH',
            'Collection',
            'saved-location-enabled',
            'saved-location-disabled',
            'checkin-radius-small',
            'checkin-radius-large',
            'checkin-radius-disabled',
            'checkout-photo-required',
            'checkout-photo-optional',
          ].contains(scenario)) {
            expect(find.text('Bank task loaded'), findsWidgets);
            if (scenario.startsWith('completed-')) {
              expect(checkIn, findsNothing);
            } else {
              expect(
                tester.widget<ElevatedButton>(checkIn).onPressed,
                isNotNull,
              );
            }
            if (scenario == 'completed-image' ||
                scenario == 'completed-document') {
              expect(
                find.text(
                  scenario == 'completed-image'
                      ? 'Checklist (4/4)'
                      : 'Checklist (3/4)',
                ),
                findsOneWidget,
              );
              final photoRow =
                  find
                      .ancestor(
                        of: find.text('Photos captured'),
                        matching: find.byType(Row),
                      )
                      .first;
              expect(
                tester
                    .widget<Checkbox>(
                      find.descendant(
                        of: photoRow,
                        matching: find.byType(Checkbox),
                      ),
                    )
                    .value,
                scenario == 'completed-image',
              );
              await tester.ensureVisible(find.text('View All'));
              await tester.tap(find.text('View All'));
              await tester.pumpAndSettle();
              final photoTile = find.widgetWithText(
                ListTile,
                'Photos captured',
              );
              expect(
                find.descendant(
                  of: photoTile,
                  matching: find.byIcon(
                    scenario == 'completed-image'
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                  ),
                ),
                findsOneWidget,
              );
              Navigator.of(tester.element(photoTile)).pop();
              await tester.pumpAndSettle();
            }
            pending.complete(http.Response('{"message":null}', 200));
            if (scenario.startsWith('saved-location-') ||
                scenario.startsWith('checkin-radius-') ||
                scenario.startsWith('checkout-photo-')) {
              final dynamic state = tester.state(find.byType(EventDetails));
              if (scenario.startsWith('checkout-photo-')) {
                final position = Position(
                  latitude: 13.05,
                  longitude: 80.2,
                  timestamp: DateTime.now(),
                  accuracy: 5,
                  altitude: 0,
                  altitudeAccuracy: 0,
                  heading: 0,
                  headingAccuracy: 0,
                  speed: 0,
                  speedAccuracy: 0,
                );
                await state.performCheckout(
                  userEmail: 'user@example.test',
                  eventId: 'EVENT-1',
                  lat: 13.05,
                  lng: 80.2,
                  address: 'Test GPS address',
                  workingHrs: '01:00',
                  position: position,
                );
                expect(
                  checkOutRequests,
                  scenario == 'checkout-photo-optional' ? 1 : 0,
                );
              } else {
                await state.performCheckIn(
                  userEmail: 'user@example.test',
                  eventId: 'EVENT-1',
                  lat:
                      scenario.startsWith('checkin-radius-') ? 13.05135 : 13.05,
                  lng: 80.2,
                  address: 'Test GPS address',
                );
              }
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 300));
              final required =
                  scenario == 'saved-location-enabled' ||
                  scenario == 'checkin-radius-small';
              if (!scenario.startsWith('checkout-photo-')) {
                expect(checkInRequests, required ? 0 : 1);
              }
              // Dismiss queued startup/GPS and check-in notices before disposal.
              for (var i = 0; i < 4; i++) {
                final close = find.byTooltip('Close');
                if (close.evaluate().isEmpty) break;
                await tester.tap(close.last);
                await tester.pump(const Duration(milliseconds: 400));
                await tester.pump();
              }
            }
          } else {
            expect(find.text('Retry task details'), findsOneWidget);
            expect(tester.widget<ElevatedButton>(checkIn).onPressed, isNull);
            await tester.tap(find.text('Retry task details'));
            for (var i = 0; i < 12; i++) {
              await tester.pump(const Duration(milliseconds: 50));
            }
            expect(find.text('Bank task loaded'), findsWidgets);
            expect(tester.widget<ElevatedButton>(checkIn).onPressed, isNotNull);
            if (!pending.isCompleted) {
              pending.complete(http.Response('{}', 500));
            }
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 30));
        }, () => client);
      },
    );
  }
}
