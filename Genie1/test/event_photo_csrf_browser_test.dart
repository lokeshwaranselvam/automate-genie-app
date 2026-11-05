@TestOn('browser')
library;
import 'package:flutter_test/flutter_test.dart';
import 'support/event_photo_csrf_scenarios.dart';
void main(){TestWidgetsFlutterBinding.ensureInitialized();test('Event photo multipart uses CSRF and preserves private attachments across a CSRF retry',()async{final results=await verifyPhotoBrowserCsrf();expect(results,hasLength(5));for(final r in results.entries){expect(r.value,isTrue,reason:r.key);}});}
