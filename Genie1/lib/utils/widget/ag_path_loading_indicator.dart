import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// An indeterminate loader. It never controls how long a request stays loading.
class AgPathLoadingIndicator extends StatefulWidget {
  const AgPathLoadingIndicator({
    super.key,
    this.size = 120,
    this.showBackground = false,
    this.animationDuration = const Duration(milliseconds: 3000),
  }) : assert(size > 0);

  final double size;
  final bool showBackground;
  final Duration animationDuration;

  @override
  State<AgPathLoadingIndicator> createState() => _AgPathLoadingIndicatorState();
}

class _AgPathLoadingIndicatorState extends State<AgPathLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.animationDuration,
  );
  bool _animate = false;

  @override
  void initState() {
    super.initState();
    assert(widget.animationDuration > Duration.zero);
  }

  void _syncAnimation() {
    final media = MediaQuery.maybeOf(context);
    _animate =
        TickerMode.valuesOf(context).enabled &&
        !(media?.disableAnimations ?? false) &&
        !(media?.accessibleNavigation ?? false);
    if (_animate && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!_animate) {
      _controller.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(AgPathLoadingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(widget.animationDuration > Duration.zero);
    if (oldWidget.animationDuration != widget.animationDuration) {
      _controller.duration = widget.animationDuration;
      if (_controller.isAnimating) {
        _controller.repeat();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading',
    container: true,
    child: RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color:
                widget.showBackground
                    ? Theme.of(context).colorScheme.surface
                    : null,
            borderRadius: BorderRadius.circular(widget.size * .16),
          ),
          child: CustomPaint(
            painter: _AgPainter(progress: _controller, animate: _animate),
          ),
        ),
      ),
    ),
  );
}

/// Normalized vector geometry traced from the supplied AG symbol reference.
/// The A terminates on the lower-left G arc; its base and G bar stay separate.
class _AgGeometry {
  static const bounds = Size(370, 210);
  static final g =
      Path()
        ..moveTo(352, 100)
        ..arcTo(
          const Rect.fromLTWH(174, 14, 178, 172),
          0,
          math.pi * 1.77,
          false,
        );
  static final a =
      Path()
        ..moveTo(185, 141)
        ..lineTo(117, 35)
        ..cubicTo(109, 21, 98, 21, 91, 34)
        ..lineTo(17, 164)
        ..cubicTo(9, 178, 9, 186, 28, 186)
        ..lineTo(149, 186);
  static final bar =
      Path()
        ..moveTo(270, 100)
        ..lineTo(352, 100);
  static final ui.PathMetric _gMetric = g.computeMetrics().single;
  static final Offset _gEnd =
      _gMetric.getTangentForOffset(_gMetric.length)!.position;
  static final sequence = <_AgLeg>[
    _AgLeg(g),
    // These transfer paths move a faded particle only; they are never stroked.
    _AgLeg(
      Path()
        ..moveTo(_gEnd.dx, _gEnd.dy)
        ..cubicTo(280, 12, 185, 75, 185, 141),
      transfer: true,
    ),
    _AgLeg(a),
    _AgLeg(
      Path()
        ..moveTo(149, 186)
        ..cubicTo(198, 186, 224, 100, 270, 100),
      transfer: true,
    ),
    _AgLeg(bar),
  ];
  static final double length = sequence.fold(
    0,
    (total, leg) => total + leg.durationWeight,
  );
  static final logoPaint =
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 15
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = const LinearGradient(
          colors: [
            Color(0xFF0055FF),
            Color(0xFF442FEF),
            Color(0xFF660AEF),
            Color(0xFF8000E5),
          ],
        ).createShader(const Rect.fromLTWH(10, 14, 342, 172));
}

class _AgLeg {
  _AgLeg(Path path, {this.transfer = false})
    : metric = path.computeMetrics().single;
  final ui.PathMetric metric;
  final bool transfer;
  double get durationWeight => transfer ? 50 : metric.length;
}

class _AgPainter extends CustomPainter {
  _AgPainter({required this.progress, required this.animate})
    : super(repaint: progress);
  final Animation<double> progress;
  final bool animate;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(
      size.width / _AgGeometry.bounds.width,
      size.height / _AgGeometry.bounds.height,
    );
    canvas.save();
    canvas.translate(
      (size.width - _AgGeometry.bounds.width * scale) / 2,
      (size.height - _AgGeometry.bounds.height * scale) / 2,
    );
    canvas.scale(scale);
    for (final path in [_AgGeometry.a, _AgGeometry.g, _AgGeometry.bar]) {
      canvas.drawPath(path, _AgGeometry.logoPaint);
    }
    if (animate) _paintParticle(canvas);
    canvas.restore();
  }

  void _paintParticle(Canvas canvas) {
    var distance = progress.value * _AgGeometry.length;
    var leg = _AgGeometry.sequence.last;
    for (final candidate in _AgGeometry.sequence) {
      leg = candidate;
      if (distance <= leg.durationWeight) break;
      distance -= leg.durationWeight;
    }
    final fraction = (distance / leg.durationWeight).clamp(0.0, 1.0);
    final offset = fraction * leg.metric.length;
    final tangent = leg.metric.getTangentForOffset(offset);
    if (tangent == null) return;
    // Fade across actual gaps without drawing a connector or dragging a trail.
    final opacity =
        leg.transfer ? ((fraction - .5).abs() * 2).clamp(0.0, 1.0) : 1.0;
    if (!leg.transfer) {
      for (var i = 4; i > 0; i--) {
        final from = math.max(0.0, offset - i * 9);
        canvas.drawPath(
          leg.metric.extractPath(from, offset),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeWidth = 11 + i * 2
            ..color = Color.lerp(
              const Color(0xFF38DAFF),
              const Color(0xFFFF28DB),
              fraction,
            )!.withValues(alpha: .045),
        );
      }
    }
    final point = tangent.position;
    final pulse = .9 + .1 * math.sin(progress.value * math.pi * 4);
    canvas.drawCircle(
      point,
      13 * pulse,
      Paint()
        ..color = const Color(0xFFFF22DF).withValues(alpha: .38 * opacity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawCircle(
      point,
      9,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-.25, -.3),
          colors: [
            Colors.white.withValues(alpha: opacity),
            const Color(0xFF7DF3FF).withValues(alpha: opacity),
            const Color(0xFFA963FF).withValues(alpha: opacity),
            const Color(0xFFFF1ADF).withValues(alpha: opacity),
          ],
          stops: const [0, .25, .55, 1],
        ).createShader(Rect.fromCircle(center: point, radius: 9)),
    );
  }

  @override
  bool shouldRepaint(_AgPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.animate != animate;
}
