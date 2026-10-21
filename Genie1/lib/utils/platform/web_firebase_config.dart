import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Public Firebase WEB registration values, never an Android app ID.
class WebFirebaseConfig {
  static bool get isConfigured => [
    'FIREBASE_WEB_API_KEY',
    'FIREBASE_WEB_APP_ID',
    'FIREBASE_WEB_PROJECT_ID',
    'FIREBASE_WEB_MESSAGING_SENDER_ID',
  ].every((key) => (dotenv.env[key] ?? '').trim().isNotEmpty);
  static String? get vapidKey {
    final value = dotenv.env['FIREBASE_WEB_VAPID_KEY']?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  static FirebaseOptions get options => FirebaseOptions(
    apiKey: dotenv.env['FIREBASE_WEB_API_KEY']!,
    appId: dotenv.env['FIREBASE_WEB_APP_ID']!,
    projectId: dotenv.env['FIREBASE_WEB_PROJECT_ID']!,
    messagingSenderId: dotenv.env['FIREBASE_WEB_MESSAGING_SENDER_ID']!,
    authDomain: dotenv.env['FIREBASE_WEB_AUTH_DOMAIN'],
    storageBucket: dotenv.env['FIREBASE_WEB_STORAGE_BUCKET'],
  );
}
