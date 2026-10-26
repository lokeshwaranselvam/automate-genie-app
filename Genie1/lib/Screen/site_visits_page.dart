import '../utils/widget/pull_to_refresh.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/api/event.dart';
import '../utils/site_visit_distance.dart';
import '../utils/api/site_visit_creation_api.dart';
import 'dart:async';
import 'event_details.dart';
import 'new_site_visit_page.dart';
import 'site_visit_report_page.dart';
import '../utils/widget/home_back_button.dart';

const _visitBlue = BrandColors.ink;
const _visitInk = Color(0xFF202B3C);
const _visitMuted = Color(0xFF7B8492);

enum _VisitTab { scheduled, completed, overdue }

class SiteVisitsPage extends StatefulWidget {
  const SiteVisitsPage({super.key, this.onVisitsUpdated, this.initialEventId});

  final ValueChanged<List<Map<String, dynamic>>>? onVisitsUpdated;
  final String? initialEventId;

  @override
  State<SiteVisitsPage> createState() => _SiteVisitsPageState();
}

class _SiteVisitsPageState extends State<SiteVisitsPage> {
  List<Map<String, dynamic>> _visits = [];
  bool _loading = true;
  String? _error;
  String _query = '';
  _VisitTab _tab = _VisitTab.scheduled;
  final Map<_VisitTab, DateTimeRange> _dateRanges = {};

  DateTimeRange? get _dateRange => _dateRanges[_tab];
  bool _canCreateVisit = false;
  int _permissionRequestId = 0;
  bool _initialVisitOpened = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    unawaited(_loadCreationPermission());
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final email = prefs.getString('email')?.trim() ?? '';
      if (email.isEmpty) throw StateError('Sign in to view your site visits.');

      final scheduled = await Event.eventList(email);
      if (scheduled.isNotEmpty &&
          scheduled.first is Map &&
          scheduled.first['status'] == 'Error') {
        throw StateError(
          scheduled.first['message']?.toString() ?? 'Could not load visits.',
        );
      }

      final now = DateTime.now();
      List<dynamic> history = [];
      try {
        history = await Event.HistoryList(
          email,
          '2000-01-01',
          DateFormat('yyyy-MM-dd').format(now),
          context,
        );
      } catch (error) {
        debugPrint('Could not load completed visit history: $error');
      }

      final byId = <String, Map<String, dynamic>>{};
      for (final item in scheduled) {
        if (item is! Map) continue;
        final visit = Map<String, dynamic>.from(item);
        final id = _id(visit);
        if (id.isEmpty) continue;
        byId[id] = {...?byId[id], ...visit};
      }
      for (final item in history) {
        if (item is! Map) continue;
        final visit = {
          ...Map<String, dynamic>.from(item),
          '_visit_completed_history': true,
        };
        final id = _id(visit);
        if (id.isEmpty) continue;
        byId[id] = {...?byId[id], ...visit};
      }

      if (!mounted) return;
      final visits = byId.values.toList();
      setState(() {
        _visits = visits;
        _loading = false;
      });
      widget.onVisitsUpdated?.call(visits);
      _openInitialVisit();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Bad state: ', '');
        _loading = false;
      });
    }
  }

  void _openInitialVisit() {
    final id = widget.initialEventId?.trim() ?? '';
    if (_initialVisitOpened || id.isEmpty) return;
    Map<String, dynamic>? target;
    for (final visit in _visits) {
      if (_id(visit) == id) {
        target = visit;
        break;
      }
    }
    final visit = target;
    if (visit != null) {
      _initialVisitOpened = true;
      setState(() {
        _tab =
            _isCompleted(visit)
                ? _VisitTab.completed
                : _isOverdue(visit)
                ? _VisitTab.overdue
                : _VisitTab.scheduled;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (visit == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not find this visit. Refresh and try again.'),
          ),
        );
        return;
      }
      unawaited(_openVisit(visit));
    });
  }

  Future<void> _loadCreationPermission() async {
    final requestId = ++_permissionRequestId;
    setState(() => _canCreateVisit = false);
    var allowed = false;
    try {
      final access = await SiteVisitCreationApi.homeQuickActionAccess();
      allowed = access.canCreateVisit && access.featureVisibility['new_visit'] != false;
    } catch (error) {
      debugPrint('Could not check site visit creation permission: $error');
    }
    if (mounted && requestId == _permissionRequestId) {
      setState(() => _canCreateVisit = allowed);
    }
  }

  String _id(Map<String, dynamic> visit) =>
      (visit['name'] ?? visit['event_id'] ?? '').toString().trim();

  DateTime? _startsAt(Map<String, dynamic> visit) =>
      DateTime.tryParse(visit['starts_on']?.toString() ?? '')?.toLocal();

  bool _isCompleted(Map<String, dynamic> visit) {
    if (visit['_visit_completed_history'] == true) return true;
    final checkout = visit['custom_check_out']?.toString().trim() ?? '';
    final endTime = visit['ends_on']?.toString().trim() ?? '';
    final status = visit['status']?.toString().toLowerCase() ?? '';
    return checkout.isNotEmpty ||
        (endTime.isNotEmpty && status == 'completed') ||
        status == 'closed';
  }

  bool _isOverdue(Map<String, dynamic> visit) {
    final startsAt = _startsAt(visit);
    if (startsAt == null || _isCompleted(visit)) return false;
    final today = DateUtils.dateOnly(DateTime.now());
    return DateUtils.dateOnly(startsAt).isBefore(today);
  }

  List<Map<String, dynamic>> get _visibleVisits {
    final query = _query.trim().toLowerCase();
    final rows =
        _visits.where((visit) {
          final tabMatches = switch (_tab) {
            _VisitTab.scheduled => !_isCompleted(visit) && !_isOverdue(visit),
            _VisitTab.completed => _isCompleted(visit),
            _VisitTab.overdue => _isOverdue(visit),
          };
          if (!tabMatches) return false;

          final type = _eventType(visit);
          final range = _dateRange;
          if (range != null) {
            final date = _filterDate(visit, _tab);
            if (date == null) return false;
            final day = DateUtils.dateOnly(date);
            if (day.isBefore(range.start) || day.isAfter(range.end)) {
              return false;
            }
          }
          if (query.isEmpty) return true;
          return [
            _customer(visit),
            visit['subject']?.toString() ?? '',
            type,
            _location(visit),
          ].join(' ').toLowerCase().contains(query);
        }).toList();
    rows.sort((a, b) {
      final first = _startsAt(a) ?? DateTime(9999);
      final second = _startsAt(b) ?? DateTime(9999);
      return _tab == _VisitTab.completed
          ? second.compareTo(first)
          : first.compareTo(second);
    });
    return rows;
  }

  int _count(_VisitTab tab) =>
      _visits.where((visit) {
        return switch (tab) {
          _VisitTab.scheduled => !_isCompleted(visit) && !_isOverdue(visit),
          _VisitTab.completed => _isCompleted(visit),
          _VisitTab.overdue => _isOverdue(visit),
        };
      }).length;

  String _customer(Map<String, dynamic> visit) {
    final direct = visit['party_name'] ?? visit['customer'];
    if (direct != null && direct.toString().trim().isNotEmpty) {
      return direct.toString().trim();
    }
    final participants = visit['reference_details'];
    if (participants is List &&
        participants.isNotEmpty &&
        participants.first is Map) {
      final partyName = participants.first['party_name']?.toString().trim();
      if (partyName != null && partyName.isNotEmpty) return partyName;
    }
    return (visit['subject'] ?? 'Site Visit').toString();
  }

  String _eventType(Map<String, dynamic> visit) =>
      (visit['event_type'] ?? visit['event_category'] ?? '').toString().trim();

  String _location(Map<String, dynamic> visit) =>
      (visit['custom_location'] ?? visit['location'] ?? '').toString().trim();

  String _visitSubtitle(Map<String, dynamic> visit) {
    final subject = visit['subject']?.toString().trim() ?? '';
    final type = _eventType(visit);
    if (subject.isNotEmpty && subject != _customer(visit)) return subject;
    if (type.isNotEmpty) return type;
    final reference = visit['reference_details'];
    if (reference is List && reference.isNotEmpty && reference.first is Map) {
      final opportunity = reference.first['opportunity_from']?.toString();
      final party = reference.first['party_name']?.toString();
      if ((opportunity ?? '').isNotEmpty) return opportunity!;
      if ((party ?? '').isNotEmpty) return party!;
    }
    return 'Customer visit';
  }

  String _dateTimeLabel(Map<String, dynamic> visit) {
    final date = _startsAt(visit);
    if (date == null) return 'Time not set';
    final today = DateUtils.dateOnly(DateTime.now());
    final visitDay = DateUtils.dateOnly(date);
    final dateLabel =
        DateUtils.isSameDay(visitDay, today)
            ? 'Today'
            : DateUtils.isSameDay(visitDay, today.add(const Duration(days: 1)))
            ? 'Tomorrow'
            : DateFormat('d MMM').format(date);
    return '$dateLabel • ${DateFormat('hh:mm a').format(date)}';
  }

  Future<void> _openVisit(Map<String, dynamic> visit) async {
    final id = _id(visit);
    if (id.isEmpty) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => EventDetails(eventid: id)),
    );
    if (mounted) await _refresh();
  }

  Future<void> _openVisitReport(Map<String, dynamic> visit) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SiteVisitReportPage(visit: visit),
      ),
    );
    if (mounted) await _refresh();
  }

  Future<void> _navigateTo(Map<String, dynamic> visit) async {
    final location = _location(visit);
    if (location.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No visit location is available.')),
      );
      return;
    }
    final uri = Uri.https('www.google.com', '/maps/search/', {
      'api': '1',
      'query': location,
    });
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open navigation.')),
      );
    }
  }

  Future<void> _newVisit() async {
    if (!_canCreateVisit) return;
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const NewSiteVisitPage()),
    );
    if (mounted && created == true) await _refresh();
  }

  DateTime? _filterDate(Map<String, dynamic> visit, _VisitTab tab) =>
      tab == _VisitTab.completed ? _completedAt(visit) : _startsAt(visit);

  Future<void> _showDateFilter() async {
    final tab = _tab;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder:
          (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: const Text(
                    'Filter visits by date',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    tab == _VisitTab.completed
                        ? 'Completion date'
                        : 'Scheduled visit date',
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.today),
                  title: const Text('Today'),
                  onTap: () => Navigator.pop(context, 'today'),
                ),
                ListTile(
                  leading: const Icon(Icons.date_range),
                  title: const Text('Choose date range'),
                  onTap: () => Navigator.pop(context, 'range'),
                ),
                ListTile(
                  leading: const Icon(Icons.clear),
                  title: const Text('Clear date filter'),
                  subtitle: const Text('Distance returns to the current month'),
                  onTap: () => Navigator.pop(context, 'all'),
                ),
              ],
            ),
          ),
    );
    if (action == null || !mounted) return;
    if (action == 'all') {
      setState(() => _dateRanges.remove(tab));
      return;
    }
    final today = DateUtils.dateOnly(DateTime.now());
    if (action == 'today') {
      setState(() {
        _dateRanges[tab] = DateTimeRange(start: today, end: today);
      });
      return;
    }
    var firstDate = DateTime(2000);
    var lastDate = DateTime(today.year + 10, 12, 31);
    for (final visit in _visits) {
      final date = _filterDate(visit, tab);
      if (date == null) continue;
      final day = DateUtils.dateOnly(date);
      if (day.isBefore(firstDate)) firstDate = day;
      if (day.isAfter(lastDate)) lastDate = day;
    }
    final currentRange = _dateRanges[tab];
    if (currentRange != null) {
      if (currentRange.start.isBefore(firstDate)) {
        firstDate = currentRange.start;
      }
      if (currentRange.end.isAfter(lastDate)) lastDate = currentRange.end;
    }
    final selected = await showDateRangePicker(
      context: context,
      firstDate: firstDate,
      lastDate: lastDate,
      initialDateRange: currentRange,
      helpText:
          tab == _VisitTab.completed
              ? 'Filter by completion date'
              : 'Filter by scheduled visit date',
    );
    if (selected == null || !mounted) return;
    setState(() => _dateRanges[tab] = selected);
  }

  @override
  Widget build(BuildContext context) {
    final visits = _visibleVisits;
    final now = DateTime.now();
    final distanceVisits =
        _dateRange != null
            ? visits
            : visits.where((visit) {
              final date = _filterDate(visit, _tab);
              return date != null &&
                  date.year == now.year &&
                  date.month == now.month;
            }).toList();
    final distances =
        distanceVisits
            .map((visit) => SiteVisitDistance.meters(visit['custom_distance']))
            .whereType<double>()
            .toList();
    final totalDistance = distances.fold<double>(
      0,
      (total, distance) => total + distance,
    );
    final distanceLabel =
        _loading && _visits.isEmpty
            ? 'Loading…'
            : distances.isEmpty && (distanceVisits.isNotEmpty || _error != null)
            ? 'Not recorded'
            : '${(totalDistance / 1000).toStringAsFixed(2)} km';
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: brandAppBar(
        leading: const HomeBackButton(color: Colors.white),
        elevation: 0,
        title: const Text(
          'Site Visits',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Tooltip(
              message:
                  'Recorded distance for ${distances.length} of ${distanceVisits.length} visits ${_dateRange == null ? 'in the current month' : 'in the selected date range'}. Updates with the selected tab and search.',
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 110),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _dateRange == null
                          ? 'This month travelled'
                          : 'Total travelled',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                    Text(
                      distanceLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Row(
            children: [
              _tabButton('Scheduled', _VisitTab.scheduled),
              _tabButton('Completed', _VisitTab.completed),
              _tabButton('Overdue', _VisitTab.overdue),
            ],
          ),
        ),
      ),
      body: PullToRefresh(
        enabled: !_loading,
        onRefresh: _refresh,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      onChanged: (value) => setState(() => _query = value),
                      decoration: InputDecoration(
                        hintText: 'Search visits...',
                        hintStyle: const TextStyle(color: _visitMuted),
                        prefixIcon: const Icon(
                          Icons.search,
                          color: _visitMuted,
                        ),
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: EdgeInsets.zero,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(13),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filledTonal(
                    tooltip: 'Filter visit date',
                    onPressed: _showDateFilter,
                    icon: const Icon(Icons.filter_list_rounded),
                  ),
                ],
              ),
            ),
            if (_dateRange != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: InputChip(
                    avatar: const Icon(Icons.date_range, size: 18),
                    label: Text(
                      '${DateFormat('d MMM yyyy').format(_dateRange!.start)} – ${DateFormat('d MMM yyyy').format(_dateRange!.end)}',
                    ),
                    onPressed: _showDateFilter,
                    onDeleted: () => setState(() => _dateRanges.remove(_tab)),
                    deleteButtonTooltipMessage: 'Clear date filter',
                  ),
                ),
              ),
            Expanded(
              child:
                  _loading && _visits.isEmpty
                      ? const Center(child: AgPathLoadingIndicator())
                      : _error != null && _visits.isEmpty
                      ? _errorView()
                      : visits.isEmpty
                      ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: ClampingScrollPhysics(),
                        ),
                        children: [
                          const SizedBox(height: 150),
                          Center(
                            child: Text(
                              _emptyMessage,
                              style: const TextStyle(color: _visitMuted),
                            ),
                          ),
                        ],
                      )
                      : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: ClampingScrollPhysics(),
                        ),
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                        itemCount: visits.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 9),
                        itemBuilder:
                            (context, index) => _visitCard(visits[index]),
                      ),
            ),
          ],
        ),
      ),
      floatingActionButton:
          !_canCreateVisit
              ? null
              : brandFloatingActionButton(
                onPressed: _newVisit,
                icon: const Icon(Icons.add_rounded),
                label: const Text(
                  'New Visit',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
    );
  }

  String get _emptyMessage => switch (_tab) {
    _VisitTab.scheduled =>
      _dateRange != null
          ? 'No scheduled visits in the selected date range.'
          : 'No scheduled visits.',
    _VisitTab.completed =>
      _dateRange != null
          ? 'No completed visits in the selected date range.'
          : 'No completed visit history.',
    _VisitTab.overdue =>
      _dateRange != null
          ? 'No overdue visits in the selected date range.'
          : 'No overdue visits.',
  };

  Widget _errorView() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );

  Widget _tabButton(String label, _VisitTab tab) {
    final selected = _tab == tab;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _tab = tab),
        child: Column(
          children: [
            SizedBox(
              height: 49,
              child: Center(
                child: Text(
                  '$label (${_count(tab)})',
                  style: TextStyle(
                    color: selected ? _visitBlue : _visitInk,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
            Container(
              height: 3,
              decoration: BoxDecoration(
                gradient: selected ? BrandColors.gradient : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _visitCard(Map<String, dynamic> visit) {
    final completed = _isCompleted(visit);
    final overdue = _isOverdue(visit);
    final location = _location(visit);
    final title = _customer(visit);
    final actionLabel = overdue ? 'Details' : 'Start Visit';
    final distance = SiteVisitDistance.meters(visit['custom_distance']);
    return Card(
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFE8EBEF)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openVisit(visit),
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor:
                    completed
                        ? const Color(0xFFE8F6EF)
                        : overdue
                        ? const Color(0xFFFFF1E5)
                        : const Color(0xFFEAF3FF),
                child: Icon(
                  completed
                      ? Icons.check_rounded
                      : overdue
                      ? Icons.warning_amber_rounded
                      : Icons.apartment_rounded,
                  color:
                      completed
                          ? const Color(0xFF219653)
                          : overdue
                          ? const Color(0xFFE58A21)
                          : _visitBlue,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _visitInk,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _visitSubtitle(visit),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _visitMuted, fontSize: 12),
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Icon(
                          completed ? Icons.check_circle : Icons.schedule,
                          size: 14,
                          color: completed ? Colors.green : _visitMuted,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            completed
                                ? _completedLabel(visit)
                                : _dateTimeLabel(visit),
                            style: const TextStyle(
                              color: _visitMuted,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (location.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          const Icon(
                            Icons.location_on,
                            size: 14,
                            color: _visitMuted,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              location,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _visitMuted,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (completed || location.isNotEmpty)
                    TextButton(
                      onPressed:
                          completed
                              ? () => _openVisitReport(visit)
                              : () => _navigateTo(visit),
                      style: TextButton.styleFrom(
                        backgroundColor: const Color(0xFFEAF3FF),
                        foregroundColor: _visitBlue,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 34),
                      ),
                      child: const Text(
                        'Navigate',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  const SizedBox(height: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 110),
                    child: Text(
                      'Travelled: ${distance == null ? 'Not recorded' : SiteVisitDistance.format(distance)}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: _visitMuted, fontSize: 11),
                    ),
                  ),
                  if (!completed) ...[
                    const SizedBox(height: 6),
                    FilledButton(
                      onPressed: () => _openVisit(visit),
                      style: FilledButton.styleFrom(
                        backgroundColor: _visitBlue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 34),
                      ).copyWith(
                        backgroundBuilder: BrandColors.buttonBackground,
                      ),
                      child: Text(
                        actionLabel,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  DateTime? _completedAt(Map<String, dynamic> visit) {
    final checkOut =
        DateTime.tryParse(
          (visit['custom_check_out'] ?? visit['ends_on'])?.toString() ?? '',
        )?.toLocal();
    return checkOut ?? _startsAt(visit);
  }

  String _completedLabel(Map<String, dynamic> visit) {
    final completedAt = _completedAt(visit);
    if (completedAt == null) return 'Visit completed';
    return 'Completed • ${DateFormat('d MMM, hh:mm a').format(completedAt)}';
  }
}
