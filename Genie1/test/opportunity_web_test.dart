@TestOn('browser')
library;

import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/opportunity_api.dart';
import 'package:homegenie/utils/api/site_visit_creation_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _user = 'sales@example.test';
const _document = {
  'name': 'OPP-1',
  'owner': _user,
  'status': 'Open',
  'modified': 'version-1',
};

class _Response extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  _Response(String body, this.url)
    : super(Stream.value(utf8.encode(body)), 200);
  @override
  final Uri url;
}

// package:http 1.3 MockClient.streaming strips BaseResponseWithUrl. Preserve
// the browser's final response URL so this test exercises redirect validation.
class _Client extends http.BaseClient {
  _Client(this.handler);
  final Future<http.StreamedResponse> Function(
    http.BaseRequest,
    http.ByteStream,
  )
  handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request, request.finalize());
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'session_sid': 'browser-generation',
      'session_username': _user,
    });
    dotenv.testLoad(fileInput: 'SITE_URL=${Uri.base.origin}/');
  });

  test(
    'browser roles use server flags without injecting a cookie marker',
    () async {
      await http.runWithClient(
        () async {
          final access = await SiteVisitCreationApi.homeQuickActionAccess();
          expect(access.canAddLead, false);
          expect(access.canCreateVisit, false);
          expect(access.canViewPending, true);
        },
        () => MockClient((request) async {
          expect(
            request.headers.keys.map((key) => key.toLowerCase()),
            isNot(contains('cookie')),
          );
          return http.Response(
            jsonEncode({
              'message': {
                'current_user': _user,
                'can_create': false,
                'can_create_lead': false,
                'can_view_pending': true,
              },
            }),
            200,
          );
        }),
      );
    },
  );

  for (final foreignBootstrap in [false, true]) {
    test(
      'browser Opportunity update checks CSRF and final origin: foreign=$foreignBootstrap',
      () async {
        var writes = 0;
        final client = _Client((request, bodyStream) async {
          expect(request.url.origin, Uri.base.origin);
          // Existing session verification headers are stripped by the browser
          // HTTP adapter. New Opportunity requests must not inject a marker.
          if (!request.url.path.endsWith('get_logged_user')) {
            expect(
              request.headers.keys.map((key) => key.toLowerCase()),
              isNot(contains('cookie')),
            );
          }
          Object body;
          if (request.url.path.endsWith('get_logged_user')) {
            body = {'message': _user};
          } else if (request.url.path.endsWith('getdoctype')) {
            body = {
              'docs': [
                {
                  'name': 'Opportunity',
                  'fields': [
                    {
                      'fieldname': 'status',
                      'fieldtype': 'Select',
                      'options': 'Open\nFollow-up',
                    },
                  ],
                },
              ],
            };
          } else if (request.url.path == '/app') {
            expect(request.followRedirects, true);
            return _Response(
              'frappe.csrf_token = "browser-csrf";',
              foreignBootstrap
                  ? Uri.parse('https://other.example.test/app')
                  : request.url.resolve('/app/home'),
            );
          } else if (request.method == 'PUT') {
            writes++;
            expect(request.followRedirects, false);
            expect(request.headers['X-Frappe-CSRF-Token'], 'browser-csrf');
            expect(jsonDecode(await bodyStream.bytesToString()), {
              'status': 'Follow-up',
              'modified': 'version-1',
              'csrf_token': 'browser-csrf',
            });
            body = {
              'data': {..._document, 'status': 'Follow-up'},
            };
          } else {
            body = {'data': _document};
          }
          return _Response(jsonEncode(body), request.url);
        });
        await http.runWithClient(() async {
          final update = OpportunityApi.updateDetails(
            original: _document,
            changes: {'status': 'Follow-up'},
          );
          if (foreignBootstrap) {
            await expectLater(update, throwsStateError);
          } else {
            expect((await update)['status'], 'Follow-up');
          }
        }, () => client);
        expect(writes, foreignBootstrap ? 0 : 1);
      },
    );
  }

  test(
    'plain HTTP ERP outside the current localhost origin is rejected',
    () async {
      dotenv.testLoad(fileInput: 'SITE_URL=http://erp.example.test/');
      await expectLater(OpportunityApi.getMyOpportunities(), throwsStateError);
      await expectLater(OpportunityApi.getEditOptions(), throwsStateError);
    },
  );
}
