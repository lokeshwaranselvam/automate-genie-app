import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widget/pending_work_alarm_player.dart';
import 'pending_work_api.dart';
import 'session_auth.dart';

/// Checks the pending sections while the app is open so new entries alarm
/// without requiring the user to pull to refresh.
class PendingWorkMonitor {
  PendingWorkMonitor._();

  static const Duration _pollInterval = Duration(seconds: 20);
  static Timer? _timer;
  static bool _checking = false;
  static Future<void> _snapshotQueue = Future<void>.value();
  static final StreamController<String> _newEntrySections =
      StreamController<String>.broadcast();

  static Stream<String> get newEntrySections => _newEntrySections.stream;

  static void start() {
    _timer ??= Timer.periodic(_pollInterval, (_) => checkNow());
    unawaited(checkNow());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static Future<void> checkNow() async {
    if (_checking) return;
    _checking = true;

    try {
      // Ask the server which sections this session may access before polling
      // them. This avoids forbidden production requests for sales-only users
      // and includes sales opportunities for users with the Sales User role.
      final dashboard = await PendingWorkApi.getMobileDashboard();
      final rawAllowedSections = dashboard['available_sections'];
      final allowedSections =
          rawAllowedSections is List
              ? rawAllowedSections.map((section) => section.toString()).toSet()
              : {'stock', 'manufacturing', 'projects'};
      const supportedSections = [
        'stock',
        'manufacturing',
        'projects',
        'same_area_city',
        'opportunities',
        'overdue_followups',
        'overdue_closing',
        'draft_delivery_plans',
      ];
      final names = supportedSections.where(allowedSections.contains).toList();
      final sections = await Future.wait(
        names.map(PendingWorkApi.getPendingSectionItems),
      );

      final newSections = <String>[];
      var newEntryCount = 0;
      for (var i = 0; i < names.length; i++) {
        final sectionNewCount = await recordSnapshot(names[i], sections[i]);
        if (sectionNewCount > 0) {
          newSections.add(names[i]);
          newEntryCount += sectionNewCount;
        }
      }

      for (final section in newSections) {
        _newEntrySections.add(section);
      }
      if (newSections.isNotEmpty) {
        debugPrint(
          'New pending work found ($newEntryCount): ${newSections.join(', ')}.',
        );
        // One alarm per poll. Playing once per entry blocked the monitor for
        // 5 seconds per item (e.g. 20 new items = 100 seconds of alarm).
        await PendingWorkAlarmPlayer.play();
      }
    } catch (error) {
      debugPrint('Pending-work monitor could not refresh: $error');
    } finally {
      _checking = false;
    }
  }

  /// Saves the latest IDs and returns how many new records appeared since the
  /// baseline. Shared with the section page refresh path.
  static Future<int> recordSnapshot(
    String section,
    List<Map<String, dynamic>> items, {
    List<Map<String, dynamic>> previousItems = const [],
  }) {
    final result = Completer<int>();
    _snapshotQueue = _snapshotQueue.then((_) async {
      try {
        final preferences = await SharedPreferences.getInstance();
        // The session was just verified by the request that fetched these
        // items, so use the saved username instead of another network call.
        final user = await SessionAuthApi.getSavedSessionUser();
        final userKey = (user ?? 'unknown').trim().toLowerCase();
        final key = 'pending_work_seen_${userKey}_$section';
        final savedIds = preferences.getStringList(key);
        final oldIds = savedIds?.toSet() ?? previousItems.map(_itemId).toSet();
        final hasBaseline = savedIds != null || previousItems.isNotEmpty;
        final currentIds = items.map(_itemId).toSet();
        final newItemCount =
            hasBaseline ? currentIds.difference(oldIds).length : 0;

        await preferences.setStringList(key, currentIds.toList());
        result.complete(newItemCount);
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  static String _itemId(Map<String, dynamic> item) {
    final id = item['name'] ?? item['id'];
    if (id != null && id.toString().trim().isNotEmpty) return id.toString();

    final keys = item.keys.toList()..sort();
    return jsonEncode({for (final key in keys) key: item[key]});
  }
}
