import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'session_auth.dart';

String notificationText(dynamic value) =>
    (value?.toString() ?? '')
        .replaceAll(
          RegExp(r'<(?:br\s*/?|/p|/div)>', caseSensitive: false),
          '\n',
        )
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .trim();

class InboxNotification {
  const InboxNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.created,
    required this.category,
    this.reference = '',
    this.read = false,
  });
  final String id, title, body, created, category, reference;
  final bool read;

  static String categoryFor(String value) {
    final type = value.toLowerCase();
    if (type.contains('task') || type.contains('todo')) return 'Tasks';
    if (type.contains('lead') || type.contains('opportunity')) return 'Leads';
    if (type.contains('visit') || type.contains('event')) return 'Visits';
    if (type.contains('pending') ||
        type.contains('stock') ||
        type.contains('job card') ||
        type.contains('manufactur') ||
        type.contains('work_assigned')) {
      return 'Pending Work';
    }
    return 'Other';
  }

  factory InboxNotification.fromJson(Map<String, dynamic> row) =>
      InboxNotification(
        id: row['id'].toString(),
        title: notificationText(row['title']),
        body: notificationText(row['body']),
        created: row['created']?.toString() ?? '',
        category: row['category']?.toString() ?? 'Other',
        reference: row['reference']?.toString() ?? '',
        read: row['read'] == true || row['read'] == 1,
      );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'created': created,
    'category': category,
    'reference': reference,
    'read': read,
  };
}

/// A bounded, per-site and per-user inbox. No push tokens or session secrets
/// are stored here, and notification payloads never choose the active user.
class NotificationInbox {
  static final _changes = StreamController<void>.broadcast();
  static Stream<void> get changes => _changes.stream;
  static Future<void> _writes = Future.value();

  static String _key(String user) =>
      'notification_inbox_${base64UrlEncode(utf8.encode('${dotenv.env['SITE_URL']?.trim() ?? ''}|${user.toLowerCase()}'))}';

  static Future<List<InboxNotification>> cached() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final user = prefs.getString('session_username');
    if (user == null || prefs.getString('session_sid') == null) return [];
    return _read(prefs, _key(user));
  }

  static List<InboxNotification> _read(SharedPreferences prefs, String key) {
    try {
      final data = jsonDecode(prefs.getString(key) ?? '[]');
      return (data as List)
          .whereType<Map>()
          .map(
            (row) => InboxNotification.fromJson(Map<String, dynamic>.from(row)),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> capture(RemoteMessage message) async {
    try {
      if (!dotenv.isInitialized) await dotenv.load(fileName: '.env');
      await _capture(message);
    } catch (error) {
      // Inbox persistence must never interrupt notification delivery or alarms.
      debugPrint('Could not retain notification: ${error.runtimeType}');
    }
  }

  static Future<void> _capture(RemoteMessage message) async {
    // Capture session identity before queueing so delayed work cannot migrate
    // from an old account into a newly signed-in account.
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final user = prefs.getString('session_username');
    final sid = prefs.getString('session_sid');
    if (user == null || sid == null) return;
    final recipient = message.data['for_user'] ?? message.data['recipient'];
    if (recipient != null &&
        recipient.toString().toLowerCase() != user.toLowerCase()) {
      return;
    }
    final title =
        message.notification?.title ??
        message.data['title']?.toString() ??
        'New work notification';
    final body =
        message.notification?.body ??
        message.data['body']?.toString() ??
        message.data['message']?.toString() ??
        '';
    final reference =
        (message.data['document_name'] ??
                message.data['docname'] ??
                message.data['reference_name'] ??
                '')
            .toString();
    final type =
        '${message.data['type'] ?? ''} ${message.data['document_type'] ?? ''} ${message.data['doctype'] ?? ''} $title';
    final id =
        message.data['notification_log']?.toString() ??
        'push:${message.messageId ?? base64UrlEncode(utf8.encode('$title|$body|$reference|${message.sentTime?.toIso8601String() ?? ''}'))}';
    final key = _key(user);
    final item = InboxNotification(
      id: id,
      title: notificationText(title),
      body: notificationText(body),
      created: (message.sentTime ?? DateTime.now()).toIso8601String(),
      category: InboxNotification.categoryFor(type),
      reference: reference,
    );
    final write = _writes.then((_) async {
      await prefs.reload();
      if (prefs.getString('session_username') != user ||
          prefs.getString('session_sid') != sid) {
        return;
      }
      final rows = _read(prefs, key);
      if (rows.any((row) => row.id == item.id)) return;
      rows.insert(0, item);
      await prefs.setString(
        key,
        jsonEncode(rows.take(200).map((row) => row.toJson()).toList()),
      );
      _changes.add(null);
    });
    _writes = write.catchError((Object error) {
      debugPrint('Could not retain notification: ${error.runtimeType}');
    });
    await _writes;
  }

  static Future<List<InboxNotification>> load() async {
    final user = await SessionAuthApi.getActiveSessionUser();
    final sid = await SessionAuthApi.getSessionId();
    if (user == null || sid == null) {
      throw StateError('Your session expired. Please sign in again.');
    }
    final site = dotenv.env['SITE_URL']?.trim() ?? '';
    if (site.isEmpty) throw StateError('SITE_URL is not configured.');
    final uri = Uri.parse(site)
        .resolve('/api/resource/Notification%20Log')
        .replace(
          queryParameters: {
            'fields': jsonEncode([
              'name',
              'subject',
              'email_content',
              'type',
              'document_type',
              'document_name',
              'creation',
              'read',
              'for_user',
            ]),
            'filters': jsonEncode([
              ['for_user', '=', user],
            ]),
            'order_by': 'creation desc',
            'limit_page_length': '100',
          },
        );
    final client = http.Client();
    final http.Response response;
    try {
      final request =
          http.Request('GET', uri)
            ..followRedirects = false
            ..headers.addAll({
              'Accept': 'application/json',
              'Cookie': 'sid=$sid',
            });
      response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 25));
    } finally {
      client.close();
    }
    if (await SessionAuthApi.getSessionId() != sid ||
        await SessionAuthApi.getSavedSessionUser() != user) {
      throw StateError('Your account changed. Reopen Notifications.');
    }
    if (response.statusCode != 200) {
      throw StateError(
        response.statusCode == 401 || response.statusCode == 403
            ? 'ERP could not authorize your notification history. Sign in again or contact your administrator.'
            : 'Could not load ERP notifications (${response.statusCode}). Swipe down to retry.',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['data'] is! List) {
      throw const FormatException('Invalid ERP notification response.');
    }
    final merged = <String, InboxNotification>{
      for (final row in await cached()) row.id: row,
    };
    for (final row in (decoded['data'] as List).whereType<Map>()) {
      if (row['for_user']?.toString().toLowerCase() != user.toLowerCase()) {
        continue;
      }
      final id = row['name']?.toString() ?? '';
      if (id.isEmpty) continue;
      merged[id] = InboxNotification(
        id: id,
        title: notificationText(row['subject']),
        body: notificationText(row['email_content']),
        created: row['creation']?.toString() ?? '',
        reference: row['document_name']?.toString() ?? '',
        category: InboxNotification.categoryFor(
          '${row['document_type']} ${row['type']} ${row['subject']}',
        ),
        read: row['read'] == 1 || row['read'] == true,
      );
    }
    final rows =
        merged.values.toList()..sort(
          (a, b) => (DateTime.tryParse(b.created)?.millisecondsSinceEpoch ?? 0)
              .compareTo(
                DateTime.tryParse(a.created)?.millisecondsSinceEpoch ?? 0,
              ),
        );
    if (await SessionAuthApi.getSessionId() != sid ||
        await SessionAuthApi.getSavedSessionUser() != user) {
      throw StateError('Your account changed. Reopen Notifications.');
    }
    return rows.take(200).toList();
  }
}
