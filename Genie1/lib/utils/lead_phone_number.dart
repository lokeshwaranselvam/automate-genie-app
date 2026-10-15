/// Basic format validation; does not claim to verify WhatsApp registration.
class LeadPhoneNumber {
  static String normalize(String value) =>
      value.trim().replaceAll(RegExp(r'[ ().-]'), '');

  static String? validateWhatsApp(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'WhatsApp Number is required.';
    }
    if (value.trim().length > 64 ||
        !RegExp(r'^[+0-9 ().-]+$').hasMatch(value.trim())) {
      return 'Enter a valid WhatsApp number (7–15 digits).';
    }
    final number = normalize(value);
    if (!RegExp(r'^\+?[0-9]{7,15}$').hasMatch(number) ||
        number.startsWith('+0')) {
      return 'Enter a valid WhatsApp number (7–15 digits).';
    }
    return null;
  }
}
