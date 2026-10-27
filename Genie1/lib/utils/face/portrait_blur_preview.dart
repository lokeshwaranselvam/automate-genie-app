import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Draws the same camera texture twice; detection still receives raw frames.
class PortraitBlurPreview extends StatelessWidget {
  const PortraitBlurPreview({
    super.key,
    required this.mask,
    required this.child,
    this.mirror = true,
  });
  final ValueListenable<ui.Image?> mask;
  final Widget child;
  final bool mirror;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ui.Image?>(
    valueListenable: mask,
    builder:
        (context, image, _) =>
            image == null
                ? child
                : ClipRect(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: 24,
                          sigmaY: 24,
                        ),
                        child: child,
                      ),
                      ShaderMask(
                        blendMode: ui.BlendMode.dstIn,
                        shaderCallback:
                            (bounds) => ui.ImageShader(
                              image,
                              ui.TileMode.clamp,
                              ui.TileMode.clamp,
                              Float64List.fromList([
                                (mirror ? -1 : 1) * bounds.width / image.width,
                                0,
                                0,
                                0,
                                0,
                                bounds.height / image.height,
                                0,
                                0,
                                0,
                                0,
                                1,
                                0,
                                mirror ? bounds.width : 0,
                                0,
                                0,
                                1,
                              ]),
                              filterQuality: ui.FilterQuality.high,
                            ),
                        child: child,
                      ),
                    ],
                  ),
                ),
  );
}
