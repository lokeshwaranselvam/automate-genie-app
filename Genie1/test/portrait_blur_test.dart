import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:homegenie/utils/face/portrait_blur_image.dart';
import 'package:homegenie/utils/face/portrait_blur_service.dart';
import 'package:homegenie/utils/face/portrait_blur_preview.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('background heads blur even inside the same connected person mask', () {
    final matte =
        buildPortraitMatte(
          PortraitMatteInput(
            100,
            100,
            List.filled(10000, 1),
            const PortraitFaceRegion(.3, .2, .75, .7),
            backgroundFaces: const [
              PortraitFaceRegion(.1, .3, .29, .6),
              PortraitFaceRegion(.01, .3, .08, .45),
            ],
          ),
        )!;
    int alpha(int x, int y) => matte[(y * 100 + x) * 4 + 3];
    expect(alpha(18, 40), 0);
    expect(alpha(28, 40), 0); // Also overlaps the main face's padded rectangle.
    expect(alpha(4, 35), 0);
    expect(alpha(18, 26), 0); // Hair above the detected background face.
    expect(alpha(18, 65), 0); // Background torso despite connected shoulders.
    expect(alpha(50, 40), 255);
    expect(alpha(50, 85), 255);
  });

  test(
    'matte preserves the main person and excludes a separate background person',
    () {
      final confidence = List<double>.filled(100, 0);
      for (var y = 1; y < 10; y++) {
        for (var x = 3; x < 6; x++) {
          confidence[y * 10 + x] = 1;
        }
        confidence[y * 10 + 9] = 1;
      }
      final matte =
          buildPortraitMatte(
            PortraitMatteInput(
              10,
              10,
              confidence,
              const PortraitFaceRegion(.3, .1, .5, .4),
            ),
          )!;
      expect(matte[(2 * 10 + 4) * 4 + 3], 255);
      expect(matte[(9 * 10 + 4) * 4 + 3], 255);
      expect(matte[(5 * 10 + 9) * 4 + 3], 0);
      expect(matte[(5 * 10) * 4 + 3], 0);
    },
  );

  test('matte protects the face even when local confidence is low', () {
    final confidence = List<double>.filled(100, 0);
    confidence[44] = 1;
    final matte =
        buildPortraitMatte(
          PortraitMatteInput(
            10,
            10,
            confidence,
            const PortraitFaceRegion(.3, .3, .6, .6),
          ),
        )!;
    expect(matte[(3 * 10 + 3) * 4 + 3], 255);
    expect(matte[(5 * 10 + 5) * 4 + 3], 255);
    expect(matte[(8 * 10 + 8) * 4 + 3], 0);
  });

  test(
    'missing or malformed segmentation cannot replace an accepted photo',
    () {
      expect(
        buildPortraitMatte(
          PortraitMatteInput(
            10,
            10,
            List.filled(100, 0),
            const PortraitFaceRegion(.3, .3, .6, .6),
          ),
        ),
        isNull,
      );
      expect(
        buildPortraitMatte(
          const PortraitMatteInput(
            10,
            10,
            [],
            PortraitFaceRegion(.3, .3, .6, .6),
          ),
        ),
        isNull,
      );
    },
  );

  test('strong background blur leaves opaque foreground pixels unchanged', () {
    final original = img.Image(width: 96, height: 96);
    final matte = Uint8List(96 * 96 * 4);
    for (final pixel in original) {
      final value = (pixel.x + pixel.y).isEven ? 255 : 0;
      pixel
        ..r = value
        ..g = 255 - value
        ..b = value;
      final offset = (pixel.y * 96 + pixel.x) * 4;
      matte[offset] = matte[offset + 1] = matte[offset + 2] = 255;
      matte[offset + 3] = pixel.x >= 32 && pixel.x < 64 ? 255 : 0;
    }
    final result =
        img.decodePng(
          compositePortraitImage(
            PortraitCompositeInput(
              Uint8List.fromList(img.encodePng(original)),
              matte,
              96,
              96,
            ),
          ),
        )!;
    for (var y = 0; y < 96; y++) {
      for (var x = 32; x < 64; x++) {
        final before = original.getPixel(x, y), after = result.getPixel(x, y);
        expect([after.r, after.g, after.b], [before.r, before.g, before.b]);
      }
    }
    expect(
      (result.getPixel(10, 40).r - result.getPixel(11, 40).r).abs(),
      lessThan(15),
    );
    expect(result.width, original.width);
    expect(result.height, original.height);
  });

  test(
    'portrait preparation preserves enrollment size and foreground colors',
    () {
      final original = img.Image(width: 1600, height: 800);
      img.fill(original, color: img.ColorRgb8(20, 80, 160));
      final result =
          img.decodePng(
            preparePortraitImage(Uint8List.fromList(img.encodePng(original))),
          )!;
      expect([result.width, result.height], [1280, 640]);
      expect(
        [
          result.getPixel(500, 300).r,
          result.getPixel(500, 300).g,
          result.getPixel(500, 300).b,
        ],
        [20, 80, 160],
      );
    },
  );

  const faceChannel = MethodChannel('google_mlkit_face_detector');
  const segmentationChannel = MethodChannel('google_mlkit_selfie_segmenter');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(faceChannel, null);
    messenger.setMockMethodCallHandler(segmentationChannel, null);
  });

  test(
    'unavailable cosmetic segmentation retains the original photo',
    () async {
      messenger.setMockMethodCallHandler(faceChannel, (call) async {
        if (call.method.contains('close')) return null;
        return [faceJson];
      });
      messenger.setMockMethodCallHandler(segmentationChannel, (_) async {
        throw PlatformException(code: 'unavailable');
      });
      await withPhoto((original) async {
        final service = PortraitBlurService();
        final detector = FaceDetector(options: FaceDetectorOptions());
        try {
          final result = await service.blurAcceptedPhoto(original, detector);
          expect(result.path, original.path);
          expect(await original.exists(), isTrue);
          expect(await original.parent.list().length, 1);
        } finally {
          await service.close();
          await detector.close();
        }
      });
    },
  );

  test(
    'accepted portrait output keeps original intact and creates no temp directory leak',
    () async {
      final preparedPaths = <String>[];
      messenger.setMockMethodCallHandler(faceChannel, (call) async {
        if (!call.method.contains('close')) {
          preparedPaths.add(
            ((call.arguments as Map)['imageData'] as Map)['path'] as String,
          );
        }
        return call.method.contains('close')
            ? null
            : [
              {
                'rect': {
                  'left': 0.0,
                  'top': 30.0,
                  'right': 17.0,
                  'bottom': 45.0,
                },
                'landmarks': <String, dynamic>{},
                'contours': <String, dynamic>{},
              },
              faceJson,
            ];
      });
      messenger.setMockMethodCallHandler(segmentationChannel, (call) async {
        if (call.method.contains('close')) return null;
        expect((call.arguments as Map)['isStream'], isFalse);
        return {
          'width': 10,
          'height': 10,
          'confidences': List<double>.filled(100, 1),
        };
      });
      await withPhoto((original) async {
        final service = PortraitBlurService();
        final detector = FaceDetector(options: FaceDetectorOptions());
        File? output;
        try {
          final originalBytes = await original.readAsBytes();
          output = await service.blurAcceptedPhoto(original, detector);
          expect(output.path, isNot(original.path));
          expect(output.parent.path, original.parent.path);
          expect(await original.readAsBytes(), originalBytes);
          expect(img.decodePng(await output.readAsBytes()), isNotNull);
          expect(await original.parent.list().length, 2);
          expect(preparedPaths, hasLength(1));
          expect(await File(preparedPaths.single).exists(), isFalse);
          expect(await File(preparedPaths.single).parent.exists(), isFalse);
        } finally {
          if (output != null && output.path != original.path) {
            await output.delete();
          }
          await service.close();
          await detector.close();
        }
      });
    },
  );

  for (final mirror in [false, true]) {
    testWidgets('preview keeps foreground sharp with mirror=$mirror', (
      tester,
    ) async {
      final pixels = Uint8List(10 * 10 * 4);
      for (var y = 0; y < 10; y++) {
        for (var x = 0; x < 5; x++) {
          final offset = (y * 10 + x) * 4;
          pixels[offset] =
              pixels[offset + 1] =
                  pixels[offset + 2] = pixels[offset + 3] = 255;
        }
      }
      final mask = await tester.runAsync(() async {
        final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
        final descriptor = ui.ImageDescriptor.raw(
          buffer,
          width: 10,
          height: 10,
          pixelFormat: ui.PixelFormat.rgba8888,
        );
        final codec = await descriptor.instantiateCodec();
        final frame = await codec.getNextFrame();
        codec.dispose();
        descriptor.dispose();
        buffer.dispose();
        return frame.image;
      });
      final notifier = ValueNotifier<ui.Image?>(mask);
      final key = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 100,
                height: 100,
                child: PortraitBlurPreview(
                  mask: notifier,
                  mirror: mirror,
                  child: CustomPaint(painter: _Stripes()),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final data = await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        } finally {
          image.dispose();
        }
      });
      int red(int x) => data!.getUint8((50 * 100 + x) * 4);
      final leftDetail = (red(16) - red(20)).abs();
      final rightDetail = (red(76) - red(80)).abs();
      expect(mirror ? rightDetail : leftDetail, greaterThan(240));
      expect(mirror ? leftDetail : rightDetail, lessThan(30));
      await tester.pumpWidget(const SizedBox.shrink());
      notifier.dispose();
      mask!.dispose();
    });
  }
}

class _Stripes extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    for (var x = 0.0; x < size.width; x += 4) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 4, size.height),
        Paint()..color = (x ~/ 4).isEven ? Colors.white : Colors.black,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

const faceJson = {
  'rect': {'left': 20.0, 'top': 20.0, 'right': 60.0, 'bottom': 60.0},
  'landmarks': <String, dynamic>{},
  'contours': <String, dynamic>{},
};

Future<void> withPhoto(Future<void> Function(File) check) async {
  final directory = await Directory.systemTemp.createTemp(
    'genie-portrait-test-',
  );
  final photo = await File(
    '${directory.path}/raw.jpg',
  ).writeAsBytes(img.encodeJpg(img.Image(width: 80, height: 80)));
  try {
    await check(photo);
  } finally {
    await photo.delete();
    await directory.delete();
  }
}
