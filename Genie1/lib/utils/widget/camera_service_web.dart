import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../platform/app_navigation.dart';
import '../platform/platform_file_web.dart';
import '../theme/brand_theme.dart';
import 'ag_path_loading_indicator.dart';

class CameraService {
  static Future<File?> capturePhoto({bool front = false}) async =>
      appNavigatorKey.currentState?.push<File>(
        MaterialPageRoute(builder: (_) => _BrowserCamera(front: front)),
      );
}

class _BrowserCamera extends StatefulWidget {
  const _BrowserCamera({required this.front});
  final bool front;
  @override
  State<_BrowserCamera> createState() => _BrowserCameraState();
}

class _BrowserCameraState extends State<_BrowserCamera>
    with WidgetsBindingObserver {
  CameraController? _camera;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    CameraController? controller;
    try {
      final cameras = await availableCameras();
      final direction =
          widget.front ? CameraLensDirection.front : CameraLensDirection.back;
      if (cameras.isEmpty) throw StateError('No camera is available.');
      controller = CameraController(
        cameras.firstWhere(
          (c) => c.lensDirection == direction,
          orElse: () => cameras.first,
        ),
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _camera = controller);
    } catch (error) {
      await controller?.dispose();
      if (mounted)
        setState(
          () =>
              _error =
                  'Could not open the camera. Allow camera access in your browser and try again.',
        );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      final camera = _camera;
      _camera = null;
      camera?.dispose();
      if (mounted)
        setState(
          () => _error = 'Camera paused. Reopen it to take a new photo.',
        );
    }
  }

  Future<void> _capture() async {
    final camera = _camera;
    if (_busy || camera == null || !camera.value.isInitialized) return;
    setState(() => _busy = true);
    try {
      final photo = await camera.takePicture();
      final file = File.fromBytes(
        await photo.readAsBytes(),
        name: 'capture.jpg',
      );
      if (mounted) Navigator.of(context).pop(file);
    } catch (_) {
      if (mounted)
        setState(() {
          _busy = false;
          _error = 'Could not capture the photo. Please reopen the camera.';
        });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camera?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: brandAppBar(title: const Text('Take photo')),
    body:
        _error != null
            ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
            : _camera == null
            ? const Center(child: AgPathLoadingIndicator())
            : Column(
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: _camera!.value.aspectRatio,
                      child: CameraPreview(_camera!),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _capture,
                    icon: const Icon(Icons.camera_alt),
                    label: Text(_busy ? 'Capturing...' : 'Take photo'),
                  ),
                ),
              ],
            ),
  );
}
