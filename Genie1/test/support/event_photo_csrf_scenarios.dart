import 'dart:async';
import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:homegenie/utils/api/image_upload_api.dart';
import 'package:homegenie/utils/platform/platform_file_web.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Map<String, bool>> verifyPhotoBrowserCsrf() async {
 final results=<String,bool>{};
 for(final scenario in ['success','csrf','validation','timeout','session-change']) {
  SharedPreferences.setMockInitialValues({'session_sid':'browser-generation','token':'token key:secret'});
  dotenv.testLoad(fileInput:'SITE_URL=https://erp.example.test/');
  final file=File.fromBytes([255,216,11,22,33,255,217],name:'visit.jpg');
  var gets=0,posts=0,valid=true;String? url;
  await http.runWithClient(() async {url=await ImageUploadApi.uploadImageToEvent(filePath:file.path,docname:'EVENT-1');},()=>MockClient.streaming((request,stream) async {
   final bytes=await stream.toBytes();
   if(request.method=='GET') {
    gets++;valid=valid&&request.url.path=='/app';
    if(scenario=='session-change')await(await SharedPreferences.getInstance()).setString('session_sid','new-generation');
    return http.StreamedResponse(Stream.value(utf8.encode('frappe.csrf_token = "csrf$gets";')),200);
   }
   posts++;
   valid=valid&&request is http.MultipartRequest&&request.url.path=='/api/method/upload_file'&&request.headers['X-Frappe-CSRF-Token']=='csrf$gets'&&request.headers['Authorization']=='token key:secret'&&!request.headers.containsKey('Cookie');
   if(request is http.MultipartRequest) {
    valid=valid&&request.fields['doctype']=='Event'&&request.fields['docname']=='EVENT-1'&&request.fields['fieldname']=='custom_event_images'&&request.fields['is_private']=='1'&&request.fields['csrf_token']=='csrf$gets'&&request.files.length==1&&request.files.first.filename=='visit.jpg';
   }
   valid=valid&&bytes.length>7&&bytes.indexOf(255)>=0;
   if(scenario=='timeout')throw TimeoutException('uncertain upload response');
   if(posts==1&&['csrf','validation'].contains(scenario))return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode({'exc_type':scenario=='csrf'?'CSRFTokenError':'ValidationError'}))),400);
   return http.StreamedResponse(Stream.value(utf8.encode('{"message":{"file_url":"/private/files/visit.jpg"}}')),200);
  }));
  results[scenario]=valid&&gets==(scenario=='csrf'?2:1)&&posts==(scenario=='csrf'?2:scenario=='session-change'?0:1)&&url==(['success','csrf'].contains(scenario)?'/private/files/visit.jpg':null);
  await file.delete();
 }
 return results;
}
