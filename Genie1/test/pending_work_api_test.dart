import 'dart:async';
import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/pending_work_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const user = 'staff@example.test';
const task = {'name': 'TASK & 1', 'subject': 'Test'};

http.Response success(Map<String, dynamic> message) =>
    http.Response(jsonEncode({'message': message}), 200);

http.Response tasks({String? token, String assignedUser = user}) => success({
  'assigned_to_only': true,
  'assigned_user': assignedUser,
  'task_data': [task],
  if (token != null) 'csrf_token': token,
});

http.Response csrfFailure() => http.Response(
  jsonEncode({
    'exc_type': 'CSRFTokenError',
    '_server_messages': jsonEncode([
      jsonEncode({'message': 'Invalid Request'}),
    ]),
  }),
  400,
);

Future<http.Response> loggedUserOr(
  http.Request request,
  Future<http.Response> Function(http.Request) handler,
) async =>
    request.url.path.endsWith('get_logged_user')
        ? http.Response(jsonEncode({'message': user}), 200)
        : handler(request);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var sessionNumber = 0;
  late String sessionId;
  setUp(() {
    sessionId = 'task-session-${++sessionNumber}';
    SharedPreferences.setMockInitialValues({
      'session_sid': sessionId,
      'session_username': user,
    });
    FlutterSecureStorage.setMockInitialValues({});
    dotenv.testLoad(fileInput: 'SITE_URL=https://erp.example.test');
  });

  test(
    'missing token is initialized once and reused for subsequent tasks',
    () async {
      var desk = 0;
      final posts = <http.Request>[];
      await http.runWithClient(
        () async {
          expect(
            (await PendingWorkApi.getPendingTasks()).single['name'],
            task['name'],
          );
          await PendingWorkApi.completePendingTask(task);
          await PendingWorkApi.getPendingTasks(); // Missing token must not erase it.
          await PendingWorkApi.completePendingTask({'task_id': 'TASK-2'});
        },
        () => MockClient(
          (request) => loggedUserOr(request, (request) async {
            expect(request.headers['Cookie'], 'sid=$sessionId');
            if (request.url.path == '/app') {
              desk++;
              expect(request.followRedirects, isFalse);
              return http.Response('frappe.csrf_token = "desk-token";', 200);
            }
            if (request.method == 'GET') return tasks();
            posts.add(request);
            return success({'status': 'success'});
          }),
        ),
      );
      expect(desk, 1);
      expect(posts.length, 2);
      expect(posts.first.url.queryParameters, {
        'action': 'complete',
        'task_id': 'TASK & 1',
      });
      for (final post in posts) {
        expect(post.headers['X-Frappe-CSRF-Token'], 'desk-token');
        expect(post.bodyFields, {'csrf_token': 'desk-token'});
      }
    },
  );

  test('valid list token avoids a bootstrap request', () async {
    var posts = 0;
    await http.runWithClient(
      () async {
        await PendingWorkApi.getPendingTasks();
        await PendingWorkApi.completePendingTask(task);
      },
      () => MockClient(
        (request) => loggedUserOr(request, (request) async {
          expect(request.url.path, '/api/method/my_assigned_tasks');
          if (request.method == 'GET') return tasks(token: 'list-token');
          posts++;
          expect(request.headers['X-Frappe-CSRF-Token'], 'list-token');
          return success({'status': 'success'});
        }),
      ),
    );
    expect(posts, 1);
  });

  test(
    'explicit CSRF rejection refreshes and retries once with fresh token',
    () async {
      final tokens = <String?>[];
      await http.runWithClient(
        () async {
          await PendingWorkApi.getPendingTasks();
          await PendingWorkApi.completePendingTask(task);
          await PendingWorkApi.completePendingTask({'id': 'TASK-2'});
        },
        () => MockClient(
          (request) => loggedUserOr(request, (request) async {
            if (request.url.path == '/app') {
              return http.Response("frappe.csrf_token = 'fresh-token';", 200);
            }
            if (request.method == 'GET') return tasks(token: 'stale-token');
            tokens.add(request.bodyFields['csrf_token']);
            return tokens.length == 1
                ? csrfFailure()
                : success({'status': 'success'});
          }),
        ),
      );
      expect(tokens, ['stale-token', 'fresh-token', 'fresh-token']);
    },
  );

  for (final failure in ['validation', 'permission', 'timeout', 'csrf']) {
    test('$failure failure has no unsafe or unlimited retry', () async {
      var posts = 0;
      await http.runWithClient(
        () async {
          await PendingWorkApi.getPendingTasks();
          await expectLater(
            PendingWorkApi.completePendingTask(task),
            throwsA(
              failure == 'timeout'
                  ? isA<TimeoutException>()
                  : isA<StateError>(),
            ),
          );
        },
        () => MockClient(
          (request) => loggedUserOr(request, (request) async {
            if (request.url.path == '/app') {
              return http.Response('frappe.csrf_token="new-token";', 200);
            }
            if (request.method == 'GET') return tasks(token: 'list-token');
            posts++;
            if (failure == 'timeout') {
              throw TimeoutException('Network interrupted');
            }
            if (failure == 'csrf') return csrfFailure();
            return http.Response(
              jsonEncode({'message': 'Invalid Request'}),
              failure == 'permission' ? 403 : 400,
            );
          }),
        ),
      );
      expect(posts, failure == 'csrf' ? 2 : 1);
    });
  }

  test(
    'session change requires list reload instead of using another user token',
    () async {
      var posts = 0;
      await http.runWithClient(
        () async {
          await PendingWorkApi.getPendingTasks();
          await (await SharedPreferences.getInstance()).setString(
            'session_sid',
            'other-session',
          );
          await expectLater(
            PendingWorkApi.completePendingTask(task),
            throwsStateError,
          );
        },
        () => MockClient(
          (request) => loggedUserOr(request, (request) async {
            if (request.method == 'POST') posts++;
            return tasks(token: 'list-token');
          }),
        ),
      );
      expect(posts, 0);
    },
  );

  test('session changes during token bootstrap prevent submission', () async {
    var posts = 0;
    await http.runWithClient(
      () async {
        await PendingWorkApi.getPendingTasks();
        await expectLater(
          PendingWorkApi.completePendingTask(task),
          throwsStateError,
        );
      },
      () => MockClient(
        (request) => loggedUserOr(request, (request) async {
          if (request.url.path == '/app') {
            await (await SharedPreferences.getInstance()).setString(
              'session_sid',
              'other-session',
            );
            return http.Response('frappe.csrf_token="other-token";', 200);
          }
          if (request.method == 'POST') posts++;
          return tasks();
        }),
      ),
    );
    expect(posts, 0);
  });

  test(
    'bootstrap refuses cross-site redirect without sending a cookie there',
    () async {
      await http.runWithClient(
        () async {
          await PendingWorkApi.getPendingTasks();
          await expectLater(
            PendingWorkApi.completePendingTask(task),
            throwsStateError,
          );
        },
        () => MockClient(
          (request) => loggedUserOr(request, (request) async {
            expect(request.url.host, 'erp.example.test');
            if (request.url.path == '/app') {
              return http.Response(
                '',
                302,
                headers: {'location': 'https://other.example.test/app'},
              );
            }
            return tasks();
          }),
        ),
      );
    },
  );

  test(
    'wrong assignee is still rejected and missing task ID cannot submit',
    () async {
      var posts = 0;
      await http.runWithClient(
        () async {
          await expectLater(
            PendingWorkApi.getPendingTasks(),
            throwsFormatException,
          );
          await expectLater(
            PendingWorkApi.completePendingTask({}),
            throwsFormatException,
          );
        },
        () => MockClient(
          (request) => loggedUserOr(request, (request) async {
            if (request.method == 'POST') posts++;
            return tasks(assignedUser: 'other@example.test');
          }),
        ),
      );
      expect(posts, 0);
    },
  );

  test(
    'dashboard request remains independent of task CSRF bootstrap',
    () async {
      await http.runWithClient(
        () async {
          expect((await PendingWorkApi.getMobileDashboard())['tasks'], 2);
        },
        () => MockClient(
          (request) => loggedUserOr(request, (request) async {
            expect(request.method, 'GET');
            expect(request.url.path, '/api/method/get_pending_work');
            expect(request.url.queryParameters, {'action': 'dashboard'});
            return success({'tasks': 2});
          }),
        ),
      );
    },
  );
}
