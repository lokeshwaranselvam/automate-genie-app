import 'package:flutter/widgets.dart';

import 'warning.dart';

/// One acknowledgement for concurrent/periodic attendance authentication errors.
class AttendanceSessionNotice {
  bool _shown = false;
  bool get isShown => _shown;

  void show(BuildContext context, {required VoidCallback onAcknowledged}) {
    if (_shown || !context.mounted) return;
    _shown = true;
    Warning.show(
      context,
      'Your login credentials are no longer valid. Please sign in again.',
      'Session Expired',
      onAction: onAcknowledged,
    );
  }
}
