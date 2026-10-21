import 'dart:convert';
import 'dart:js_interop';

@JS('genieMapCall')
external JSPromise<JSString> _mapCall(JSString operation, JSString args);
Future<Map<String, dynamic>> browserMapCall(
  String operation,
  Map<String, dynamic> args,
) async {
  final response = await _mapCall(
    operation.toJS,
    jsonEncode(args).toJS,
  ).toDart.timeout(const Duration(seconds: 15));
  return Map<String, dynamic>.from(jsonDecode(response.toDart) as Map);
}
