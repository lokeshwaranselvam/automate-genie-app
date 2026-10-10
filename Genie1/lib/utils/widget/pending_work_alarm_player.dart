import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Plays the pending-work alarm for five seconds, matching the TODO alarm
/// behavior in my_flutter_app. The bundled sound is used when no URL is sent.
class PendingWorkAlarmPlayer {
  PendingWorkAlarmPlayer._();

  static const Duration _playDuration = Duration(seconds: 5);
  static const String _fallbackAsset = 'assets/audio/work_assigned.mp3';

  static AudioPlayer? _player;
  static Timer? _stopTimer;
  static Future<void> _playQueue = Future<void>.value();

  static Future<void> play({String? url}) {
    _playQueue = _playQueue.then((_) => _playOnce(url)).catchError((
      Object error,
    ) {
      debugPrint('Pending-work alarm queue failed: $error');
    });
    return _playQueue;
  }

  static Future<void> _playOnce(String? url) async {
    await _stop();

    final player = AudioPlayer();
    _player = player;

    try {
      if (url != null && url.trim().isNotEmpty) {
        try {
          await player.setUrl(url.trim()).timeout(const Duration(seconds: 10));
        } catch (error) {
          debugPrint(
            'Pending-work alarm URL failed; using bundled sound: $error',
          );
          await player.setAsset(_fallbackAsset);
        }
      } else {
        await player.setAsset(_fallbackAsset);
      }

      final stopped = Completer<void>();
      _stopTimer = Timer(_playDuration, () {
        unawaited(
          _stop().whenComplete(() {
            if (!stopped.isCompleted) stopped.complete();
          }),
        );
      });
      unawaited(
        player.play().catchError((Object error) {
          debugPrint('Pending-work alarm playback failed: $error');
        }),
      );
      await stopped.future;
    } catch (error) {
      debugPrint('Pending-work alarm could not start: $error');
      await _stop();
    }
  }

  static Future<void> _stop() async {
    _stopTimer?.cancel();
    _stopTimer = null;

    final player = _player;
    _player = null;
    if (player == null) return;

    try {
      await player.stop();
    } catch (_) {}
    await player.dispose();
  }
}
