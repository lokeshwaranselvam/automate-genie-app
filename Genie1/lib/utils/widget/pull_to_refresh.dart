import 'package:flutter/material.dart';

import '../theme/brand_theme.dart';

/// Pull-to-refresh for lists, forms, and bounded empty/error layouts.
/// Nested vertical lists remain scrollable; short content can still be pulled.
class PullToRefresh extends StatefulWidget {
  const PullToRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.color = BrandColors.ink,
    this.backgroundColor,
    this.enabled = true,
  });

  final Future<void> Function() onRefresh;
  final Widget child;
  final Color color;
  final Color? backgroundColor;
  final bool enabled;

  @override
  State<PullToRefresh> createState() => _PullToRefreshState();
}

class _PullToRefreshState extends State<PullToRefresh> {
  bool _refreshing = false;

  Future<void> _refresh() async {
    if (_refreshing || !widget.enabled) return;
    _refreshing = true;
    try {
      await widget.onRefresh();
    } finally {
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(
      physics: const AlwaysScrollableScrollPhysics(
        parent: ClampingScrollPhysics(),
      ),
    ),
    child: RefreshIndicator(
      color: widget.color,
      backgroundColor: widget.backgroundColor,
      onRefresh: _refresh,
      notificationPredicate:
          (notification) => notification.metrics.axis == Axis.vertical,
      child:
          widget.child is ScrollView
              ? widget.child
              : CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: ClampingScrollPhysics(),
                ),
                slivers: [
                  SliverFillRemaining(hasScrollBody: true, child: widget.child),
                ],
              ),
    ),
  );
}
