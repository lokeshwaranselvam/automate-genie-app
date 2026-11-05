import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
import '../utils/platform/platform_file_web.dart';
import '../utils/theme/brand_theme.dart';
import '../utils/face/browser_face_runtime.dart';
import '../utils/face/face_blink_controller.dart';
import '../utils/face/face_embedding_service_web.dart';

class FaceCapturePage extends StatefulWidget {
  const FaceCapturePage({
    super.key,
    required this.title,
    this.validateCapture,
    this.validatePhotoInCallback = false,
  });
  final String title;
  final Future<String?> Function(File)? validateCapture;
  final bool validatePhotoInCallback;
  @override
  State<FaceCapturePage> createState() => _FaceCapturePageState();
}

class _FaceCapturePageState extends State<FaceCapturePage>
    with WidgetsBindingObserver {
  final _blink = FaceBlinkController(config: const FaceBlinkConfig.browser());
  final _clock = Stopwatch();
  web.HTMLVideoElement? _video;
  Timer? _timer;
  late final JSFunction _visibility;
  int _generation = 0;
  bool _busy = true, _sampling = false, _capturing = false;
  String _instruction = 'Preparing your camera and face toolsâ€¦';
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _visibility =
        ((web.Event _) {
          if (web.document.hidden) _pause();
        }).toJS;
    web.document.addEventListener('visibilitychange', _visibility);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _pause();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    final video = _video;
    if (video != null) BrowserFaceRuntime.stop(video);
  }

  void _pause() {
    _generation++;
    _stop();
    if (mounted) {
      setState(() {
        _busy = false;
        _capturing = false;
        _error = 'Camera paused. Return to this page and tap Retry.';
      });
    }
  }

  Future<void> _start() async {
    if (_video == null || web.document.hidden) return;
    final generation = ++_generation;
    _stop();
    setState(() {
      _busy = true;
      _error = null;
      _capturing = false;
      _instruction = 'Preparing your camera and face tools';
    });
    try {
      // Load the model before requesting frames: no blink is accepted while loading.
      await FaceEmbeddingService.instance.warmUp();
      if (!mounted || generation != _generation) return;
      await BrowserFaceRuntime.start(_video!);
      if (!mounted || generation != _generation) return;
      _clock.reset();
      _clock.start();
      _blink.reset(Duration.zero);
      setState(() {
        _busy = false;
        _instruction = _blink.progress.instruction;
      });
      _timer = Timer.periodic(
        const Duration(milliseconds: 80),
        (_) => _sample(generation),
      );
    } catch (error) {
      if (mounted && generation == _generation) _fail(error);
    }
  }

  void _fail(Object error) {
    _stop();
    final raw = error.toString();
    final message =
        raw.contains('NotAllowed') || raw.contains('Permission')
            ? 'Camera access was denied. Allow camera access in Chrome site settings, then tap Retry.'
            : raw.contains('NotFound')
            ? 'No camera was found. Connect a camera and retry.'
            : raw.contains('NotReadable')
            ? 'The camera is busy. Close other apps using it and retry.'
            : raw;
    setState(() {
      _busy = false;
      _capturing = false;
      _error = message;
    });
  }

  Future<void> _sample(int generation) async {
    if (_sampling || _capturing || !mounted || generation != _generation) {
      return;
    }
    if (_blink.tick(_clock.elapsed).needsRetry) {
      _fail(StateError(_blink.progress.instruction));
      return;
    }
    _sampling = true;
    try {
      final face = await BrowserFaceRuntime.sample(_video!);
      if (!mounted || generation != _generation) return;
      double? value(String key) => (face[key] as num?)?.toDouble();
      final progress = _blink.observe(
        FaceBlinkSample(
          faceCount: (face['faceCount'] as num).toInt(),
          leftEyeOpen: value('leftEyeOpen'),
          rightEyeOpen: value('rightEyeOpen'),
          yaw: value('yaw'),
          pitch: value('pitch'),
          faceFraction: value('faceFraction') ?? 0,
          centerOffset: value('centerOffset') ?? 1,
          brightness: value('brightness') ?? 0,
          trackingId: (face['trackingId'] as num?)?.toInt(),
        ),
        _clock.elapsed,
      );
      setState(() => _instruction = progress.instruction);
      if (progress.canCapture) await _capture(generation);
    } catch (error) {
      if (mounted && generation == _generation) _fail(error);
    } finally {
      _sampling = false;
    }
  }

  Future<void> _capture(int generation) async {
    _capturing = true;
    setState(() {
      _busy = true;
      _instruction = 'Checking your selfie...';
    });
    File? photo;
    var accepted = false;
    try {
      photo = File.fromBytes(
        BrowserFaceRuntime.snapshot(_video!),
        name: 'attendance-selfie.jpg',
      );
      _stop();
      if (!widget.validatePhotoInCallback || widget.validateCapture == null) {
        await FaceEmbeddingService.instance.embeddingFromCapture(photo);
      }
      final rejection = await widget.validateCapture?.call(photo);
      if (!mounted || generation != _generation) return;
      if (rejection != null) throw StateError(rejection);
      accepted = true;
      Navigator.of(context).pop(photo);
    } finally {
      if (!accepted && photo != null) await photo.delete();
    }
  }

  @override
  void dispose() {
    _generation++;
    _stop();
    _clock.stop();
    web.document.removeEventListener('visibilitychange', _visibility);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: brandAppBar(title: Text(widget.title)),
    body: SafeArea(
      child: LayoutBuilder(
        builder:
            (context, constraints) => Center(
              child: SizedBox(
                width: math.min(640, constraints.maxWidth),
                child: Column(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ColoredBox(
                                color: Colors.black,
                                child: HtmlElementView.fromTagName(
                                  tagName: 'video',
                                  onElementCreated: (element) {
                                    final video =
                                        element as web.HTMLVideoElement;
                                    video
                                      ..autoplay = true
                                      ..muted = true
                                      ..playsInline = true;
                                    video.style
                                      ..width = '100%'
                                      ..height = '100%'
                                      ..objectFit = 'contain'
                                      ..transform = 'scaleX(-1)';
                                    _video = video;
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                          if (mounted) _start();
                                        });
                                  },
                                ),
                              ),
                              IgnorePointer(
                                child: Center(
                                  child: FractionallySizedBox(
                                    widthFactor: .65,
                                    heightFactor: .85,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: Colors.white70,
                                          width: 2,
                                        ),
                                        borderRadius: const BorderRadius.all(
                                          Radius.elliptical(180, 240),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      child: Text(
                        _error ?? _instruction,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 17,
                          color: _error == null ? null : Colors.red.shade700,
                        ),
                      ),
                    ),
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(),
                      ),
                    if (_error != null)
                      FilledButton.icon(
                        onPressed: _busy ? null : _start,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(24, 8, 24, 20),
                      child: Text(
                        'Face the camera in good light. Keep both eyes visible and blink when asked.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ),
    ),
  );
}
