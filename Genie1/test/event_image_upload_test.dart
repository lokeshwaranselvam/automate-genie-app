import 'dart:convert';
import 'dart:io';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/api/image_upload_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 for(final success in [true,false]){
  test('Native private Event upload contract remains unchanged: $success',()async{
   SharedPreferences.setMockInitialValues({'token':'token key:secret'});
   dotenv.testLoad(fileInput:'SITE_URL=https://erp.example.test');
   final dir=await Directory.systemTemp.createTemp('genie-event-photo-test-');
   final file=await File('${dir.path}/visit.jpg').writeAsBytes([255,216,11,22,33,255,217]);
   var uploads=0;
   try{
    final url=await http.runWithClient(()=>ImageUploadApi.uploadImageToEvent(filePath:file.path,docname:'EVENT-1'),()=>MockClient.streaming((request,stream)async{
     uploads++;await stream.toBytes();
     expect(request.method,'POST');expect(request.url.path,'/api/method/upload_file');
     expect(request.headers['Authorization'],'token key:secret');expect(request.headers.containsKey('X-Frappe-CSRF-Token'),isFalse);
     final multipart=request as http.MultipartRequest;
     expect(multipart.fields,{'doctype':'Event','docname':'EVENT-1','fieldname':'custom_event_images','is_private':'1'});
     expect(multipart.files.single.filename,'visit.jpg');
     return http.StreamedResponse(Stream.value(utf8.encode(success?'{"message":{"file_url":"/private/files/visit.jpg"}}':'{"exc_type":"ValidationError"}')),success?200:400);
    }));
    expect(uploads,1);expect(url,success?'/private/files/visit.jpg':null);
   }finally{await file.delete();await dir.delete();}
  });
 }
}
