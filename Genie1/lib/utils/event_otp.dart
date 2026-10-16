/// Event OTPs stay as text so leading zeroes are preserved.
class EventOtp {
  static const validationMessage = 'OTP must contain exactly 4 digits.';

  static bool isValid(String value) =>
      RegExp(r'^[0-9]{4}$').hasMatch(value.trim());
}
