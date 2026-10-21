import 'package:http/http.dart' as http;
import 'platform_file_web.dart';
Future<http.MultipartFile> platformMultipartFile(String field, String path, {String? filename}) async => http.MultipartFile.fromBytes(field, await File(path).readAsBytes(), filename: filename);
