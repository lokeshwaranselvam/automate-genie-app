import 'event_category_policy.dart';

/// Supported form workflows selected by the server, without category-name checks.
class SiteVisitCategoryRule {
  const SiteVisitCategoryRule({
    required this.mode,
    required this.referenceDoctype,
    required this.requiredFields,
  });

  final String mode;
  final String referenceDoctype;
  final Set<String> requiredFields;

  bool get isDirect => mode == 'none';
  bool get isDocument => mode == 'document';

  factory SiteVisitCategoryRule.fromApi(Object? value) {
    if (value is! Map ||
        !const [
          'none',
          'opportunity',
          'document',
        ].contains(value['reference_mode']) ||
        value['reference_doctype'] is! String ||
        value['required_fields'] is! List ||
        (value['required_fields'] as List).any((field) => field is! String)) {
      throw const FormatException(
        'ERP returned an invalid event category rule.',
      );
    }
    final mode = value['reference_mode'] as String;
    final doctype = value['reference_doctype'] as String;
    if ((mode == 'none' && doctype.isNotEmpty) ||
        (mode == 'opportunity' && doctype != 'Opportunity') ||
        (mode == 'document' && (doctype.isEmpty || doctype == 'Opportunity'))) {
      throw const FormatException(
        'ERP returned an inconsistent event category rule.',
      );
    }
    return SiteVisitCategoryRule(
      mode: mode,
      referenceDoctype: doctype,
      requiredFields: Set<String>.from(value['required_fields'] as List),
    );
  }

  /// Compatibility only for servers that have not deployed category rules yet.
  factory SiteVisitCategoryRule.legacy(String? category) {
    final normalized = category?.trim().toLowerCase();
    final doctype = switch (normalized) {
      'measurement' => 'Measurement',
      'installation' => 'Installation Note',
      _ => isLocationFreeEventCategory(category) ? '' : 'Opportunity',
    };
    return SiteVisitCategoryRule.fromApi({
      'reference_mode':
          doctype.isEmpty
              ? 'none'
              : doctype == 'Opportunity'
              ? 'opportunity'
              : 'document',
      'reference_doctype': doctype,
      'required_fields': [
        'category',
        'summary',
        'starts_on',
        'ends_on',
        'assigned_to',
        if (doctype == 'Opportunity') ...['opportunity', 'location_row'],
        if (doctype.isNotEmpty && doctype != 'Opportunity') ...[
          'reference_name',
          'map_link',
          'latitude',
          'longitude',
        ],
      ],
    });
  }
}
