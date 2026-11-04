import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

@JS('genieFace')
external _FaceBridge get _bridge;
@JS('genieFace')
external JSAny? get _installedBridge;
extension type _FaceBridge(JSObject _) implements JSObject {
  external JSPromise<JSAny?> warmup();
  external JSPromise<JSAny?> start(web.HTMLVideoElement video);
  external void stop(web.HTMLVideoElement video);
  external void release();
  external JSPromise<JSString> sample(web.HTMLVideoElement video);
  external JSString snapshot(web.HTMLVideoElement video);
  external JSPromise<JSString> detect(JSUint8Array bytes);
  external JSPromise<JSArray<JSNumber>> embed(JSFloat32Array tensor);
}

/// Camera images and tensors stay in memory and are never persisted here.
class BrowserFaceRuntime {
  static Future<void>? _loading;
  static bool _loaded = false;
  static Future<void> load() => _loading ??= _load();
  static Future<void> _load() async {
    if (_installedBridge != null) {
      _loaded = true;
      return;
    }
    final script =
        web.HTMLScriptElement()
          ..src =
              Uri.parse(
                web.document.baseURI,
              ).resolve('face/face_bridge.js').toString();
    final ready = Completer<void>();
    script.onload =
        ((web.Event _) {
          if (!ready.isCompleted) ready.complete();
        }).toJS;
    script.onerror =
        ((web.Event _) {
          if (!ready.isCompleted) {
            ready.completeError(
              StateError(
                'Could not load browser face tools. Check your connection and retry.',
              ),
            );
          }
        }).toJS;
    web.document.head!.append(script);
    try {
      await ready.future.timeout(const Duration(seconds: 30));
      _loaded = true;
    } catch (_) {
      script.remove();
      _loading = null;
      rethrow;
    }
  }

  static Future<void> warmUp() async {
    await load();
    await _bridge.warmup().toDart;
  }

  static Future<void> start(web.HTMLVideoElement video) async {
    await load();
    await _bridge.start(video).toDart;
  }

  static void stop(web.HTMLVideoElement video) {
    if (_loaded) _bridge.stop(video);
  }

  static void clear() {
    if (_loaded) _bridge.release();
  }

  static Future<Map<String, dynamic>> sample(
    web.HTMLVideoElement video,
  ) async =>
      jsonDecode((await _bridge.sample(video).toDart).toDart)
          as Map<String, dynamic>;
  static Uint8List snapshot(web.HTMLVideoElement video) =>
      base64Decode(_bridge.snapshot(video).toDart);
  static Future<Map<String, dynamic>> detect(Uint8List bytes) async {
    await load();
    return jsonDecode((await _bridge.detect(bytes.toJS).toDart).toDart)
        as Map<String, dynamic>;
  }

  static Future<List<double>> embed(Float32List tensor) async =>
      (await _bridge.embed(tensor.toJS).toDart).toDart
          .map((v) => v.toDartDouble)
          .toList();
}
