/// Recognizes only the server's pending short-visit checkout restriction.
/// Server HTML and its URL are never rendered or used for navigation.
class ShortVisitCheckoutNotice {
  static const url = 'https://16.itgenie.online/SVR';
  static const actionLabel = 'SVR';
  final int? pendingCount;

  const ShortVisitCheckoutNotice(this.pendingCount);

  static ShortVisitCheckoutNotice? fromMessage(String message) {
    final text =
        message
            .replaceAll(RegExp(r'<[^>]*>'), ' ')
            .replaceAll('&nbsp;', ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    if (!RegExp(
          r'checkout\s+restricted',
          caseSensitive: false,
        ).hasMatch(text) ||
        !RegExp(
          r'pending\s+short\s+visit',
          caseSensitive: false,
        ).hasMatch(text)) {
      return null;
    }
    final count = RegExp(
      r'\b(\d+)\s+pending\s+short\s+visit',
      caseSensitive: false,
    ).firstMatch(text)?.group(1);
    return ShortVisitCheckoutNotice(int.tryParse(count ?? ''));
  }

  String get message {
    final summary =
        pendingCount == null
            ? 'You have pending short visit reasons for today.'
            : 'You have $pendingCount pending short visit '
                '${pendingCount == 1 ? 'reason' : 'reasons'} for today.';
    return '$summary\n\n'
        'Before checking out:\n'
        '1. Open the pending short visits below.\n'
        '2. Submit a reason for each pending visit.\n'
        '3. Return to Attendance and check out again.';
  }
}
