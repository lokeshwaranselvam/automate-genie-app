import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'package:overlay_support/overlay_support.dart';
import 'package:flutter/material.dart';

Future<void> showBrowserNotification(String title, String body) async {
  // Foreground alerts stay visible even if push permission is denied.
  showSimpleNotification(
    Text(title),
    subtitle: Text(body),
    duration: const Duration(seconds: 5),
  );
  if (web.Notification.permission != 'granted') return;
  try {
    final registration =
        await web.window.navigator.serviceWorker.getRegistration().toDart;
    if (registration != null) {
      await registration
          .showNotification(
            title,
            web.NotificationOptions(body: body, icon: 'icons/Icon-192.png'),
          )
          .toDart;
    }
  } catch (_) {}
}
