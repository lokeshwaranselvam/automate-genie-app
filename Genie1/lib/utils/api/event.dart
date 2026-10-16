import 'dart:convert';
import '../event_location_selection.dart';
import '../event_otp.dart';
import 'package:flutter/src/widgets/framework.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:homegenie/utils/api/check_in_out.dart';
import 'package:homegenie/utils/widget/warning.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class Event {
  static String? token;

  static late SharedPreferences prefs;
  static final URL = dotenv.env['URL'];

  static Future<List<dynamic>> eventList(String usr) async {
    final pingResult = await Check.pingpong();

    if (pingResult == null || pingResult['message'] != 'pong') {
      return [
        {
          "message":
              "ERP Site is not in working condition! Please try again later.",
          "status": "Error",
        },
      ];
    }
    final prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');
    try {
      var response = await http.get(
        Uri.parse('$URL.event_list?user=$usr'),
        headers: {
          "Authorization": token ?? "",
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      );
      if (response.statusCode == 200) {
        var data = json.decode(response.body);
        return data['message'];
      } else {
        throw Exception("Failed to load events: ${response.statusCode}");
      }
    } catch (e) {
      throw Exception("Error fetching events: $e");
    }
  }

  static Future<bool> checkIfOtpRequired(
    String eventId,
    BuildContext context,
  ) async {
    final pingResult = await Check.pingpong();
    if (pingResult == false) {
      Warning.show(
        context,
        'ERP Site is not in working condition! Please try again later.',
        'Error',
      );
      return false;
    }

    final prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');

    try {
      var response = await http.get(
        Uri.parse('$URL.is_otp_required?event_id=$eventId'),
        headers: {
          "Authorization": token ?? "",
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        var data = json.decode(response.body);
        return data['message'] == true;
      } else {
        throw Exception(
          "Failed to check OTP requirement: ${response.statusCode}",
        );
      }
    } catch (e) {
      throw Exception("Error checking OTP requirement: $e");
    }
  }

  static Future<List<dynamic>> HistoryList(
    String usr,
    String fromDate,
    String toDate,
    BuildContext context,
  ) async {
    final pingResult = await Check.pingpong();
    if (pingResult == false) {
      Warning.show(
        context,
        'ERP Site is not in working condition! Please try again later.',
        'Error',
      );
      return [];
    }
    final prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');

    if (token == null || token.isEmpty) {
      throw Exception("Authorization token missing.");
    }

    try {
      final url = Uri.parse(
        '$URL.history_list?user=$usr&from_date=$fromDate&to_date=$toDate',
      );

      final response = await http
          .get(
            url,
            headers: {
              "Authorization": token,
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data.containsKey('exc') && data['exc'] != null) {
          throw Exception("Frappe Error: ${data['exc']}");
        }
        return data['message'];
      } else {
        throw Exception("Failed to load History: ${response.statusCode}");
      }
    } catch (e) {
      throw Exception("Error fetching events: $e");
    }
  }

  static eventdetails(String id, BuildContext context) async {
    final pingResult = await Check.pingpong();
    if (pingResult == false) {
      Warning.show(
        context,
        'ERP Site is not in working condition! Please try again later.',
        'Error',
      );
      return [];
    }

    final prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');
    try {
      var response = await http.get(
        Uri.parse('$URL.event_details?id=$id'),
        headers: {
          "Authorization": token ?? "",
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      );
      if (response.statusCode == 200) {
        var data = json.decode(response.body);
        return data['message'];
      } else {
        throw Exception("Failed to load events: ${response.statusCode}");
      }
    } catch (e) {
      throw Exception("Error fetching events: $e");
    }
  }

  /// Fetches event timestamps used by the Home schedule without showing UI
  /// warnings. This is polled while Home is visible, so it must be quiet on
  /// transient network failures.
  static Future<Map<String, dynamic>?> eventTimelineDetails(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');

    try {
      final response = await http
          .get(
            Uri.parse('$URL.event_details?id=$id'),
            headers: {
              'Authorization': token ?? '',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) return null;
      final decoded = json.decode(response.body);
      if (decoded is! Map || decoded['exc'] != null) return null;
      final message = decoded['message'];
      if (message is! Map) return null;
      return Map<String, dynamic>.from(message);
    } catch (error) {
      debugPrint('Could not refresh event timeline details: $error');
      return null;
    }
  }

  /// Gets image attachments saved against an Event document in File.
  static Future<List<Map<String, dynamic>>> visitImageFiles(
    String eventId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    final siteUrl = dotenv.env['SITE_URL']?.trim() ?? '';
    if (token == null || token.isEmpty || siteUrl.isEmpty) {
      throw StateError('Sign in to view visit photos.');
    }

    final baseUri = Uri.tryParse(siteUrl);
    if (baseUri == null || baseUri.host.isEmpty) {
      throw StateError('The ERP site URL is not configured.');
    }

    final uri = baseUri
        .resolve('/api/resource/File')
        .replace(
          queryParameters: {
            'filters': jsonEncode([
              ['attached_to_doctype', '=', 'Event'],
              ['attached_to_name', '=', eventId],
            ]),
            'fields': jsonEncode([
              'name',
              'file_name',
              'file_url',
              'is_private',
              'creation',
            ]),
            'order_by': 'creation asc',
            'limit_page_length': '100',
          },
        );

    final response = await http.get(
      uri,
      headers: {'Authorization': token, 'Accept': 'application/json'},
    );
    if (response.statusCode != 200) {
      throw StateError('Could not load visit photos (${response.statusCode}).');
    }

    final decoded = jsonDecode(response.body);
    final records = decoded is Map ? decoded['data'] : null;
    if (records is! List) return [];

    final imageExtension = RegExp(
      r'\.(jpe?g|png|gif|webp|bmp|svg|heic|heif)$',
      caseSensitive: false,
    );
    final images = <Map<String, dynamic>>[];
    for (final record in records.whereType<Map>()) {
      final file = Map<String, dynamic>.from(record);
      final fileUrl = file['file_url']?.toString().trim() ?? '';
      final fileName = file['file_name']?.toString().trim() ?? '';
      if (!imageExtension.hasMatch(Uri.tryParse(fileUrl)?.path ?? fileUrl) &&
          !imageExtension.hasMatch(fileName)) {
        continue;
      }

      final parsedUrl = Uri.tryParse(fileUrl);
      if (parsedUrl == null) continue;
      file['file_url'] =
          parsedUrl.hasScheme
              ? parsedUrl.toString()
              : baseUri.resolve(fileUrl).toString();
      images.add(file);
    }
    return images;
  }

  static Uri _visitReportUri(Map<String, String> queryParameters) {
    final siteUrl = dotenv.env['SITE_URL']?.trim() ?? '';
    final baseUri = Uri.tryParse(siteUrl);
    if (baseUri == null || baseUri.host.isEmpty) {
      throw StateError('The ERP site URL is not configured.');
    }
    return baseUri
        .resolve('/api/method/event_visit_report')
        .replace(queryParameters: queryParameters);
  }

  static Map<String, dynamic> _visitReportResponse(http.Response response) {
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw StateError('The visit report API returned an invalid response.');
    }

    final message = decoded is Map ? decoded['message'] : null;
    if (response.statusCode != 200 ||
        (decoded is Map && decoded['exc'] != null)) {
      final detail =
          message?.toString().trim().isNotEmpty == true
              ? message.toString()
              : 'Visit report request failed (${response.statusCode}).';
      throw StateError(detail);
    }
    if (message is! Map) {
      throw StateError('The visit report API returned no report data.');
    }
    return Map<String, dynamic>.from(message);
  }

  /// Loads the observation and outcome previously saved in Event.description.
  static Future<Map<String, dynamic>> getVisitReport(String eventId) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (token == null || token.isEmpty) {
      throw StateError('Sign in to view this visit report.');
    }

    final response = await http.get(
      _visitReportUri({'action': 'get', 'event_id': eventId}),
      headers: {'Authorization': token, 'Accept': 'application/json'},
    );
    return _visitReportResponse(response);
  }

  /// Persists OTP independently of the observation/outcome submission.
  static Future<void> saveVisitOtp({
    required String eventId,
    required String customOtp,
  }) async {
    final otp = customOtp.trim();
    if (!EventOtp.isValid(otp)) {
      throw ArgumentError(EventOtp.validationMessage);
    }
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (token == null || token.isEmpty) {
      throw StateError('Sign in to save this visit OTP.');
    }
    final response = await http
        .post(
          _visitReportUri(const {}),
          headers: {'Authorization': token, 'Accept': 'application/json'},
          body: {'action': 'save_otp', 'event_id': eventId, 'custom_otp': otp},
        )
        .timeout(const Duration(seconds: 25));
    final result = _visitReportResponse(response);
    if (result['status'] != 'success' ||
        result['action'] != 'save_otp' ||
        result['event_id'] != eventId ||
        result['otp_saved'] != true ||
        result['custom_otp']?.toString().trim() != otp) {
      throw StateError(
        'OTP was not confirmed as saved. Checkout was not submitted.',
      );
    }
  }

  /// Saves report fields through the authenticated Event visit-report API.
  static Future<Map<String, dynamic>> saveVisitReport({
    required String eventId,
    required String observation,
    required String outcome,
    String? customOtp,
  }) async {
    if (customOtp != null && !EventOtp.isValid(customOtp)) {
      throw ArgumentError(EventOtp.validationMessage);
    }
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (token == null || token.isEmpty) {
      throw StateError('Sign in to submit this visit report.');
    }

    final response = await http.post(
      _visitReportUri(const {}),
      headers: {
        'Authorization': token,
        'Accept': 'application/json',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {
        'action': 'save',
        'event_id': eventId,
        'observation': observation,
        'outcome': outcome,
        if (customOtp != null) 'custom_otp': customOtp.trim(),
      },
    );
    return _visitReportResponse(response);
  }

  static Future<String?> getParticipantVisitType({
    required String eventName,
    required String referenceDocname,
    String referenceDoctype = 'Opportunity',
    required BuildContext context,
  }) async {
    final pingResult = await Check.pingpong();
    if (pingResult == false) {
      Warning.show(
        context,
        'ERP Site is not in working condition! Please try again later.',
        'Error',
      );
      return null;
    }

    final prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');
    final siteUrl = dotenv.env['SITE_URL'];

    if (siteUrl == null || siteUrl.isEmpty) {
      return null;
    }

    try {
      final uri = Uri.parse(
        '$siteUrl/api/method/event'
        '?reference_docname=$referenceDocname'
        '&reference_doctype=$referenceDoctype',
      );

      debugPrint(
        '[EventApi] getParticipantVisitType -> eventName=$eventName, '
        'reference_docname=$referenceDocname, reference_doctype=$referenceDoctype',
      );

      final response = await http.get(
        uri,
        headers: {
          "Authorization": token ?? "",
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      );

      if (response.statusCode != 200) {
        debugPrint(
          '[EventApi] getParticipantVisitType failed: ${response.statusCode} ${response.body}',
        );
        return null;
      }

      final data = json.decode(response.body);
      final payload = data['data'];
      debugPrint('[EventApi] getParticipantVisitType payload: $payload');

      if (payload is List) {
        for (final item in payload) {
          if (item is Map<String, dynamic>) {
            final name = item['name']?.toString();
            if (name == eventName) {
              final visitType = item['visit_type']?.toString();
              if (visitType != null && visitType.isNotEmpty) {
                debugPrint(
                  '[EventApi] visit type matched by event name: $visitType',
                );
                return visitType;
              }
            }
          }
        }

        for (final item in payload) {
          if (item is Map<String, dynamic>) {
            final docname = item['reference_docname']?.toString();
            if (docname == referenceDocname) {
              final visitType = item['visit_type']?.toString();
              if (visitType != null && visitType.isNotEmpty) {
                debugPrint(
                  '[EventApi] visit type matched by reference_docname: $visitType',
                );
                return visitType;
              }
            }
          }
        }
      }

      if (payload is Map<String, dynamic>) {
        final visitType = payload['visit_type']?.toString();
        if (visitType != null && visitType.isNotEmpty) {
          debugPrint(
            '[EventApi] visit type matched by map payload: $visitType',
          );
          return visitType;
        }
      }

      debugPrint('[EventApi] visit type not found in payload');
      return null;
    } catch (e) {
      debugPrint('[EventApi] getParticipantVisitType exception: $e');
      return null;
    }
  }

  static Future<List<dynamic>> office_type_list(
    String usr,
    BuildContext context,
  ) async {
    final pingResult = await Check.pingpong();
    if (pingResult == false) {
      Warning.show(
        context,
        'ERP Site is not in working condition! Please try again later.',
        'Error',
      );
      return [];
    }
    final prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');
    try {
      var response = await http.get(
        Uri.parse('$URL.officetype?user=$usr'),
        headers: {
          "Authorization": token ?? "",
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      );
      if (response.statusCode == 200) {
        var data = json.decode(response.body);
        return data['message'];
      } else {
        throw Exception("Failed to load events: ${response.statusCode}");
      }
    } catch (e) {
      throw Exception("Error fetching events: $e");
    }
  }

  static String? _headOfficeKey;
  static List<dynamic>? _headOfficeNames;
  static DateTime? _headOfficeLoadedAt;
  static Future<List<dynamic>>? _headOfficeLoading;

  static Future<List<dynamic>> head_office_list(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (token == null || token.isEmpty) {
      throw StateError('Your session has expired. Please sign in again.');
    }
    final key = '$URL|$token';
    if (_headOfficeKey != key) {
      _headOfficeKey = key;
      _headOfficeNames = null;
      _headOfficeLoadedAt = null;
      _headOfficeLoading = null;
    }
    if (_headOfficeNames != null &&
        DateTime.now().difference(_headOfficeLoadedAt!) <
            const Duration(minutes: 2)) {
      return _headOfficeNames!;
    }
    if (_headOfficeLoading != null) return _headOfficeLoading!;
    final request = _loadHeadOfficeNames(token, key);
    _headOfficeLoading = request;
    try {
      return await request;
    } finally {
      if (identical(_headOfficeLoading, request)) _headOfficeLoading = null;
    }
  }

  static Future<List<dynamic>> _loadHeadOfficeNames(
    String token,
    String key,
  ) async {
    // The list request itself checks connectivity; no preliminary ping is needed.
    final response = await http
        .get(
          Uri.parse('$URL.head_office_list'),
          headers: {
            'Authorization': token,
            'Accept': 'application/json',
            'Cache-Control': 'no-cache, no-store',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError(
        'Could not load Head Office locations (${response.statusCode}).',
      );
    }
    final decoded = jsonDecode(response.body);
    final names = decoded is Map ? decoded['message'] : null;
    if (names is! List ||
        names.any((name) => name is! String || name.trim().isEmpty)) {
      throw const FormatException('ERP returned an invalid Head Office list.');
    }
    final result = List<dynamic>.unmodifiable(names);
    if (_headOfficeKey == key) {
      _headOfficeNames = result;
      _headOfficeLoadedAt = DateTime.now();
    }
    return result;
  }

  static Future<Map<String, dynamic>> Head_office_details(
    String office,
    BuildContext context,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (token == null || token.isEmpty) {
      throw StateError('Your session has expired. Please sign in again.');
    }
    // Fetch current geofence data directly; never cache office coordinates.
    final response = await http
        .get(
          Uri.parse(
            '$URL.head_office_details',
          ).replace(queryParameters: {'head_office': office}),
          headers: {
            'Authorization': token,
            'Accept': 'application/json',
            'Cache-Control': 'no-cache, no-store',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError(
        'Could not load Head Office details (${response.statusCode}).',
      );
    }
    final body = jsonDecode(response.body);
    final details = body is Map ? body['message'] : null;
    if (details is! Map) {
      throw const FormatException('ERP returned invalid Head Office details.');
    }
    return Map<String, dynamic>.from(details);
  }

  static Future<List<Map<String, dynamic>>> fetchEventListByDate(
    String user,
    String date,
    BuildContext context,
  ) async {
    final pingResult = await Check.pingpong();
    if (pingResult == false) {
      Warning.show(
        context,
        'ERP Site is not in working condition! Please try again later.',
        'Error',
      );
      return [];
    }
    final prefs = await SharedPreferences.getInstance();

    final String? token = prefs.getString('token');

    final response = await http.post(
      Uri.parse('$URL.event_list_date'),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': token ?? '',
      },
      body: jsonEncode({"user": user, "date": date}),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data['message'] is List) {
        return List<Map<String, dynamic>>.from(data['message']);
      } else {
        throw Exception("Unexpected response format");
      }
    } else {
      throw Exception("Failed to fetch event list: ${response.body}");
    }
  }

  static Future<Map<String, dynamic>> eventCheckin(
    String? user,
    String eventId,
    double lat,
    double lng,
    String address,
    BuildContext context,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');

    final response = await http
        .post(
          Uri.parse('$URL.event_checkin'),
          body: {
            'user': user,
            'event_id': eventId,
            'lat': lat.toString(),
            'lng': lng.toString(),
            'address': address,
          },
          headers: {'Authorization': token ?? ''},
        )
        .timeout(const Duration(seconds: 25));

    debugPrint(
      '[EventApi] eventCheckin response: ${response.statusCode} ${response.body}',
    );

    return json.decode(response.body);
  }

  static Future<Map<String, dynamic>> eventCheckout(
    String? user,
    String eventId,
    double lat,
    double lng,
    String address,
    String workingHrs,
    String distance,
    String lastLatLng,
    String locationLogs,
    BuildContext context, {
    required String customOtp,
  }) async {
    final otp = customOtp.trim();
    if (!EventOtp.isValid(otp)) {
      throw ArgumentError(EventOtp.validationMessage);
    }
    final prefs = await SharedPreferences.getInstance();

    final String? token = prefs.getString('token');

    // The deployed checkout method may ignore unknown arguments. Persist and
    // confirm the exact Event field through the assigned-user API first.
    await saveVisitOtp(eventId: eventId, customOtp: otp);

    final response = await http
        .post(
          Uri.parse('$URL.event_checkout'),
          body: {
            'user': user,
            'event_id': eventId,
            'lat': lat.toString(),
            'lng': lng.toString(),
            'address': address,
            'working_hrs': workingHrs,
            'distance': distance,
            'last_lat_lng': lastLatLng,
            "location_logs": locationLogs,
            'custom_otp': otp,
          },
          headers: {'Authorization': token ?? ''},
        )
        .timeout(const Duration(seconds: 25));

    return json.decode(response.body);
  }

  static Future<bool> saveCustomerLocationFromVisit({
    required String eventId,
    required String referenceDocname,
    required BuildContext context,
  }) async {
    final pingResult = await Check.pingpong();
    if (pingResult == false) {
      Warning.show(
        context,
        'ERP Site is not in working condition! Please try again later.',
        'Error',
      );
      return false;
    }

    final prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');
    final siteUrl = dotenv.env['SITE_URL'] ?? '';

    if (token == null || token.isEmpty || siteUrl.isEmpty) {
      return false;
    }

    try {
      final visitResponse = await http.get(
        Uri.parse('$siteUrl/api/method/visit?event_id=$eventId'),
        headers: {
          'Authorization': token,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      );

      debugPrint(
        '[EventApi] saveCustomerLocationFromVisit -> event_id=$eventId, '
        'reference_docname=$referenceDocname',
      );

      debugPrint(
        '[EventApi] visit lookup response: '
        '${visitResponse.statusCode} ${visitResponse.body}',
      );

      if (visitResponse.statusCode != 200) {
        return false;
      }

      final visitJson = jsonDecode(visitResponse.body);
      final visitData = _extractVisitPayload(visitJson, eventId);

      if (visitData == null) {
        debugPrint(
          '[EventApi] saveCustomerLocationFromVisit -> no visit payload found for $eventId',
        );
        return false;
      }

      final opportunityResponse = await http.get(
        Uri.parse(
          '$siteUrl/api/resource/Opportunity/${Uri.encodeComponent(referenceDocname)}',
        ),
        headers: {
          'Authorization': token,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      );

      debugPrint(
        '[EventApi] opportunity fetch response: '
        '${opportunityResponse.statusCode} ${opportunityResponse.body}',
      );

      if (opportunityResponse.statusCode != 200) {
        return false;
      }

      final opportunityJson = jsonDecode(opportunityResponse.body);
      final opportunityData = opportunityJson['data'];

      if (opportunityData is! Map<String, dynamic>) {
        return false;
      }

      final List<Map<String, dynamic>> existingRows =
          ((opportunityData['custom_location'] as List?) ?? [])
              .whereType<Map>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList();

      existingRows.removeWhere((row) => row['event_id']?.toString() == eventId);

      existingRows.add({
        'doctype': 'Customer Location',
        'location': visitData['source']?.toString() ?? '',
        'latitude': visitData['latitude']?.toString() ?? '',
        'longitude': visitData['longitude']?.toString() ?? '',
        'location_type': visitData['location']?.toString() ?? '',
        'event_id': visitData['event_id']?.toString() ?? eventId,
      });

      final response = await http.put(
        Uri.parse(
          '$siteUrl/api/resource/Opportunity/${Uri.encodeComponent(referenceDocname)}',
        ),
        headers: {
          'Authorization': token,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({'custom_location': existingRows}),
      );

      debugPrint(
        '[EventApi] saveCustomerLocationFromVisit response: '
        '${response.statusCode} ${response.body}',
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('[EventApi] saveCustomerLocationFromVisit exception: $e');
      return false;
    }
  }

  static Map<String, dynamic>? _extractVisitPayload(
    dynamic responseJson,
    String eventId,
  ) {
    final payload = responseJson['data'] ?? responseJson['message'];

    if (payload is Map<String, dynamic>) {
      return payload;
    }

    if (payload is List) {
      for (final item in payload) {
        if (item is Map<String, dynamic>) {
          final currentEventId = item['event_id']?.toString();
          if (currentEventId == eventId) {
            return item;
          }
        }
      }

      for (final item in payload) {
        if (item is Map<String, dynamic>) {
          return item;
        }
      }
    }

    return null;
  }

  static Future<bool> updateEventLocationType({
    required String eventId,
    required String locationType,
    required BuildContext context,
  }) async {
    final pingResult = await Check.pingpong();
    if (pingResult == false) {
      Warning.show(
        context,
        'ERP Site is not in working condition! Please try again later.',
        'Error',
      );
      return false;
    }

    final prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');
    final siteUrl = dotenv.env['SITE_URL'] ?? '';

    if (token == null || token.isEmpty || siteUrl.isEmpty) {
      return false;
    }

    try {
      final response = await http.put(
        Uri.parse('$siteUrl/api/resource/Event/$eventId'),
        headers: {
          'Authorization': token,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({'location': locationType}),
      );

      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<List<Map<String, dynamic>>> getOpportunityLocations({
    required String referenceDocname,
    required BuildContext context,
  }) async {
    final pingResult = await Check.pingpong();
    if (pingResult == false) {
      Warning.show(
        context,
        'ERP Site is not in working condition! Please try again later.',
        'Error',
      );
      return [];
    }

    final prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');
    final siteUrl = dotenv.env['SITE_URL'] ?? '';

    if (token == null || token.isEmpty || siteUrl.isEmpty) {
      return [];
    }

    try {
      final response = await http.get(
        Uri.parse(
          '$siteUrl/api/resource/Opportunity/${Uri.encodeComponent(referenceDocname)}',
        ),
        headers: {
          'Authorization': token,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      );

      debugPrint(
        '[EventApi] getOpportunityLocations response: ${response.statusCode} ${response.body}',
      );

      if (response.statusCode != 200) {
        return [];
      }

      final data = jsonDecode(response.body);
      final opportunity = data['data'];
      if (opportunity is! Map<String, dynamic>) {
        return [];
      }

      return opportunityLocationRows(opportunity);
    } catch (e) {
      debugPrint('[EventApi] getOpportunityLocations exception: $e');
      return [];
    }
  }

  static Future<void> sendOtp(eventId, BuildContext context) async {
    final pingResult = await Check.pingpong();
    if (pingResult == false) {
      Warning.show(
        context,
        'ERP Site is not in working condition! Please try again later.',
        'Error',
      );
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');

    final response = await http.get(
      Uri.parse('$URL.send_otp?event_id=$eventId'),
      headers: {'Authorization': token!},
    );

    if (response.statusCode != 200) {
      throw Exception("Failed to send OTP");
    }
  }

  static Future<bool> verifyOtp(String otp, String eventId) async {
    if (!EventOtp.isValid(otp)) return false;
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');

    if (token == null || token.isEmpty) return false;

    try {
      final response = await http.post(
        Uri.parse('$URL.verify_otp'),
        headers: {
          'Authorization': token,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({'otp': otp, 'event_id': eventId}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['message']['status'] == 'success';
      } else {
        return false;
      }
    } catch (e) {
      return false;
    }
  }
}
