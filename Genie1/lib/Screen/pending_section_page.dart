import '../utils/widget/pull_to_refresh.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../utils/api/pending_work_api.dart';
import '../utils/api/pending_work_monitor.dart';
import '../utils/api/session_auth.dart';
import '../utils/widget/pending_work_alarm_player.dart';
import '../utils/widget/glass_card.dart';
import '../utils/widget/home_back_button.dart';
import 'opportunities_webview_page.dart';

const Color _primary = BrandColors.ink;
const Color _primaryDark = BrandColors.indigo;
const Color _background = Color(0xFFF4F7FB);
const Color _textDark = Color(0xFF17202A);
const Color _textMuted = Color(0xFF697586);
const Color _cardBorder = Color(0xFFE1E8F0);
const Color _success = Color(0xFF2E7D32);

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

/// Frappe labels can look like "Label:Data:120" or contain HTML.
String _cleanLabel(String value) {
  var v = value;
  if (v.contains(':')) v = v.split(':').first;
  v = v.replaceAll(RegExp(r'<[^>]*>'), '');
  return v.trim();
}

String _sectionFieldLabel(String fieldname) {
  const labels = {
    'opportunity': 'Opportunity',
    'customer': 'Customer',
    'opportunity_owner': 'Opportunity Owner',
    'field_owner': 'Field Owner 1',
    'field_owner_1': 'Field Owner 2',
    'next_followup_date': 'Next Follow Up',
    'expected_closing_date': 'Expected Closing Date',
    'delivery_note': 'Delivery Note',
    'created_on': 'Created On',
    'company': 'Company',
    'owner': 'Owner',
    'overdue_days': 'Days Overdue',
  };
  final knownLabel = labels[fieldname];
  if (knownLabel != null) return knownLabel;
  return fieldname
      .replaceAll('_', ' ')
      .split(' ')
      .map(
        (word) =>
            word.isEmpty
                ? word
                : '${word[0].toUpperCase()}${word.substring(1)}',
      )
      .join(' ');
}

/// Normalizes the user-specific items into the list/detail screen's structure.
Map<String, dynamic> _normalizeSection(dynamic section) {
  if (section is! Map) {
    return {
      'count': 0,
      'columns': <Map<String, dynamic>>[],
      'items': <Map<String, dynamic>>[],
    };
  }

  final rawColumns = section['columns'];
  final columns =
      rawColumns is List
          ? rawColumns
              .whereType<Map>()
              .map((c) => Map<String, dynamic>.from(c))
              .toList()
          : <Map<String, dynamic>>[];

  final fieldnames =
      columns
          .map((c) => c['fieldname']?.toString())
          .whereType<String>()
          .toList();

  final items = <Map<String, dynamic>>[];
  final rawItems = section['items'];

  if (rawItems is List) {
    for (final row in rawItems) {
      if (row is Map) {
        items.add(Map<String, dynamic>.from(row));
      } else if (row is List) {
        final map = <String, dynamic>{};
        for (var i = 0; i < row.length; i++) {
          final key = i < fieldnames.length ? fieldnames[i] : 'col_$i';
          map[key] = row[i];
        }
        items.add(map);
      }
    }
  }

  final rawCount = section['count'];
  final count =
      rawCount is int
          ? rawCount
          : (rawCount is num
              ? rawCount.toInt()
              : int.tryParse(rawCount?.toString() ?? '') ?? items.length);

  return {'count': count, 'columns': columns, 'items': items};
}

// =============================================================================
// Pending entry list for role-authorized Pending Work sections.
// =============================================================================

class PendingSectionPage extends StatefulWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback? onMenuPressed;
  final bool isActive;

  /// The section key returned by get_pending_work's dashboard action.
  final String section;
  final VoidCallback? onBack;

  const PendingSectionPage({
    super.key,
    required this.title,
    this.subtitle,
    required this.icon,
    required this.section,
    this.onMenuPressed,
    this.onBack,
    this.isActive = false,
  });

  @override
  State<PendingSectionPage> createState() => _PendingSectionPageState();
}

class _PendingSectionPageState extends State<PendingSectionPage> {
  bool _loading = true;
  String? _error;

  int _count = 0;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _columns = [];
  Map<String, String> _userFullNames = {};

  final TextEditingController _searchController = TextEditingController();
  String _searchText = '';
  StreamSubscription<String>? _pendingEntrySubscription;

  @override
  void initState() {
    super.initState();

    _pendingEntrySubscription = PendingWorkMonitor.newEntrySections.listen((
      section,
    ) {
      if (section == widget.section && widget.isActive) _load();
    });

    _searchController.addListener(() {
      if (!mounted) return;
      setState(() {
        _searchText = _searchController.text.trim().toLowerCase();
      });
    });

    if (widget.isActive) _load();
  }

  @override
  void didUpdateWidget(covariant PendingSectionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) _load();
  }

  @override
  void dispose() {
    final subscription = _pendingEntrySubscription;
    if (subscription != null) unawaited(subscription.cancel());
    _searchController.dispose();
    super.dispose();
  }

  // Overlapping loads are coalesced: a request during an in-flight load runs
  // one more load afterwards, so responses apply in order and recordSnapshot
  // (which counts new entries for the alarm) runs once per completed load.
  bool _loadInFlight = false;
  bool _reloadRequested = false;

  Future<void> _load() async {
    if (!mounted) return;
    if (_loadInFlight) {
      _reloadRequested = true;
      return;
    }
    _loadInFlight = true;
    try {
      do {
        _reloadRequested = false;
        await _loadOnce();
      } while (_reloadRequested && mounted);
    } finally {
      _loadInFlight = false;
    }
  }

  Future<void> _loadOnce() async {
    if (!mounted) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final items = await PendingWorkApi.getPendingSectionItems(widget.section);
      final newItemsCount = await PendingWorkMonitor.recordSnapshot(
        widget.section,
        items,
        previousItems: _items,
      );

      final fieldnames = <String>{};
      for (final item in items) {
        fieldnames.addAll(item.keys.where((key) => !key.startsWith('_')));
      }
      final report = _normalizeSection({
        'count': items.length,
        'columns':
            fieldnames
                .map(
                  (fieldname) => {
                    'fieldname': fieldname,
                    'label': _sectionFieldLabel(fieldname),
                  },
                )
                .toList(),
        'items': items,
      });

      if (!mounted) return;

      setState(() {
        _count = report['count'] as int;
        _items = report['items'] as List<Map<String, dynamic>>;
        _columns = report['columns'] as List<Map<String, dynamic>>;
        _loading = false;
      });
      _resolvePendingUserNames(items);

      for (var i = 0; i < newItemsCount; i++) {
        unawaited(PendingWorkAlarmPlayer.play());
      }
    } catch (e) {
      debugPrint('PendingSectionPage(${widget.section}) error: $e');

      if (!mounted) return;

      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  /// Identifies a pending row the same way for the list item and the
  /// refreshed rows, so detail refresh finds the same record.
  static Object? _pendingItemId(Map<String, dynamic> row) =>
      row['name'] ??
      row['id'] ??
      row['stock_entry'] ??
      row['job_card'] ??
      row['project'] ??
      row['opportunity'] ??
      row['delivery_note'];

  bool _isUserField(String field) {
    final key = field.toLowerCase();
    return key == 'owner' ||
        key == 'user' ||
        key == 'user_id' ||
        key == 'assigned_to' ||
        key == 'allocated_to' ||
        key == 'created_by' ||
        key == 'modified_by' ||
        key.endsWith('_owner') ||
        key.endsWith('_assigned_to') ||
        key.endsWith('_allocated_to');
  }

  void _resolvePendingUserNames(List<Map<String, dynamic>> items) {
    final userIds = <String>{};
    for (final item in items) {
      for (final entry in item.entries) {
        final userId = entry.value?.toString().trim() ?? '';
        if (_isUserField(entry.key) &&
            userId.isNotEmpty &&
            userId.toLowerCase() != 'null' &&
            userId.contains('@')) {
          userIds.add(userId);
        }
      }
    }

    for (final userId in userIds.take(12)) {
      unawaited(() async {
        final fullName = await SessionAuthApi.getUserFullName(userId);
        if (!mounted || fullName == null || fullName.isEmpty) return;
        setState(() {
          _userFullNames = {..._userFullNames, userId.toLowerCase(): fullName};
        });
      }());
    }
  }

  String _displayFieldValue(String field, dynamic value) {
    final text = value?.toString() ?? '';
    if (!_isUserField(field) || !text.contains('@')) return text;
    return _userFullNames[text.toLowerCase()] ?? 'User';
  }

  /// First non-empty column value = title, next ones = subtitle.
  ({String title, String subtitle}) _summaryFor(Map<String, dynamic> item) {
    if (widget.section == 'overdue_followups') {
      final customer = item['customer']?.toString().trim();
      final opportunity = item['opportunity']?.toString().trim();
      final status = item['status']?.toString().trim();
      final nextFollowup = item['next_followup_date']?.toString().trim();
      final overdueDays = item['overdue_days']?.toString().trim();
      final details = <String>[];

      if (opportunity != null && opportunity.isNotEmpty) {
        details.add(opportunity);
      }
      if (status != null && status.isNotEmpty) details.add(status);
      if (nextFollowup != null && nextFollowup.isNotEmpty) {
        details.add('Due $nextFollowup');
      }
      if (overdueDays != null && overdueDays.isNotEmpty) {
        details.add('$overdueDays days overdue');
      }

      return (
        title:
            customer == null || customer.isEmpty
                ? (opportunity == null || opportunity.isEmpty
                    ? 'Opportunity'
                    : opportunity)
                : customer,
        subtitle: details.join(' • '),
      );
    }

    if (widget.section == 'overdue_closing') {
      final customer = item['customer']?.toString().trim();
      final opportunity = item['opportunity']?.toString().trim();
      final status = item['status']?.toString().trim();
      final closingDate = item['expected_closing_date']?.toString().trim();
      final overdueDays = item['overdue_days']?.toString().trim();
      final details = <String>[];

      if (opportunity != null && opportunity.isNotEmpty) {
        details.add(opportunity);
      }
      if (status != null && status.isNotEmpty) details.add(status);
      if (closingDate != null && closingDate.isNotEmpty) {
        details.add('Closing date $closingDate');
      }
      if (overdueDays != null && overdueDays.isNotEmpty) {
        details.add('$overdueDays days overdue');
      }

      return (
        title:
            customer == null || customer.isEmpty
                ? (opportunity == null || opportunity.isEmpty
                    ? 'Opportunity'
                    : opportunity)
                : customer,
        subtitle: details.join(' • '),
      );
    }

    const preferredTitleFields = [
      'subject',
      'customer_name',
      'customer',
      'title',
      'project_name',
      'item_name',
      'production_item',
      'opportunity_id',
      'name',
    ];
    String title = '';
    final parts = <String>[];

    for (final field in preferredTitleFields) {
      final value = item[field]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        title = value;
        break;
      }
    }

    for (final col in _columns) {
      final fieldname = col['fieldname']?.toString();
      if (fieldname == null) continue;
      if (fieldname.startsWith('_') || fieldname == 'subject') continue;

      final value = item[fieldname];
      if (value == null || value.toString().trim().isEmpty) continue;

      if (title.isEmpty) {
        title = _displayFieldValue(fieldname, value);
      } else if (_displayFieldValue(fieldname, value) != title) {
        final label = _cleanLabel(col['label']?.toString() ?? fieldname);
        parts.add('$label: ${_displayFieldValue(fieldname, value)}');
      }
    }

    if (title.isEmpty) {
      final values =
          item.values
              .where((v) => v != null && v.toString().trim().isNotEmpty)
              .map((v) => v.toString())
              .toList();

      if (values.isNotEmpty) {
        title = values.first;
        parts.addAll(values.skip(1));
      }
    }

    if (title.isEmpty) title = 'Item';
    final pendingType = item['_pending_type']?.toString();
    if (pendingType != null && pendingType.isNotEmpty) {
      parts.insert(0, pendingType);
    }

    return (title: title, subtitle: parts.take(3).join(' • '));
  }

  void _openDetails(Map<String, dynamic> item) {
    if (widget.section == 'opportunities') {
      final opportunityId = item['opportunity_id']?.toString().trim() ?? '';
      final name = item['name']?.toString().trim() ?? '';
      final id = opportunityId.isNotEmpty ? opportunityId : name;
      if (id.isNotEmpty) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => OpportunitiesWebViewPage(initialOpportunityId: id),
          ),
        );
        return;
      }
    }

    final summary = _summaryFor(item);
    final displayItem = Map<String, dynamic>.from(item);
    for (final entry in item.entries) {
      if (_isUserField(entry.key) &&
          entry.value?.toString().contains('@') == true) {
        displayItem[entry.key] = _displayFieldValue(entry.key, entry.value);
      }
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => PendingDetailPage(
              sectionTitle: widget.title,
              icon: widget.icon,
              title: summary.title,
              item: displayItem,
              columns: _columns,
              section: widget.section,
              loadItem: () async {
                final latest = await PendingWorkApi.getPendingSectionItems(
                  widget.section,
                );
                final id = _pendingItemId(item);
                final matches = latest.where(
                  (row) => _pendingItemId(row) == id,
                );
                if (id == null || matches.isEmpty) {
                  throw StateError(
                    'This item is no longer pending. Return to the list and refresh.',
                  );
                }
                return {
                  for (final entry in matches.first.entries)
                    entry.key: _displayFieldValue(entry.key, entry.value),
                };
              },
            ),
      ),
    );
  }

  List<Map<String, dynamic>> get _filtered {
    if (_searchText.isEmpty) return _items;

    return _items
        .where((i) => i.values.join(' ').toLowerCase().contains(_searchText))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _background,
      appBar: brandAppBar(
        elevation: 0,
        centerTitle: false,
        leading: const HomeBackButton(color: Colors.white),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (widget.subtitle?.isNotEmpty == true) ...[
              const SizedBox(height: 2),
              Text(
                widget.subtitle!,
                style: const TextStyle(color: Colors.white, fontSize: 11.5),
              ),
            ],
          ],
        ),
        actions: [const SizedBox(width: 6)],
      ),
      body: PullToRefresh(
        enabled: !_loading,
        onRefresh: _load,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _items.isEmpty) {
      return const Center(child: AgPathLoadingIndicator());
    }

    if (_error != null && _items.isEmpty) {
      return _buildError();
    }

    final list = _filtered;
    final headerCount = _items.isEmpty ? 0 : 4;

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(
        parent: ClampingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 30),
      itemCount: headerCount + (list.isEmpty ? 1 : list.length),
      itemBuilder: (context, index) {
        if (headerCount > 0) {
          if (index == 0) return _buildCountCard();
          if (index == 1 || index == 3) return const SizedBox(height: 14);
          if (index == 2) return _buildSearch();
        }
        if (list.isEmpty) return _buildEmpty();
        return _buildItemCard(list[index - headerCount]);
      },
    );
  }

  Widget _buildCountCard() {
    return GlassCard(
      borderRadius: BorderRadius.circular(22),
      tintColor: _primaryDark.withValues(alpha: 0.84),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(widget.icon, color: Colors.white, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.section == 'overdue_followups'
                        ? 'Overdue follow-ups'
                        : widget.section == 'overdue_closing'
                        ? 'Overdue opportunities'
                        : 'Pending items',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$_count',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearch() {
    return GlassCard(
      borderRadius: BorderRadius.circular(16),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: 'Search ${widget.title.toLowerCase()}...',
          hintStyle: const TextStyle(color: _textMuted, fontSize: 13),
          prefixIcon: const Icon(Icons.search_rounded, color: _primary),
          suffixIcon:
              _searchText.isNotEmpty
                  ? IconButton(
                    onPressed: _searchController.clear,
                    icon: const Icon(Icons.clear_rounded),
                  )
                  : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 15,
          ),
        ),
      ),
    );
  }

  Widget _buildItemCard(Map<String, dynamic> item) {
    final summary = _summaryFor(item);

    return GlassCard(
      margin: const EdgeInsets.only(bottom: 11),
      borderRadius: BorderRadius.circular(18),
      onTap: () => _openDetails(item),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _background,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(widget.icon, color: _primary, size: 21),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _textDark,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (summary.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      summary.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _textMuted, fontSize: 11.5),
                    ),
                  ],
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: _textMuted),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    final searching = _items.isNotEmpty && _searchText.isNotEmpty;

    return GlassCard(
      padding: const EdgeInsets.all(30),
      child: Column(
        children: [
          Icon(
            searching
                ? Icons.search_off_rounded
                : Icons.check_circle_outline_rounded,
            color: searching ? _textMuted : _success,
            size: 42,
          ),
          const SizedBox(height: 12),
          Text(
            searching ? 'No matching items' : 'No pending items',
            style: const TextStyle(
              color: _textDark,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.cloud_off_rounded,
                color: Colors.red,
                size: 34,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Unable to load ${widget.title}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _textDark,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? 'Unknown error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: _textMuted, fontSize: 12),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// DETAILS PAGE (opens when an item in the list is tapped)
// =============================================================================

class PendingDetailPage extends StatefulWidget {
  final String? section;
  final String sectionTitle;
  final IconData icon;
  final String title;
  final Map<String, dynamic> item;
  final List<Map<String, dynamic>> columns;
  final Future<Map<String, dynamic>> Function()? loadItem;

  const PendingDetailPage({
    super.key,
    required this.sectionTitle,
    required this.icon,
    required this.title,
    required this.item,
    required this.columns,
    this.section,
    this.loadItem,
  });

  @override
  State<PendingDetailPage> createState() => _PendingDetailPageState();
}

class _PendingDetailPageState extends State<PendingDetailPage> {
  late Map<String, dynamic> item = widget.item;
  String? get section => widget.section;
  String get sectionTitle => widget.sectionTitle;
  String get title => widget.title;
  IconData get icon => widget.icon;
  List<Map<String, dynamic>> get columns => widget.columns;

  Future<void> _refresh() async {
    final load = widget.loadItem;
    if (load == null) return;
    try {
      final updated = await load();
      if (mounted) setState(() => item = updated);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Bad state: ', '')),
          ),
        );
      }
    }
  }

  /// Ordered label/value pairs: report columns first, then any extra keys.
  List<MapEntry<String, String>> _entries() {
    final entries = <MapEntry<String, String>>[];
    final used = <String>{};

    for (final col in columns) {
      final fieldname = col['fieldname']?.toString();
      if (fieldname == null) continue;

      used.add(fieldname);
      if (_isRepeatedStockEntry(fieldname, item[fieldname])) continue;

      final value = item[fieldname];
      if (value == null || value.toString().trim().isEmpty) continue;

      final label = _cleanLabel(col['label']?.toString() ?? fieldname);
      entries.add(MapEntry(label, value.toString()));
    }

    item.forEach((key, value) {
      if (used.contains(key) || key.startsWith('_')) return;
      if (_isRepeatedStockEntry(key, value)) return;
      if (value == null || value.toString().trim().isEmpty) return;

      entries.add(MapEntry(_cleanLabel(key), value.toString()));
    });

    return entries;
  }

  bool _isRepeatedStockEntry(String field, dynamic value) =>
      section == 'stock' &&
      field == 'stock_entry' &&
      (item['name']?.toString().trim().isNotEmpty ?? false) &&
      value?.toString().trim() == item['name'].toString().trim();

  @override
  Widget build(BuildContext context) {
    final entries = _entries();

    return Scaffold(
      backgroundColor: _background,
      appBar: brandAppBar(
        leading: const HomeBackButton(color: Colors.white),
        elevation: 0,
        title: Text(
          '$sectionTitle Details',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body: PullToRefresh(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 30),
          children: [
            // Stock Entry IDs already appear in the Name row.
            if (section != 'stock') ...[
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: BrandColors.gradient,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(icon, color: Colors.white, size: 26),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),
            ],

            // Fields
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _cardBorder),
              ),
              child:
                  entries.isEmpty
                      ? const Padding(
                        padding: EdgeInsets.all(20),
                        child: Center(
                          child: Text(
                            'No details available',
                            style: TextStyle(color: _textMuted),
                          ),
                        ),
                      )
                      : Column(
                        children: [
                          for (var i = 0; i < entries.length; i++) ...[
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 110,
                                    child: Text(
                                      entries[i].key,
                                      style: const TextStyle(
                                        color: _textMuted,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: SelectableText(
                                      entries[i].value,
                                      style: const TextStyle(
                                        color: _textDark,
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (i != entries.length - 1)
                              const Divider(height: 1, color: _cardBorder),
                          ],
                        ],
                      ),
            ),
          ],
        ),
      ),
    );
  }
}
