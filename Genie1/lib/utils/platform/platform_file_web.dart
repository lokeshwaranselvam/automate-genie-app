import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// Browser blobs remain in memory for the lifetime of the current form.
/// They are never persisted in localStorage or a service-worker cache.
class File {
  File(this.path) { _modified.putIfAbsent(path, DateTime.now); }
  final String path;
  static final Map<String, Uint8List> _files = {};
  static int _sequence = 0;
  static final Map<String, DateTime> _modified = {};
  Future<DateTime> lastModified() async => _modified[path] ?? DateTime.now();
  static File fromBytes(List<int> bytes, {String name = 'photo.jpg'}) {
    final file = File('/memory/${_sequence++}/$name');
    _files[file.path] = Uint8List.fromList(bytes);
    return file;
  }

  Future<Uint8List> readAsBytes() async {
    final saved = _files[path];
    if (saved != null) return saved;
    if (path.startsWith('blob:')) {
      final response = await http.get(Uri.parse(path));
      if (response.statusCode != 200)
        throw StateError('The selected file is no longer available.');
      return _files[path] = response.bodyBytes;
    }
    throw StateError(
      'The selected file is no longer available. Choose it again.',
    );
  }

  Uint8List readAsBytesSync() =>
      _files[path] ??
      (throw StateError('Read the browser file before previewing it.'));
  Future<File> writeAsBytes(List<int> bytes, {bool flush = false}) async {
    _files[path] = Uint8List.fromList(bytes);
    _modified[path] = DateTime.now();
    return this;
  }

  bool existsSync() => _files.containsKey(path) || path.startsWith('blob:');
  Future<bool> exists() async => existsSync();
  int lengthSync() => _files[path]?.length ?? 0;
  Future<int> length() async => (await readAsBytes()).length;
  Future<File> delete({bool recursive = false}) async {
    deleteSync();
    return this;
  }

  void deleteSync({bool recursive = false}) {
    _files.remove(path);
    _modified.remove(path);
  }

  static void clearTemporaryFiles() { _files.clear(); _modified.clear(); }
}

class Directory {
  Directory(this.path);
  final String path;
  static final systemTemp = Directory('/memory');
  Future<Directory> createTemp([String? prefix]) async => Directory(
    '$path/${prefix ?? ''}${DateTime.now().microsecondsSinceEpoch}',
  );
  Future<bool> exists() async => true;
  Future<Directory> delete({bool recursive = false}) async {
    File._files.removeWhere((key, _) => key.startsWith('$path/'));
    return this;
  }
}

class Platform {
  static const isAndroid = false,
      isIOS = false,
      isWindows = false,
      isLinux = false,
      isMacOS = false;
  static const pathSeparator = '/';
}
