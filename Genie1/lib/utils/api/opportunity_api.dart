import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import 'session_auth.dart';
import '../api_business_policy.dart';

/// Opportunity access using Frappe's normal document permissions.
class OpportunityApi {
  static const editableStatuses = [
    'Open',
    'Follow-up',
    'Demo',
    'VC',
    'Duplicate Lead',
    'Junk',
    'Not Interested',
    'Hot Followup',
    'RNR',
    'B2B Database',
  ];

  static DateTime get earliestFollowUpDate {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  static bool isFutureFollowUpDate(Object? value) {
    if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      return false;
    }
    final date = DateTime.tryParse(value);
    return date != null &&
        date.toIso8601String().substring(0, 10) == value &&
        !date.isBefore(earliestFollowUpDate);
  }

  static const pageSize = 50;

  static Future<dynamic> _read({
    String? name,
    int offset = 0,
    String phone = '',
    String status = '',
  }) async {
    final site = dotenv.env['SITE_URL']?.trim() ?? '';
    final base = Uri.tryParse(site);
    if (base == null || base.scheme != 'https' || base.host.isEmpty) {
      throw StateError('The ERP site URL is not configured.');
    }
    final sid = await SessionAuthApi.getSessionId();
    final user = await SessionAuthApi.getActiveSessionUser();
    if (sid == null || sid.isEmpty || user == null) {
      throw StateError('Your session expired. Please sign in again.');
    }
    Future<void> assertSession() async {
      if (await SessionAuthApi.getSessionId() != sid ||
          await SessionAuthApi.getSavedSessionUser() != user ||
          dotenv.env['SITE_URL']?.trim() != site) {
        throw StateError('Your account changed. Reopen Opportunities.');
      }
    }

    await assertSession();
    final resource = base.resolve('/api/resource/Opportunity');
    final uri =
        name == null
            ? resource.replace(
              queryParameters: {
                'fields': jsonEncode([
                  'name',
                  'owner',
                  'opportunity_owner',
                  'customer_name',
                  'party_name',
                  'status',
                  'creation',
                ]),
                'filters': jsonEncode([
                  ['opportunity_owner', '=', user],
                  if (status.isNotEmpty) ['status', '=', status],
                ]),
                if (phone.isNotEmpty)
                  'or_filters': jsonEncode([
                    [
                      'contact_mobile',
                      'like',
                      '%${phone.split('').join('%')}%',
                    ],
                    ['phone', 'like', '%${phone.split('').join('%')}%'],
                  ]),
                'order_by': 'creation desc, name desc',
                'limit_start': '$offset',
                'limit_page_length': '$pageSize',
              },
            )
            : Uri.parse('${resource.toString()}/${Uri.encodeComponent(name)}');
    final client = http.Client();
    late http.Response response;
    try {
      final request =
          http.Request('GET', uri)
            ..followRedirects = false
            ..headers.addAll({
              'Cookie': 'sid=$sid',
              'Accept': 'application/json',
              'Cache-Control': 'no-cache, no-store',
            });
      response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 25));
    } finally {
      client.close();
    }
    await assertSession();
    if (response.statusCode != 200) {
      throw StateError(switch (response.statusCode) {
        401 => 'Your session expired. Please sign in again.',
        403 => 'You do not have permission to view these opportunities.',
        404 => 'This opportunity is no longer available.',
        _ =>
          'Could not load opportunities (${response.statusCode}). Please retry.',
      });
    }
    final body = jsonDecode(response.body);
    final data = body is Map ? body['data'] : null;
    final rows = name == null ? data : [data];
    if (rows is! List || rows.any((row) => row is! Map)) {
      throw const FormatException(
        'The ERP returned an invalid Opportunity response.',
      );
    }
    for (final row in rows) {
      if (row['opportunity_owner'] != user ||
          (name != null && row['name'] != name)) {
        throw StateError(
          'Only opportunities where you are the Opportunity Owner can be displayed here.',
        );
      }
    }
    return data;
  }

  static Future<List<Map<String, dynamic>>> getMyOpportunities({
    int offset = 0,
    String phone = '',
    String status = '',
  }) async {
    if (offset < 0) throw ArgumentError('Invalid page offset.');
    final digits = phone.replaceAll(RegExp(r'[+\s().-]'), '');
    if (digits.isNotEmpty && !RegExp(r'^\d{1,15}$').hasMatch(digits)) {
      throw ArgumentError('Enter a valid phone number.');
    }
    final rows =
        await _read(offset: offset, phone: digits, status: status.trim())
            as List;
    return rows.map((row) => Map<String, dynamic>.from(row as Map)).toList();
  }

  static Future<Map<String, dynamic>> getDetails(String name) async {
    if (name.trim().isEmpty) throw ArgumentError('Opportunity ID is required.');
    return Map<String, dynamic>.from(await _read(name: name));
  }

  static Future<OpportunityEditOptions> getEditOptions({String? name}) async {
    final body = await _request(
      '/api/method/frappe.desk.form.load.getdoctype',
      query: {'doctype': 'Opportunity'},
    );
    final docs = body['docs'];
    if (docs is! List) {
      throw const FormatException('ERP did not return Opportunity fields.');
    }
    final meta =
        docs
            .whereType<Map>()
            .where((doc) => doc['name'] == 'Opportunity')
            .firstOrNull;
    final fields = (meta?['fields'] as List? ?? []).whereType<Map>().toList();
    final status =
        fields.where((field) => field['fieldname'] == 'status').firstOrNull;
    final statuses =
        (status?['options']?.toString() ?? '')
            .split('\n')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet()
            .toList();
    String normalize(dynamic value) =>
        value.toString().toLowerCase().replaceAll(RegExp('[^a-z]'), '');
    final followUp =
        fields
            .where(
              (field) =>
                  field['fieldtype'] == 'Date' &&
                  (normalize(field['label']) == 'nextfollowupdate' ||
                      normalize(
                            field['fieldname'],
                          ).replaceFirst('custom', '') ==
                          'nextfollowupdate'),
            )
            .toList();
    final notes =
        fields
            .where(
              (field) =>
                  field['fieldname'] == 'notes' &&
                  field['fieldtype'] == 'Table',
            )
            .firstOrNull;
    final child =
        docs
            .whereType<Map>()
            .where((doc) => doc['name'] == notes?['options'])
            .firstOrNull;
    final hasNote = (child?['fields'] as List? ?? []).whereType<Map>().any(
      (field) => field['fieldname'] == 'note',
    );
    if (statuses.isEmpty) {
      throw const FormatException(
        'ERP did not return Opportunity status options.',
      );
    }
    final policyBody = await _request(
      '/api/method/mobile_opportunity_policy',
      query: {'action': 'get', if (name != null) 'name': name},
    );
    final policy = policyBody['message'];
    final expectedUser = await SessionAuthApi.getSavedSessionUser();
    if (policy is! Map ||
        policy['current_user'] != expectedUser ||
        policy['editable_statuses'] is! List ||
        (policy['editable_statuses'] as List).isEmpty ||
        (policy['editable_statuses'] as List).any(
          (value) => value is! String || !statuses.contains(value),
        ) ||
        policy['status_transitions'] is! Map ||
        policy['followup_policy'] is! Map) {
      throw const FormatException('ERP returned invalid Opportunity policy.');
    }
    final transitions = <String, List<String>>{};
    for (final entry in (policy['status_transitions'] as Map).entries) {
      if (entry.key is! String ||
          entry.value is! List ||
          (entry.value as List).any((value) => value is! String)) {
        throw const FormatException(
          'ERP returned invalid Opportunity transitions.',
        );
      }
      transitions[entry.key] = List<String>.from(entry.value);
    }
    final datePolicy = policy['followup_policy'] as Map;
    final earliestText = datePolicy['earliest_date']?.toString() ?? '';
    final earliest =
        earliestText.isEmpty ? null : DateTime.tryParse(earliestText);
    if (datePolicy['allow_past'] is! bool ||
        (earliestText.isNotEmpty &&
            (earliest == null ||
                earliest.toIso8601String().substring(0, 10) != earliestText))) {
      throw const FormatException(
        'ERP returned invalid Opportunity date rules.',
      );
    }
    return OpportunityEditOptions(
      statuses: statuses,
      followUpField:
          followUp.length == 1
              ? followUp.single['fieldname']?.toString()
              : null,
      notesType: hasNote ? (notes?['options']?.toString()) : null,
      allowedStatuses: List<String>.from(policy['editable_statuses']),
      statusTransitions: transitions,
      allowPastFollowup: datePolicy['allow_past'],
      earliestDate: earliest,
      businessPolicy: ApiBusinessPolicy.fromApi(policy['business_policy']),
    );
  }

  /// Synchronizes sales stage when status changes. Frappe enforces write permissions,
  /// field permissions, workflow rules and document validation on PUT.
  static Future<Map<String, dynamic>> updateDetails({
    required Map<String, dynamic> original,
    required Map<String, dynamic> changes,
  }) async {
    if (changes.isEmpty) return original;
    final options = await getEditOptions(name: original['name']?.toString());
    final allowed = {
      'status',
      if (options.notesType != null) 'notes',
      if (options.followUpField != null) options.followUpField!,
    };
    if (changes.keys.any((key) => !allowed.contains(key))) {
      throw ArgumentError(
        'Only status, notes and next follow-up date can be updated.',
      );
    }
    if (changes.containsKey('status') &&
        (!options
                .statusesFor(original['status']?.toString() ?? '')
                .contains(changes['status']) ||
            !options.statuses.contains(changes['status']))) {
      throw ArgumentError('Select a valid Opportunity status.');
    }
    final dateField = options.followUpField;
    if (dateField != null) {
      final date =
          changes.containsKey(dateField)
              ? changes[dateField]
              : original[dateField];
      if ((changes.containsKey(dateField) ||
              (date?.toString().isNotEmpty ?? false)) &&
          !options.isAllowedFollowupDate(date)) {
        throw ArgumentError(
          'Select a valid next follow-up date on or after ${options.firstFollowupDate.toIso8601String().substring(0, 10)}.',
        );
      }
    }
    final name = original['name']?.toString() ?? '';
    final fresh = await getDetails(name);
    if (original['modified'] == null ||
        fresh['modified'] != original['modified']) {
      throw StateError(
        'This opportunity changed. Refresh it before editing again.',
      );
    }
    final body = await _request(
      '/api/method/mobile_opportunity_policy',
      changes: {
        'action': 'save',
        'name': name,
        'changes': changes,
        'modified': original['modified'],
      },
      expectedOpportunityOwner: original['opportunity_owner']?.toString(),
    );
    final data = body['data'];
    if (data is! Map ||
        data['name'] != name ||
        data['owner'] != original['owner'] ||
        data['opportunity_owner'] != original['opportunity_owner']) {
      throw const FormatException(
        'ERP did not confirm the Opportunity update. Refresh before retrying.',
      );
    }
    return Map<String, dynamic>.from(data);
  }

  static Future<Map<String, dynamic>> _request(
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? changes,
    String? expectedOpportunityOwner,
  }) async {
    final site = dotenv.env['SITE_URL']?.trim() ?? '';
    final base = Uri.tryParse(site);
    if (base == null ||
        base.scheme != 'https' ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty) {
      throw StateError('The ERP site URL is not configured.');
    }
    final sid = await SessionAuthApi.getSessionId();
    final user = await SessionAuthApi.getActiveSessionUser();
    if (sid == null || sid.isEmpty || user == null || user == 'Guest') {
      throw StateError('Your session expired. Please sign in again.');
    }
    if (changes != null && user != expectedOpportunityOwner) {
      throw StateError('Your account changed. Reopen Opportunities.');
    }
    Future<void> assertSession() async {
      if (await SessionAuthApi.getSessionId() != sid ||
          await SessionAuthApi.getSavedSessionUser() != user ||
          dotenv.env['SITE_URL']?.trim() != site) {
        throw StateError('Your account changed. Reopen Opportunities.');
      }
    }

    final client = http.Client();
    Future<http.Response> send(
      String method,
      Uri uri, {
      String? csrf,
      bool html = false,
    }) async {
      await assertSession();
      final request =
          http.Request(method, uri)
            ..followRedirects = false
            ..headers.addAll({
              'Cookie': 'sid=$sid',
              'Accept': html ? 'text/html' : 'application/json',
              'Cache-Control': 'no-cache, no-store',
              if (csrf != null) 'Content-Type': 'application/json',
              if (csrf != null) 'X-Frappe-CSRF-Token': csrf,
            });
      if (csrf != null) {
        request.body = jsonEncode({...changes!, 'csrf_token': csrf});
      }
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 25));
      await assertSession();
      return response;
    }

    Future<String> token() async {
      var uri = base.resolve('/app');
      for (var i = 0; i <= 3; i++) {
        final response = await send('GET', uri, html: true);
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers['location'];
          if (location == null) break;
          final next = uri.resolve(location);
          if (next.origin != base.origin || next.userInfo.isNotEmpty) break;
          uri = next;
          continue;
        }
        if (response.statusCode == 200) {
          final value = RegExp(
            r'''frappe\.csrf_token\s*=\s*["']([^"']+)["']''',
          ).firstMatch(response.body)?.group(1);
          if (value != null && value.isNotEmpty) return value;
        }
        break;
      }
      throw StateError(
        'Could not initialize your update session. Sign in again.',
      );
    }

    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        final response = await send(
          changes == null
              ? 'GET'
              : path == '/api/method/mobile_opportunity_policy'
              ? 'POST'
              : 'PUT',
          base.resolve(path).replace(queryParameters: query),
          csrf: changes == null ? null : await token(),
        );
        dynamic body;
        try {
          body = jsonDecode(response.body);
        } catch (_) {
          throw const FormatException(
            'ERP did not confirm the request. Refresh before retrying.',
          );
        }
        final csrfFailure =
            body is Map &&
            (body['exc_type'] == 'CSRFTokenError' ||
                body['exception']?.toString().startsWith(
                      'frappe.exceptions.CSRFTokenError:',
                    ) ==
                    true);
        if (changes != null &&
            attempt == 0 &&
            response.statusCode != 200 &&
            csrfFailure) {
          continue;
        }
        if (response.statusCode != 200 ||
            body is! Map ||
            body['exc_type'] != null ||
            body['exception'] != null) {
          if (response.statusCode == 417) {
            String? validationMessage;
            // Read user-facing validation messages only, never server tracebacks.
            try {
              final raw = body is Map ? body['_server_messages'] : null;
              final messages = raw is String ? jsonDecode(raw) : raw;
              if (messages is List) {
                final texts = <String>[];
                for (final item in messages) {
                  final entry = item is String ? jsonDecode(item) : item;
                  final message = entry is Map ? entry['message'] : null;
                  if (message is String && message.trim().isNotEmpty) {
                    texts.add(
                      message.replaceAll(RegExp(r'<[^>]*>'), '').trim(),
                    );
                  }
                }
                if (texts.isNotEmpty) validationMessage = texts.join('\n');
              }
            } catch (_) {
              // Malformed validation details use the existing safe fallback.
            }
            throw OpportunityActionError(
              statusCode: response.statusCode,
              validationMessage: validationMessage,
            );
          }
          throw StateError(switch (response.statusCode) {
            401 => 'Your session expired. Please sign in again.',
            403 => 'You do not have permission for this Opportunity action.',
            409 => 'This opportunity changed. Refresh before editing again.',
            _ =>
              'ERP could not complete this Opportunity action (${response.statusCode}). Check required fields and workflow rules in ERP.',
          });
        }
        return Map<String, dynamic>.from(body);
      }
      throw StateError(
        'Could not initialize your update session. Sign in again.',
      );
    } finally {
      client.close();
    }
  }
}

class OpportunityEditOptions {
  const OpportunityEditOptions({
    required this.statuses,
    this.followUpField,
    this.notesType,
    this.allowedStatuses,
    this.statusTransitions = const {},
    this.allowPastFollowup = false,
    this.earliestDate,
    this.businessPolicy = ApiBusinessPolicy.empty,
  });
  final List<String> statuses;
  final String? followUpField;
  final String? notesType;
  final List<String>? allowedStatuses;
  final Map<String, List<String>> statusTransitions;
  final bool allowPastFollowup;
  final DateTime? earliestDate;
  final ApiBusinessPolicy businessPolicy;

  List<String> statusesFor(String current) {
    final allowed = allowedStatuses ?? OpportunityApi.editableStatuses;
    final targets = statusTransitions[current];
    return allowed
        .where(
          (value) =>
              targets == null || targets.contains(value) || value == current,
        )
        .toList();
  }

  DateTime get firstFollowupDate {
    final today = OpportunityApi.earliestFollowUpDate;
    if (!allowPastFollowup) {
      return earliestDate != null && earliestDate!.isAfter(today)
          ? earliestDate!
          : today;
    }
    return earliestDate ?? DateTime(1900);
  }

  bool isAllowedFollowupDate(Object? value) {
    if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      return false;
    }
    final date = DateTime.tryParse(value);
    return date != null &&
        date.toIso8601String().substring(0, 10) == value &&
        !date.isBefore(firstFollowupDate);
  }
}

/// Preserves the response status for the edit dialog without exposing tracebacks.
class OpportunityActionError extends StateError {
  OpportunityActionError({required this.statusCode, this.validationMessage})
    : super(
        validationMessage ??
            'ERP could not save this Opportunity. Check required fields and workflow rules in ERP.',
      );
  final int statusCode;
  final String? validationMessage;
}
