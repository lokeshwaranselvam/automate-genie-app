/// Contact phone fields accepted by the Opportunity call action.
abstract final class OpportunityContact {
  static bool isPhoneField(String key) => const {
    'contact_mobile',
    'mobile',
    'mobile_no',
    'mobile_number',
    'phone',
    'phone_no',
    'phone_number',
    'contact_number',
    'contact_no',
  }.contains(key.toLowerCase().replaceFirst(RegExp(r'^custom_'), ''));

  static String number(dynamic value) =>
      value is String || value is num ? value.toString().trim() : '';
}
