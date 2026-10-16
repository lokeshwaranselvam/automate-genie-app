import 'dart:async';

import 'package:flutter/material.dart';

import '../api/notification_inbox.dart';

/// Uses inbox events and app resume; it never polls for notifications.
class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key, required this.onPressed});
  final VoidCallback onPressed;

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell>
    with WidgetsBindingObserver {
  StreamSubscription<void>? _subscription;
  bool _hasNew = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = NotificationInbox.changes.listen((_) => _refreshCached());
    unawaited(_refreshCached());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshCached());
  }

  Future<void> _refreshCached() async {
    try {
      final rows = await NotificationInbox.cached();
      if (mounted && _hasNew != rows.isNotEmpty) {
        setState(() => _hasNew = rows.isNotEmpty);
      }
    } catch (_) {
      // Storage failures must not interrupt Home or clear an existing badge.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Notifications',
    onPressed: widget.onPressed,
    icon: Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(
          Icons.notifications_none_rounded,
          color: Color(0xFF07143E),
          size: 27,
        ),
        if (_hasNew)
          Positioned(
            right: -2,
            top: -1,
            child: Container(
              key: const ValueKey('notification-unread-dot'),
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Color(0xFFFF4167),
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    ),
  );
}
