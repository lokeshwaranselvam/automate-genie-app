import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StorageDiagnostics {
  static const enabled =
      bool.fromEnvironment('STORAGE_DIAGNOSTICS');

  static const _knownKeys = {
    'genie_mobile_installation_key',
    'genie_pending_mobile_logout',
    'genie_active_mobile_binding',
    'genie_fcm_registration_device_id',
    'remember_login_enabled',
    'remembered_login_username',
    'remembered_login_password',
    'genie_private_face_template_v1',
  };

  static Future<String?> read(
    FlutterSecureStorage storage, {
    required String key,
  }) => _run('READ', key, () => storage.read(key: key));

  static Future<void> write(
    FlutterSecureStorage storage, {
    required String key,
    required String? value,
  }) => _run(
    'WRITE',
    key,
    () => storage.write(key: key, value: value),
  );

  static Future<T> _run<T>(
    String operation,
    String key,
    Future<T> Function() action,
  ) async {
    if (!enabled) return action();

    final label = _knownKeys.contains(key) ? key : 'other_key';
    debugPrintSynchronously('[StorageDiag] $operation $label START');

    try {
      final result = await action();
      debugPrintSynchronously('[StorageDiag] $operation $label SUCCESS');
      return result;
    } catch (error) {
      var category = 'STORAGE_ERROR';

      if (error is PlatformException) {
        final details = '${error.message} ${error.details}'.toLowerCase();
        category = 'PLATFORM_ERROR';

        if (details.contains('bad_decrypt') ||
            details.contains('badpaddingexception')) {
          category = 'BAD_DECRYPT';
        } else if (details.contains('keypermanentlyinvalidatedexception')) {
          category = 'KEY_INVALIDATED';
        } else if (details.contains('unwrap key') ||
            details.contains('failed to unwrap')) {
          category = 'KEY_UNWRAP_FAILED';
        }
      }

      debugPrintSynchronously(
        '[StorageDiag] $operation $label FAILED $category',
      );
      rethrow;
    }
  }
}