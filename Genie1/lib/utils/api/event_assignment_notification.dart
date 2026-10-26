import 'dart:async';
import 'dart:convert';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Only assignment pushes generated for a specific Event and user are accepted.
class EventAssignmentNotification {
  const EventAssignmentNotification(
    this.eventId,
    this.assignmentId,
    this.recipient,
  );
  final String eventId, assignmentId, recipient;

  static EventAssignmentNotification? fromData(Map<String, dynamic> data) {
    if (data['type'] != 'EVENT_ASSIGNED' || data['doctype'] != 'Event') {
      return null;
    }
    final event = data['docname']?.toString().trim() ?? '';
    final assignment = data['assignment_id']?.toString().trim() ?? '';
    final user = data['for_user']?.toString().trim().toLowerCase() ?? '';
    if (event.isEmpty ||
        assignment.isEmpty ||
        user.isEmpty ||
        user == 'guest') {
      return null;
    }
    return EventAssignmentNotification(event, assignment, user);
  }
}

/// Serializes duplicate deliveries in this isolate; receipts also survive restarts.
class EventAssignmentAlerts {
  static Future<void> _queue = Future<void>.value();

  static Future<bool> deliver({
    required Map<String, dynamic> data,
    required Future<void> Function() notify,
    Future<void> Function()? playSound,
  }) {
    final result = _queue.then((_) async {
      final assignment = EventAssignmentNotification.fromData(data);
      if (assignment == null) return false;
      if (!dotenv.isInitialized) await dotenv.load(fileName: '.env');
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final sid = prefs.getString('session_sid');
      final user = prefs.getString('session_username')?.trim().toLowerCase();
      if (sid == null || sid.isEmpty || user != assignment.recipient) {
        return false;
      }
      final site = dotenv.env['SITE_URL']?.trim() ?? '';
      final key = 'event_assignment_alerts_${jsonEncode([site, user])}';
      final receipt = jsonEncode([assignment.eventId, assignment.assignmentId]);
      final seen = prefs.getStringList(key) ?? [];
      if (seen.contains(receipt)) return false;
      await notify();
      // Do not play an alarm into a different account if logout raced delivery.
      await prefs.reload();
      if (prefs.getString('session_sid') != sid ||
          prefs.getString('session_username')?.trim().toLowerCase() != user) {
        return true;
      }
      await prefs.setStringList(
        key,
        [...seen, receipt].reversed.take(500).toList().reversed.toList(),
      );
      if (playSound != null) await playSound();
      return true;
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}
