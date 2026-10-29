import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';

class AudioRecordingService {
  static final AudioRecordingService _instance = AudioRecordingService._internal();
  factory AudioRecordingService() => _instance;
  AudioRecordingService._internal();

  final String recorderId = 'default';
  final record = RecordPlatform.instance;

  bool isRecording = false;
  bool isPaused = false;
  String? lastRecordingPath;
  final List<String> _recordingPaths = [];
  final TimerService timerService = TimerService();

  bool _isStarting = false;

  Future<void> startRecording() async {
    // Already recording (or a start is in flight): starting again would
    // re-create the recorder and orphan the current recording.
    if (isRecording || _isStarting) return;
    _isStarting = true;
    try {
      await record.create(recorderId);
      const config = RecordConfig(encoder: AudioEncoder.aacLc);

      // getExternalStorageDirectory() is unsupported on iOS and can return
      // null on Android; fall back to the app documents directory.
      Directory? dir;
      if (Platform.isAndroid) {
        dir = await getExternalStorageDirectory();
      }
      dir ??= await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final path = '${dir.path}/recording_$timestamp.m4a';

      await record.start(recorderId, config, path: path);

      isRecording = true;
      isPaused = false;
      lastRecordingPath = path;
      _recordingPaths.add(path);

      timerService.startTimer();
      const platform = MethodChannel('com.example.audioapp/record');
      if (Platform.isAndroid) {
        await platform.invokeMethod('startService');
      }
    } finally {
      _isStarting = false;
    }
  }

  Future<void> pauseRecording() async {
    await record.pause(recorderId);
    isPaused = true;
    print("🔴 Recording paused");
    timerService.pauseTimer();
  }

  Future<void> resumeRecording() async {
    await record.resume(recorderId);
    isPaused = false;
    print("🟢 Recording resumed");

    timerService.resumeTimer();
  }

  Future<void> stopRecording() async {
    await record.stop(recorderId);
    await record.dispose(recorderId);
    isRecording = false;
    isPaused = false;

    const platform = MethodChannel('com.example.audioapp/record');
    if (Platform.isAndroid) {
      await platform.invokeMethod('stopService');
    }
    timerService.stopTimer();
  }

  List<String> getAllRecordingPaths() => _recordingPaths;

  void resetRecordings() {
    lastRecordingPath = null;
    isRecording = false;
    isPaused = false;
    _recordingPaths.clear();
  }

  bool get isRecordingActive => isRecording && !isPaused;
}



class TimerService {
  final _timerController = StreamController<Duration>.broadcast();
  Timer? _timer;
  Duration _currentDuration = Duration.zero;
  Duration _pausedDuration = Duration.zero;

  Stream<Duration> get timerStream => _timerController.stream;

  void startTimer() {
    _pausedDuration = Duration.zero;
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: 1), (timer) {
      _currentDuration = Duration(seconds: timer.tick) + _pausedDuration;
      _timerController.add(_currentDuration);
    });
  }

  void resumeTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: 1), (timer) {
      _currentDuration = Duration(seconds: timer.tick) + _pausedDuration;
      _timerController.add(_currentDuration);
    });
  }

  void pauseTimer() {
    _timer?.cancel();
    _pausedDuration = _currentDuration;
  }

  void stopTimer() {
    _timer?.cancel();
    _currentDuration = Duration.zero;
    _pausedDuration = Duration.zero;
    _timerController.add(_currentDuration);
  }

  void dispose() {
    _timer?.cancel();
    _timerController.close();
  }
}