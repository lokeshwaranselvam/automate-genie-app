import '../utils/widget/pull_to_refresh.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../utils/api/performance_api.dart';
import 'session_webview.dart';
import '../utils/connection_notice.dart';
import '../utils/widget/warning.dart';

const _blue = BrandColors.ink;
const _ink = Color(0xFF202936);
const _muted = Color(0xFF738093);
const _leadColor = BrandColors.ink;
const _conversionColor = Color(0xFF25BA9A);

class MyPerformancePage extends StatefulWidget {
  const MyPerformancePage({
    super.key,
    this.load,
    this.initialMonth,
    this.onNavigate,
    this.canViewSales,
  });

  final Future<PerformanceData> Function(DateTime)? load;
  final DateTime? initialMonth;
  final ValueChanged<int>? onNavigate;
  final Future<bool> Function()? canViewSales;

  @override
  State<MyPerformancePage> createState() => _MyPerformancePageState();
}

class _MyPerformancePageState extends State<MyPerformancePage>
    with TickerProviderStateMixin {
  late TabController _tabs;
  bool _checkingAccess = true;
  bool _canViewSales = false;
  late DateTime _month;
  PerformanceData? _data;
  bool _loading = true;
  bool _monthly = false;
  bool _attendanceOpened = false;
  String? _error;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    final now = widget.initialMonth ?? DateTime.now();
    _month = DateTime(now.year, now.month);
    _tabs = TabController(length: 1, vsync: this)..addListener(_tabChanged);
    _checkSalesAccess();
  }

  Future<void> _checkSalesAccess() async {
    var allowed = false;
    try {
      allowed =
          await (widget.canViewSales ?? PerformanceApi.instance.canViewSales)();
    } catch (error) {
      debugPrint('Could not verify sales performance access: $error');
    }
    if (!mounted) return;
    setState(() {
      _canViewSales = allowed;
      _checkingAccess = false;
      _attendanceOpened = !allowed;
      if (allowed) {
        _tabs.dispose();
        _tabs = TabController(length: 2, vsync: this)..addListener(_tabChanged);
      }
    });
    if (allowed) await _load();
  }

  void _tabChanged() {
    if (mounted) {
      setState(() {
        if (!_canViewSales || _tabs.index == 1) _attendanceOpened = true;
      });
    }
  }

  @override
  void dispose() {
    _request++;
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
      _data = null;
    });
    try {
      final data = await (widget.load ?? PerformanceApi.instance.load)(_month);
      if (!mounted || request != _request) return;
      setState(() => _data = data);
    } catch (error) {
      if (!mounted || request != _request) return;
      final connection = ConnectionNotice.fromError(error);
      setState(
        () =>
            _error =
                connection?.message ??
                error.toString().replaceFirst(
                  RegExp(r'^(Bad state: |FormatException: )'),
                  '',
                ),
      );
      if (connection != null) {
        Warning.show(
          context,
          error.toString(),
          'Error',
          actionLabel: 'Try again',
          onAction: _load,
        );
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  void _moveMonth(int delta) {
    final next = DateTime(_month.year, _month.month + delta);
    if (next.year < 1900 || next.year > 2100) return;
    setState(() => _month = next);
    _load();
  }

  Future<void> _chooseMonth() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _month,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100, 12, 31),
      helpText: 'Choose performance month',
    );
    if (!mounted || date == null) return;
    setState(() => _month = DateTime(date.year, date.month));
    await _load();
  }

  ({
    String title,
    String first,
    String second,
    String firstLabel,
    String secondLabel,
    List<(String, String)> metrics,
    String definition,
  })
  get _section => (
    title: 'Leads vs Conversions',
    first: 'leads',
    second: 'conversions',
    firstLabel: 'Leads',
    secondLabel: 'Conversions',
    metrics: const [
      ('Leads Created', 'leads'),
      ('Site Visits', 'site_visits'),
    ],
    definition:
        'Leads Created counts records whose Lead Owner is your user, matching My Leads, grouped by creation date. Conversions counts those same leads currently marked Converted, grouped by lead creation date. Site Visits counts actual event visits for your Employee.',
  );

  void _showDefinitions() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder:
          (context) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _section.title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(_section.definition),
                  const SizedBox(height: 12),
                  const Text(
                    'Percentages compare full calendar months. W1: days 1–7; W2: 8–14; W3: 15–21; W4: 22–month end. A dash means the ERP data is unavailable. No targets have been configured in this API.',
                    style: TextStyle(color: _muted, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F7FC),
      appBar: brandAppBar(
        elevation: 0,
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: const Text(
          'My Performance',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        actions: [
          if (_canViewSales)
            IconButton(
              tooltip: 'Find month',
              onPressed: _chooseMonth,
              icon: const Icon(Icons.search_rounded, color: Colors.white),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(46),
          child: Container(
            decoration: const BoxDecoration(gradient: BrandColors.gradient),
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(14),
              ),
              child: TabBar(
                controller: _tabs,
                indicatorSize: TabBarIndicatorSize.tab,
                indicator: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                dividerColor: Colors.transparent,
                labelColor: _blue,
                unselectedLabelColor: Colors.white,
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
                tabs: [
                  if (_canViewSales)
                    const Tab(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.bar_chart_rounded, size: 20),
                          SizedBox(width: 8),
                          Flexible(child: Text('Sales')),
                        ],
                      ),
                    ),
                  const Tab(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.calendar_month_outlined, size: 18),
                        SizedBox(width: 8),
                        Flexible(child: Text('Attendance')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body:
          _checkingAccess
              ? const Center(child: AgPathLoadingIndicator())
              : IndexedStack(
                index: _tabs.index,
                children: [
                  if (_canViewSales) _salesBody(),
                  if (_attendanceOpened)
                    const SessionWebView(
                      url: 'https://erp.homegeniegroup.in/GOAD',
                      title: 'Attendance',
                      embedded: true,
                      blockSystemBack: false,
                    )
                  else
                    const SizedBox.shrink(),
                ],
              ),
      bottomNavigationBar:
          widget.onNavigate == null
              ? null
              : brandBottomNavigationBar(
                currentIndex: 4,
                onTap: widget.onNavigate,
                type: BottomNavigationBarType.fixed,
                selectedFontSize: 10,
                unselectedFontSize: 10,
                showUnselectedLabels: true,
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(Icons.home_outlined),
                    label: 'Home',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.assignment_outlined),
                    label: 'Tasks',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.location_on_outlined),
                    label: 'Visits',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.people_outline_rounded),
                    label: 'Leads',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.more_horiz_rounded),
                    label: 'More',
                  ),
                ],
              ),
    );
  }

  Widget _salesBody() => Column(
    children: [
      Container(
        margin: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F9FC),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Previous month',
              onPressed: () => _moveMonth(-1),
              icon: const Icon(
                Icons.chevron_left_rounded,
                size: 22,
                color: _muted,
              ),
            ),
            Expanded(
              child: TextButton(
                onPressed: _chooseMonth,
                child: Text(
                  DateFormat('MMM yyyy').format(_month),
                  style: const TextStyle(
                    color: Color(0xFF465367),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Next month',
              onPressed: () => _moveMonth(1),
              icon: const Icon(
                Icons.chevron_right_rounded,
                size: 22,
                color: _muted,
              ),
            ),
          ],
        ),
      ),
      Expanded(
        child:
            _loading
                ? const Center(child: AgPathLoadingIndicator())
                : _error != null
                ? _errorBody()
                : _dashboard(),
      ),
    ],
  );

  Widget _errorBody() => PullToRefresh(
    onRefresh: _load,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 42, color: _muted),
            const SizedBox(height: 14),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _muted),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _dashboard() {
    final data = _data!;
    final section = _section;
    final values = data.sales;
    final rows = _monthly ? data.trend : data.weekly;
    final points =
        rows
            .map(
              (row) => PerformanceChartPoint(
                label:
                    _monthly
                        ? DateFormat(
                          'MMM',
                        ).format(DateTime.parse('${row['month']}-01'))
                        : row['label'].toString(),
                first: PerformanceData.count(row[section.first]),
                second: PerformanceData.count(row[section.second]),
              ),
            )
            .toList();
    return PullToRefresh(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final width =
                  constraints.maxWidth < 330 &&
                          MediaQuery.textScalerOf(context).scale(12) > 15
                      ? constraints.maxWidth
                      : (constraints.maxWidth - 10) / 2;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final metric in section.metrics)
                    SizedBox(
                      width: width,
                      child: _MetricCard(
                        label: metric.$1,
                        index: section.metrics.indexOf(metric),
                        series:
                            data.weekly
                                .map(
                                  (row) =>
                                      PerformanceData.count(row[metric.$2]),
                                )
                                .toList(),
                        value: PerformanceData.count(values[metric.$2]),
                        previous: PerformanceData.count(
                          data.previous[metric.$2],
                        ),
                        comparisonMonth: DateFormat(
                          'MMM yyyy',
                        ).format(DateTime(_month.year, _month.month - 1)),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        section.title,
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'How these numbers are counted',
                      onPressed: _showDefinitions,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(
                        Icons.info_outline_rounded,
                        size: 18,
                        color: _muted,
                      ),
                    ),
                  ],
                ),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    _legend(section.firstLabel, _leadColor),
                    _legend(section.secondLabel, _conversionColor),
                  ],
                ),
                const SizedBox(height: 16),
                PerformanceBarChart(
                  points: points,
                  firstLabel: section.firstLabel,
                  secondLabel: section.secondLabel,
                ),
                if (points.every(
                  (point) => point.first == 0 && point.second == 0,
                ))
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'No records for this period.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _muted, fontSize: 12),
                    ),
                  ),
                if (points.any(
                  (point) => point.first == null || point.second == null,
                ))
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'Some ERP data is unavailable. Tap ⓘ for details.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _muted, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => setState(() => _monthly = !_monthly),
              icon: const Icon(Icons.bar_chart_rounded, size: 17),
              label: Text(
                _monthly ? 'Show weekly trend' : 'Show monthly trend',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _legend(String label, Color color) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(color: _muted, fontSize: 11)),
    ],
  );
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.index,
    required this.series,
    required this.value,
    required this.previous,
    required this.comparisonMonth,
  });
  final int index;
  final List<int?> series;
  final String label, comparisonMonth;
  final int? value, previous;

  @override
  Widget build(BuildContext context) {
    final delta = value == null || previous == null ? null : value! - previous!;
    final positive = delta != null && delta > 0;
    final negative = delta != null && delta < 0;
    final color = negative ? const Color(0xFFBE4D55) : const Color(0xFF269570);
    final percent =
        delta == null
            ? null
            : previous == 0
            ? (value == 0 ? '0%' : 'New')
            : '${(delta.abs() * 100 / previous!).round()}%';
    final accent =
        [
          BrandColors.electricBlue,
          const Color(0xFF18B37A),
          const Color(0xFFF29A25),
          BrandColors.purple,
        ][index];
    final icon =
        [
          Icons.people_alt_rounded,
          Icons.location_on_rounded,
          Icons.description_rounded,
          Icons.shopping_cart_rounded,
        ][index];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.10),
            accent.withValues(alpha: 0.035),
          ],
        ),
        border: Border.all(color: Colors.white, width: 1.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: accent, size: 20),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        value?.toString().padLeft(2, '0') ?? '\u2014',
                        style: const TextStyle(
                          color: _ink,
                          fontSize: 29,
                          height: 1.15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: SizedBox(
                        height: 27,
                        child: CustomPaint(
                          painter: _SparkPainter(series, accent),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Tooltip(
                  message:
                      percent == null
                          ? 'ERP data unavailable'
                          : 'Compared with $comparisonMonth ($previous)',
                  child: Semantics(
                    label:
                        '$label change ${negative
                            ? "down"
                            : positive
                            ? "up"
                            : "unchanged"} ${percent ?? "unavailable"} compared with $comparisonMonth',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (percent != null)
                          Icon(
                            negative
                                ? Icons.arrow_downward_rounded
                                : positive
                                ? Icons.arrow_upward_rounded
                                : Icons.remove_rounded,
                            size: 12,
                            color: color,
                          ),
                        if (percent != null) const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            percent ?? 'Unavailable',
                            style: TextStyle(
                              color: percent == null ? _muted : color,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Sparklines use the selected month's actual weekly totals, with gaps for
// unavailable values. They never invent a rising trend.
class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values, this.color);
  final List<int?> values;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final maximum = values.fold<int>(1, (m, v) => math.max(m, v ?? 0));
    final path = Path();
    var started = false;
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value == null) {
        started = false;
        continue;
      }
      final x = size.width * i / (values.length - 1);
      final y = size.height - 3 - (size.height - 6) * value / maximum;
      if (started) {
        path.lineTo(x, y);
      } else {
        path.moveTo(x, y);
        started = true;
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: 0.65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SparkPainter oldDelegate) =>
      oldDelegate.values != values || oldDelegate.color != color;
}

class PerformanceChartPoint {
  const PerformanceChartPoint({
    required this.label,
    required this.first,
    required this.second,
  });
  final String label;
  final int? first, second;
}

class PerformanceBarChart extends StatelessWidget {
  const PerformanceBarChart({
    super.key,
    required this.points,
    required this.firstLabel,
    required this.secondLabel,
  });
  final List<PerformanceChartPoint> points;
  final String firstLabel, secondLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    label: points
        .map(
          (point) =>
              '${point.label}: $firstLabel ${point.first ?? "unavailable"}, $secondLabel ${point.second ?? "unavailable"}',
        )
        .join('. '),
    child: SizedBox(
      height: 190,
      width: double.infinity,
      child: CustomPaint(painter: _BarPainter(points)),
    ),
  );
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.points);
  final List<PerformanceChartPoint> points;

  void _text(
    Canvas canvas,
    String text,
    Offset offset, {
    bool centered = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: _muted,
          fontSize: 10,
          fontFamily: 'Roboto',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(centered ? offset.dx - painter.width / 2 : offset.dx, offset.dy),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final maxValue = points.fold<int>(
      0,
      (value, point) =>
          math.max(value, math.max(point.first ?? 0, point.second ?? 0)),
    );
    final step = math.max(1, (maxValue / 4).ceil());
    final top = step * 4;
    const left = 30.0;
    const paddingTop = 12.0;
    final bottom = size.height - 28;
    final height = bottom - paddingTop;
    final width = size.width - left - 4;
    final line =
        Paint()
          ..color = const Color(0xFFEEF2F6)
          ..strokeWidth = 1;
    for (var tick = 0; tick <= 4; tick++) {
      final y = bottom - height * tick / 4;
      canvas.drawLine(Offset(left, y), Offset(size.width, y), line);
      _text(canvas, '${tick * step}', Offset(0, y - 6));
    }
    if (points.isEmpty) return;
    final groupWidth = width / points.length;
    final barWidth = math.min(22.0, groupWidth * 0.25);
    for (var index = 0; index < points.length; index++) {
      final point = points[index];
      final center = left + groupWidth * (index + 0.5);
      for (final entry in [
        (point.first, _leadColor, -barWidth - 1),
        (point.second, _conversionColor, 1.0),
      ]) {
        if (entry.$1 == null) continue;
        final barHeight = height * entry.$1! / top;
        if (barHeight <= 0) continue;
        final rect = Rect.fromLTWH(
          center + entry.$3,
          bottom - barHeight,
          barWidth,
          barHeight,
        );
        final paint =
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [entry.$2, entry.$2.withValues(alpha: 0.65)],
              ).createShader(rect);
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            rect,
            topLeft: const Radius.circular(2),
            topRight: const Radius.circular(2),
          ),
          paint,
        );
      }
      _text(canvas, point.label, Offset(center, bottom + 9), centered: true);
    }
  }

  @override
  bool shouldRepaint(covariant _BarPainter oldDelegate) =>
      oldDelegate.points != points;
}
