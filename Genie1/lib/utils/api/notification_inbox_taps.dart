import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'document_notification.dart';
import 'notification_inbox.dart';

/// Push taps open only the inbox, after Home has passed normal sign-in gates.
/// The document or dialer can be opened separately from an inbox item.
class NotificationInboxTaps {
  static Object? _owner;
  static void Function()? _open;
  static String? _pendingScope;
  static bool _flushing = false;

  static void register(Object owner, void Function() open) {
    _owner = owner;
    _open = open;
    unawaited(_flush());
  }

  static void unregister(Object owner) {
    if (!identical(owner, _owner)) return;
    _owner = null;
    _open = null;
  }

  static Future<void> open(RemoteMessage message) async {
    if (!dotenv.isInitialized) await dotenv.load(fileName: '.env');
    final scope = await NotificationInbox.sessionScope();
    if (scope == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final user = prefs.getString('session_username')?.trim().toLowerCase();
    if (user == null ||
        user.isEmpty ||
        user == 'guest' ||
        (prefs.getString('session_sid') ?? '').isEmpty) {
      return;
    }
    final data = message.data;
    for (final field in ['for_user', 'recipient', '_genie_user']) {
      if (data[field] != null &&
          data[field].toString().trim().toLowerCase() != user) {
        return;
      }
    }
    if (data['_genie_site'] != null &&
        data['_genie_site'] != dotenv.env['SITE_URL']) {
      return;
    }
    if (data['type'] == 'DOCUMENT_NOTIFICATION' &&
        DocumentNotification.fromData(data) == null) {
      return;
    }
    if (await NotificationInbox.sessionScope() != scope) return;
    await NotificationInbox.capture(message);
    if (await NotificationInbox.sessionScope() != scope) return;
    _pendingScope = scope;
    await _flush();
  }

  static Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      while (_pendingScope != null && _open != null) {
        final scope = _pendingScope;
        _pendingScope = null;
        if (scope == await NotificationInbox.sessionScope()) _open?.call();
      }
    } finally {
      _flushing = false;
    }
  }
}
