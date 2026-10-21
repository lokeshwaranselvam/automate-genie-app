import 'package:http/http.dart' as http;
Future<http.MultipartFile> platformMultipartFile(String field, String path, {String? filename}) => http.MultipartFile.fromPath(field, path, filename: filename);
