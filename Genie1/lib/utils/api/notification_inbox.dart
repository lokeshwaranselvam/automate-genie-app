import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_auth.dart';
import 'lead_call_notification.dart';
import 'sales_summary_notification.dart';

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
    this.doctype = '',
    this.callPhone = '',
    this.pageRoute = '',
    this.notificationName = '',
    this.read = false,
    this.receivedViaPush = false,
  });
  final String id, title, body, created, category, reference;
  final String doctype, callPhone;
  final String pageRoute;
  final String notificationName;
  bool get isSalesSummary =>
      pageRoute == salesSummaryRoute ||
      notificationName == 'TOMORROW-COLLECTION' ||
      // Older cached pushes did not retain notification_name. Match only the
      // collection message's exact title and heading, never arbitrary links.
      (notificationName.isEmpty &&
          (doctype.isEmpty || doctype.trim().toLowerCase() == 'user') &&
          title.trim() == 'Tomorrow Collection' &&
          body.trimLeft().startsWith('TOMORROW COLLECTION\n'));

  bool get hasErpDocumentLink =>
      !isSalesSummary &&
      doctype.trim().isNotEmpty &&
      reference.trim().isNotEmpty &&
      !const {
        'user',
        'notification log',
      }.contains(doctype.trim().toLowerCase());
  final bool read;
  final bool receivedViaPush;

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
        doctype: row['doctype']?.toString() ?? '',
        callPhone: row['call_phone']?.toString() ?? '',
        pageRoute: salesSummaryPageRoute(row['page_route']),
        notificationName: row['notification_name']?.toString() ?? '',
        read: row['read'] == true || row['read'] == 1,
        receivedViaPush:
            row['received_via_push'] == true ||
            row['id']?.toString().startsWith('push:') == true,
      );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'created': created,
    'category': category,
    'reference': reference,
    'doctype': doctype,
    'call_phone': callPhone,
    'page_route': pageRoute,
    'notification_name': notificationName,
    'read': read,
    'received_via_push': receivedViaPush,
  };
}

/// A bounded, per-site and per-user inbox. No push tokens or session secrets
/// are stored here, and notification payloads never choose the active user.
class NotificationInbox {
  static final _changes = StreamController<void>.broadcast();
  static Stream<void> get changes => _changes.stream;
  static Future<void>? _writes;

  static Future<void> _queueWrite(Future<void> Function() operation) {
    final previous = _writes;
    final write =
        previous == null
            ? Future<void>.sync(operation)
            : previous.then((_) => operation());
    late Future<void> settled;
    settled = write.then<void>(
      (_) {
        if (identical(_writes, settled)) _writes = null;
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_writes, settled)) _writes = null;
      },
    );
    _writes = settled;
    return write;
  }

  static String? _scope(SharedPreferences prefs) {
    final user = prefs.getString('session_username');
    final sid = prefs.getString('session_sid');
    return user == null || sid == null ? null : '${_key(user)}|$sid';
  }

  static Future<String?> sessionScope() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return _scope(prefs);
  }

  static Set<String> _dismissed(SharedPreferences prefs, String key) =>
      (prefs.getStringList('${key}_viewed') ?? []).toSet();

  /// Records viewing locally without deleting messages or updating ERP records.
  static Future<void> markSeen(Set<String> ids, {required String scope}) async {
    if (ids.isEmpty) return;
    try {
      await _queueWrite(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        if (_scope(prefs) != scope) return;
        final key = _key(prefs.getString('session_username')!);
        final seen = (prefs.getStringList('${key}_seen') ?? []).toSet();
        if (ids.every(seen.contains)) return;
        seen.addAll(ids);
        await prefs.setStringList(
          '${key}_seen',
          seen.toList().reversed.take(2000).toList().reversed.toList(),
        );
        _changes.add(null);
      });
    } catch (error) {
      debugPrint('Could not mark notifications seen: ${error.runtimeType}');
    }
  }

  static Future<bool> hasUnseen() async {
    await _writes;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final user = prefs.getString('session_username');
    if (user == null || prefs.getString('session_sid') == null) return false;
    final key = _key(user);
    final seen = (prefs.getStringList('${key}_seen') ?? []).toSet();
    final dismissed = _dismissed(prefs, key);
    return _read(prefs, key).any(
      (row) =>
          !row.read && !seen.contains(row.id) && !dismissed.contains(row.id),
    );
  }

  /// Removes only the notifications selected for clearing, never later arrivals.
  static Future<void> dismissViewed(
    Set<String> ids, {
    required String scope,
  }) async {
    if (ids.isEmpty) return;
    final write = _queueWrite(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (_scope(prefs) != scope) return;
      final key = _key(prefs.getString('session_username')!);
      final dismissed = _dismissed(prefs, key)..addAll(ids);
      // Retain recent cleared IDs to suppress duplicate push delivery,
      // including after logout and login.
      await prefs.setStringList(
        '${key}_viewed',
        dismissed.toList().reversed.take(2000).toList().reversed.toList(),
      );
      final rows = _read(prefs, key).where((row) => !ids.contains(row.id));
      await prefs.setString(
        key,
        jsonEncode(rows.map((row) => row.toJson()).toList()),
      );
      _changes.add(null);
    });
    await write.catchError((Object error) {
      debugPrint('Could not clear viewed notifications: ${error.runtimeType}');
    });
  }

  /// Clear login/session preferences while retaining explicit notification clears.
  /// Dismissals are already scoped by ERP site and user; message bodies, seen
  /// state and credentials retain their existing logout cleanup behavior.
  static Future<void> clearPreferencesPreservingDismissals(
    SharedPreferences prefs,
  ) => _queueWrite(() async {
    await prefs.reload();
    for (final key in prefs.getKeys()) {
      if (key.startsWith('notification_inbox_') && key.endsWith('_viewed')) {
        continue;
      }
      await prefs.remove(key);
    }
  });

  static String _key(String user) =>
      'notification_inbox_${base64UrlEncode(utf8.encode('${dotenv.env['SITE_URL']?.trim() ?? ''}|${user.toLowerCase()}'))}';

  static Future<List<InboxNotification>> cached() async {
    await _writes;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final user = prefs.getString('session_username');
    if (user == null || prefs.getString('session_sid') == null) return [];
    final key = _key(user);
    final dismissed = _dismissed(prefs, key);
    return _read(
      prefs,
      key,
    ).where((row) => !dismissed.contains(row.id)).toList();
  }

  static List<InboxNotification> _read(SharedPreferences prefs, String key) {
    try {
      final data = jsonDecode(prefs.getString(key) ?? '[]');
      return (data as List)
          .whereType<Map>()
          .map(
            (row) => InboxNotification.fromJson(Map<String, dynamic>.from(row)),
          )
          .where((row) => row.receivedViaPush)
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
    final leadCall = LeadCallNotification.fromData(message.data);
    final title =
        message.notification?.title ??
        message.data['title']?.toString() ??
        leadCall?.title ??
        'New work notification';
    final body =
        message.notification?.body ??
        message.data['body']?.toString() ??
        message.data['message']?.toString() ??
        leadCall?.body ??
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
      receivedViaPush: true,
      title: notificationText(title),
      body: notificationText(body),
      created: (message.sentTime ?? DateTime.now()).toIso8601String(),
      category: InboxNotification.categoryFor(type),
      reference: reference,
      doctype:
          (message.data['document_type'] ?? message.data['doctype'] ?? '')
              .toString(),
      callPhone: leadCall?.phone ?? '',
      pageRoute: isSalesSummaryPush(message.data) ? salesSummaryRoute : '',
      notificationName: message.data['notification_name']?.toString() ?? '',
    );
    final write = _queueWrite(() async {
      await prefs.reload();
      if (prefs.getString('session_username') != user ||
          prefs.getString('session_sid') != sid ||
          _key(user) != key) {
        return;
      }
      final rows = _read(prefs, key);
      if (_dismissed(prefs, key).contains(item.id)) return;
      if (rows.any((row) => row.id == item.id)) return;
      rows.insert(0, item);
      await prefs.setString(
        key,
        jsonEncode(rows.take(200).map((row) => row.toJson()).toList()),
      );
      _changes.add(null);
    });
    await write;
  }

  static Future<List<InboxNotification>> load() async {
    final scope = await sessionScope();
    final user = await SessionAuthApi.getActiveSessionUser();
    final sid = await SessionAuthApi.getSessionId();
    if (user == null || sid == null) {
      throw StateError('Your session expired. Please sign in again.');
    }
    // Refresh only pushes captured on this device. ERP Notification Log rows
    // are not evidence that a push was received and must not enter this inbox.
    final items = await cached();
    if (await sessionScope() != scope ||
        await SessionAuthApi.getSessionId() != sid ||
        await SessionAuthApi.getSavedSessionUser() != user) {
      throw StateError('Your account changed. Reopen Notifications.');
    }
    return items;
  }
}
