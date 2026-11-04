import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../theme/brand_theme.dart';

/// Observe pointers without taking the WebView's scrolling/typing gestures.
/// Refresh only after a deliberate downward pull starting at the top of every
/// scrollable ancestor, including fixed HTML form containers.
class WebViewPullToRefresh extends StatefulWidget {
  const WebViewPullToRefresh({
    super.key,
    required this.controller,
    required this.onRefresh,
    required this.child,
    this.enabled = true,
  });

  final WebViewController? controller;
  final Future<void> Function() onRefresh;
  final Widget child;
  final bool enabled;

  @override
  State<WebViewPullToRefresh> createState() => _WebViewPullToRefreshState();
}

class _WebViewPullToRefreshState extends State<WebViewPullToRefresh> {
  static const _threshold = 90.0;
  final _pointers = <int>{};
  int _gesture = 0;
  Offset? _start;
  Offset _delta = Offset.zero;
  Future<bool>? _probe;
  bool _eligible = false;
  bool _refreshing = false;

  @override
  void didUpdateWidget(WebViewPullToRefresh oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || oldWidget.controller != widget.controller) {
      _cancel();
    }
  }

  void _cancel() {
    _gesture++;
    _start = null;
    _probe = null;
    _eligible = false;
    _delta = Offset.zero;
  }

  Future<bool> _atTop(Offset position, Size size) async {
    final controller = widget.controller;
    if (controller == null) return true; // Empty/error layout: allow retry.
    if (size.isEmpty) return false;
    try {
      final result = await controller
          .runJavaScriptReturningResult(
            webViewRefreshProbe(
              position.dx / size.width,
              position.dy / size.height,
            ),
          )
          .timeout(const Duration(seconds: 2));
      return result == true || result.toString() == 'true';
    } catch (_) {
      return false; // Never guess the scroll position if the page cannot answer.
    }
  }

  void _down(PointerDownEvent event, Size size) {
    _pointers.add(event.pointer);
    if (_pointers.length != 1 ||
        !widget.enabled ||
        _refreshing ||
        event.kind != PointerDeviceKind.touch) {
      setState(_cancel);
      return;
    }
    final gesture = ++_gesture;
    _start = event.localPosition;
    _delta = Offset.zero;
    _eligible = false;
    final probe = _probe = _atTop(event.localPosition, size);
    unawaited(
      probe.then((allowed) {
        if (mounted && gesture == _gesture && _start != null) {
          setState(() => _eligible = allowed);
        }
      }),
    );
  }

  void _move(PointerMoveEvent event) {
    if (_start == null || _pointers.length != 1 || !widget.enabled) return;
    setState(() => _delta = event.localPosition - _start!);
  }

  Future<void> _up(PointerUpEvent event) async {
    _pointers.remove(event.pointer);
    final probe = _probe;
    final delta = _delta;
    final gesture = _gesture;
    final controller = widget.controller;
    final ready =
        _start != null &&
        _pointers.isEmpty &&
        probe != null &&
        delta.dy >= _threshold &&
        delta.dx.abs() < delta.dy * 0.6;
    if (!ready) {
      setState(_cancel);
      return;
    }
    final allowed = await probe;
    if (!mounted || gesture != _gesture) return;
    setState(_cancel);
    if (!allowed ||
        !widget.enabled ||
        _refreshing ||
        controller != widget.controller) {
      return;
    }
    setState(() => _refreshing = true);
    try {
      FocusScope.of(context).unfocus();
      await widget.onRefresh();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('Could not refresh this page. Swipe down to retry.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder:
        (context, constraints) => Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) => _down(event, constraints.biggest),
          onPointerMove: _move,
          onPointerUp: (event) => unawaited(_up(event)),
          onPointerCancel: (event) {
            _pointers.remove(event.pointer);
            setState(_cancel);
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (_refreshing ||
                  (widget.enabled &&
                      _eligible &&
                      _delta.dy > 12 &&
                      _delta.dx.abs() < _delta.dy * 0.6))
                Positioned(
                  top: 12,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: Material(
                        elevation: 3,
                        color: Colors.white,
                        shape: const CircleBorder(),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: BrandColors.ink,
                              value:
                                  _refreshing
                                      ? null
                                      : (_delta.dy / _threshold).clamp(0, 1),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
  );
}

String webViewRefreshProbe(double x, double y) => """
(() => {
  if (document.readyState !== 'complete' ||
      document.querySelector('dialog[open], .modal.show, [aria-busy="true"]')) return false;
  let node = document.elementFromPoint(
    ${x.clamp(0, 1)} * window.innerWidth, ${y.clamp(0, 1)} * window.innerHeight);
  if (!node || node.closest('input, textarea, select, button, [contenteditable="true"], iframe, canvas, [role="slider"]')) return false;
  while (node) {
    if (node.scrollHeight > node.clientHeight + 1 &&
        /auto|scroll|overlay/.test(getComputedStyle(node).overflowY) && node.scrollTop > 1) return false;
    node = node.parentElement;
  }
  return (document.scrollingElement?.scrollTop || window.scrollY || 0) <= 1;
})();
""";
