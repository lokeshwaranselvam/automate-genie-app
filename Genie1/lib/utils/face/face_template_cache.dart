import '../storage_diagnostics.dart';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keeps only one account's derived template. The ERP File remains authoritative.
class FaceTemplateCache {
  FaceTemplateCache({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static final instance = FaceTemplateCache();
  static const _key = 'genie_private_face_template_v1';
  final FlutterSecureStorage _storage;
  Future<void> _operations = Future<void>.value();
  int _generation = 0;

  /// Capture before async template derivation; logout invalidates that work.
  int get generation => _generation;

  Future<List<double>?> read(String identity) => _serialized(() async {
    final generation = _generation;
    try {
      final raw = await StorageDiagnostics.read(_storage, key: _key);
      if (generation != _generation) return null;
      if (raw == null) return null;
      final data = jsonDecode(raw);
      if (data is! Map ||
          data['identity'] != identity ||
          data['embedding'] is! List) {
        await _deleteLocked();
        return null;
      }
      final values =
          (data['embedding'] as List)
              .map((value) => (value as num).toDouble())
              .toList();
      if (values.length != 128 ||
          values.any((value) => !value.isFinite) ||
          values.every((value) => value == 0)) {
        await _deleteLocked();
        return null;
      }
      return values;
    } catch (_) {
      // A failed/invalid cache never becomes an approved identity template.
      await _deleteLocked();
      return null;
    }
  });

  Future<void> write(
    String identity,
    List<double> embedding, {
    int? expectedGeneration,
  }) => _serialized(() async {
    if (expectedGeneration != null && expectedGeneration != _generation) return;
    try {
      await StorageDiagnostics.write(_storage,
        key: _key,
        value: jsonEncode({'identity': identity, 'embedding': embedding}),
      );
    } catch (_) {
      // Recognition still works by deriving from the private ERP reference.
    }
  });

  Future<void> clear() {
    // Invalidate before queuing storage deletion. A write already in progress
    // finishes before the deletion; later stale writes are skipped.
    _generation++;
    return _serialized(() => _deleteLocked(invalidate: false));
  }

  Future<void> _deleteLocked({bool invalidate = true}) async {
    if (invalidate) _generation++;
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }
}
