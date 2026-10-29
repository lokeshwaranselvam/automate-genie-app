import 'dart:async';
import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Contract sent by the generic Frappe Notification channel.
class DocumentNotification {
  const DocumentNotification(this.data, this.doctype, this.docname, this.user);
  final Map<String, dynamic> data;
  final String doctype, docname, user;

  static DocumentNotification? fromData(Map<String, dynamic> data) {
    if (data['type'] != 'DOCUMENT_NOTIFICATION') return null;
    final doctype = data['doctype']?.toString().trim() ?? '';
    final docname = data['docname']?.toString().trim() ?? '';
    final user = data['for_user']?.toString().trim().toLowerCase() ?? '';
    if (doctype.isEmpty || docname.isEmpty || user.isEmpty || user == 'guest') {
      return null;
    }
    return DocumentNotification(Map.of(data), doctype, docname, user);
  }

  String get title => data['title']?.toString() ?? 'New notification';
  String get body => data['body']?.toString() ?? '';
  bool get alarmEnabled => data['alarm_enabled'] == '1';

  Uri? get documentUri {
    final site = Uri.tryParse(dotenv.env['SITE_URL']?.trim() ?? '');
    if (site == null || site.scheme != 'https' || site.host.isEmpty) {
      return null;
    }
    return site.replace(
      pathSegments: [
        'app',
        doctype.toLowerCase().replaceAll(' ', '-'),
        docname,
      ],
      query: '',
      fragment: '',
    );
  }

  Future<bool> isCurrentRecipient() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return (prefs.getString('session_sid') ?? '').isNotEmpty &&
        prefs.getString('session_username')?.trim().toLowerCase() == user &&
        (data['_genie_site'] == null ||
            data['_genie_site'] == dotenv.env['SITE_URL']);
  }
}

class DocumentNotificationAlerts {
  static Future<void> _queue = Future<void>.value();

  /// Message IDs distinguish separate notifications for the same document.
  static Future<bool> deliver({
    required Map<String, dynamic> data,
    required String receipt,
    required Future<void> Function() notify,
    Future<void> Function()? playSound,
  }) {
    final result = _queue.then((_) async {
      final notification = DocumentNotification.fromData(data);
      if (notification == null) return false;
      if (!dotenv.isInitialized) await dotenv.load(fileName: '.env');
      if (!await notification.isCurrentRecipient()) return false;
      final prefs = await SharedPreferences.getInstance();
      final sid = prefs.getString('session_sid');
      final key =
          'document_notification_alerts_${jsonEncode([dotenv.env['SITE_URL'], notification.user])}';
      final seen = prefs.getStringList(key) ?? [];
      if (seen.contains(receipt)) return false;
      await notify();
      await prefs.reload();
      if (prefs.getString('session_sid') != sid ||
          !await notification.isCurrentRecipient()) {
        return true;
      }
      await prefs.setStringList(
        key,
        [...seen, receipt].reversed.take(500).toList().reversed.toList(),
      );
      if (notification.alarmEnabled && playSound != null) await playSound();
      return true;
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}

/// Initial taps wait until Home has passed the normal sign-in/face gates.
class DocumentNotificationTaps {
  static Object? _owner;
  static void Function(DocumentNotification)? _open;
  static DocumentNotification? _pending;
  static String? _pendingSid;
  static bool _flushing = false;

  static void register(Object owner, void Function(DocumentNotification) open) {
    _owner = owner;
    _open = open;
    unawaited(_flush());
  }

  static void unregister(Object owner) {
    if (!identical(owner, _owner)) return;
    _owner = null;
    _open = null;
  }

  static Future<void> open(Map<String, dynamic> data) async {
    final notification = DocumentNotification.fromData(data);
    if (notification == null) return;
    if (!dotenv.isInitialized) await dotenv.load(fileName: '.env');
    if (!await notification.isCurrentRecipient()) return;
    final prefs = await SharedPreferences.getInstance();
    _pending = notification;
    _pendingSid = prefs.getString('session_sid');
    await _flush();
  }

  static Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      while (_pending != null && _open != null) {
        final notification = _pending!;
        final sid = _pendingSid;
        _pending = null;
        final valid = await notification.isCurrentRecipient();
        final prefs = await SharedPreferences.getInstance();
        if (valid && sid == prefs.getString('session_sid')) {
          _open?.call(notification);
        }
      }
    } finally {
      _flushing = false;
    }
  }
}
