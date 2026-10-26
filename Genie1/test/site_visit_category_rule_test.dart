import 'package:flutter_test/flutter_test.dart';
import 'package:homegenie/utils/site_visit_category_rule.dart';

void main() {
  test(
    'server controls document type and required fields without category names',
    () {
      final rule = SiteVisitCategoryRule.fromApi({
        'reference_mode': 'document',
        'reference_doctype': 'Measurement',
        'required_fields': [
          'reference_name',
          'map_link',
          'latitude',
          'longitude',
        ],
      });
      expect(rule.isDocument, isTrue);
      expect(rule.isDirect, isFalse);
      expect(rule.referenceDoctype, 'Measurement');
      expect(rule.requiredFields, contains('reference_name'));
      expect(rule.requiredFields, isNot(contains('opportunity')));
    },
  );

  test('inconsistent routes and malformed required fields are rejected', () {
    for (final value in [
      null,
      {
        'reference_mode': 'none',
        'reference_doctype': 'Opportunity',
        'required_fields': [],
      },
      {
        'reference_mode': 'document',
        'reference_doctype': '',
        'required_fields': [],
      },
      {
        'reference_mode': 'opportunity',
        'reference_doctype': 'Measurement',
        'required_fields': [],
      },
      {
        'reference_mode': 'none',
        'reference_doctype': '',
        'required_fields': [null],
      },
    ]) {
      expect(() => SiteVisitCategoryRule.fromApi(value), throwsFormatException);
    }
  });
}
