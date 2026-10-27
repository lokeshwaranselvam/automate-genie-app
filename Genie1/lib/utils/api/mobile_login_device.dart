import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// An installation credential, not a hardware ID. Kept across prefs.clear().
class MobileLoginDevice {
  static const _storage = FlutterSecureStorage();
  static const _keyName = 'genie_mobile_installation_key';
  static const _pendingName = 'genie_pending_mobile_logout';
  static const _activeName = 'genie_active_mobile_binding';
  static Future<String>? _keyRequest;
  static Future<void>? _logoutRequest;

  static const _deviceChannel = MethodChannel(
    'ai.automategenie.app/mobile_device',
  );

  /// A recognition signal, never a replacement for the private logout key.
  /// Null means iOS/web or Android below 8; keep their existing binding flow.
  static Future<String?> androidId() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    final value = await _deviceChannel.invokeMethod<String>('androidId');
    if (value == null) return null;
    final id = value.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{1,16}$').hasMatch(id) ||
        RegExp(r'^0+$').hasMatch(id) ||
        id == '9774d56d682e549c') {
      throw StateError(
        'Unable to identify this Android device. Contact your administrator.',
      );
    }
    return id;
  }

  static Future<String> key() async {
    final request = _keyRequest ??= _loadKey();
    try {
      return await request;
    } finally {
      if (identical(_keyRequest, request)) _keyRequest = null;
    }
  }

  static Future<String> _loadKey() async {
    final saved = await _storage.read(key: _keyName);
    if (saved != null && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(saved)) {
      return saved;
    }
    final random = Random.secure();
    final value = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    await _storage.write(key: _keyName, value: value);
    return value;
  }

  static Future<void> logout(Uri endpoint, String user) async {
    // Persist before the network call. Enrollment's emergency local cleanup
    // must not lose the ability to release the server binding after an outage.
    await _storage.write(
      key: _pendingName,
      value: jsonEncode({'endpoint': endpoint.toString(), 'user': user}),
    );
    await completePendingLogout();
  }

  static Future<void> rememberSession(Uri endpoint, String user) async {
    final previous = await _storage.read(key: _activeName);
    final value = jsonEncode({'endpoint': endpoint.toString(), 'user': user});
    if (previous != null && previous != value) {
      final old = jsonDecode(previous) as Map;
      await logout(Uri.parse(old['endpoint'] as String), old['user'] as String);
    }
    await _storage.write(key: _activeName, value: value);
  }

  static Future<bool> logoutRememberedSession() async {
    final active = await _storage.read(key: _activeName);
    if (active == null) return false;
    final data = jsonDecode(active) as Map;
    await logout(Uri.parse(data['endpoint'] as String), data['user'] as String);
    return true;
  }

  static Future<void> completePendingLogout() async {
    final request = _logoutRequest ??= _completePendingLogout();
    try {
      await request;
    } finally {
      if (identical(_logoutRequest, request)) _logoutRequest = null;
    }
  }

  static Future<void> _completePendingLogout() async {
    final pending = await _storage.read(key: _pendingName);
    if (pending == null) return;
    final data = jsonDecode(pending) as Map;
    final response = await http
        .post(
          Uri.parse(data['endpoint'] as String),
          headers: const {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          // No SID/token: the installation credential authenticates this narrow
          // operation even when the server-side browser session has expired.
          body: jsonEncode({'user': data['user'], 'device_key': await key()}),
        )
        .timeout(const Duration(seconds: 15));
    dynamic body;
    try {
      body = jsonDecode(response.body);
    } catch (_) {
      body = null;
    }
    if (response.statusCode != 200 ||
        body is! Map ||
        body['message'] is! Map ||
        body['message']['status'] != 'success') {
      throw StateError(
        'Could not complete sign-out on ERP. Check your connection and retry.',
      );
    }
    await _storage.delete(key: _pendingName);
    if (await _storage.read(key: _activeName) == pending) {
      await _storage.delete(key: _activeName);
    }
  }
}
