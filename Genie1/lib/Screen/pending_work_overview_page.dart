import '../utils/widget/pull_to_refresh.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'package:flutter/material.dart';

import '../utils/api/pending_work_api.dart';
import 'pending_section_page.dart';
import '../utils/widget/home_back_button.dart';

const _pendingSections = <_PendingSectionInfo>[
  _PendingSectionInfo(
    keyName: 'stock',
    team: 'Production Team',
    title: 'Pending Transferred MTM',
    icon: Icons.inventory_2_outlined,
  ),
  _PendingSectionInfo(
    keyName: 'manufacturing',
    team: 'Production Team',
    title: 'Pending Jobcards',
    icon: Icons.precision_manufacturing_outlined,
  ),
  _PendingSectionInfo(
    keyName: 'projects',
    team: 'Production Team',
    title: 'Pending Production Confirm PBF',
    icon: Icons.work_outline_rounded,
  ),
  _PendingSectionInfo(
    keyName: 'same_area_city',
    team: 'Sales Team',
    title: 'Same Area & City',
    icon: Icons.location_city_outlined,
  ),
  _PendingSectionInfo(
    keyName: 'opportunities',
    team: 'Sales Team',
    title: 'Open Opportunities',
    icon: Icons.handshake_outlined,
  ),
  _PendingSectionInfo(
    keyName: 'overdue_followups',
    team: 'Sales Team',
    title: 'Overdue Next Follow Up',
    icon: Icons.phone_callback_outlined,
  ),
  _PendingSectionInfo(
    keyName: 'overdue_closing',
    team: 'Sales Team',
    title: 'Overdue Closing Date',
    icon: Icons.event_busy_outlined,
  ),
  _PendingSectionInfo(
    keyName: 'draft_delivery_plans',
    team: 'Sales Team',
    title: 'Pending Draft Delivery Plans',
    icon: Icons.local_shipping_outlined,
  ),
];

class PendingWorkOverviewPage extends StatefulWidget {
  const PendingWorkOverviewPage({super.key});

  @override
  State<PendingWorkOverviewPage> createState() =>
      _PendingWorkOverviewPageState();
}

class _PendingWorkOverviewPageState extends State<PendingWorkOverviewPage> {
  Map<String, dynamic> _dashboard = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
      _dashboard = {};
    });
    try {
      final dashboard = await PendingWorkApi.getMobileDashboard();
      if (!mounted) return;
      setState(() {
        _dashboard = dashboard;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  int _count(String key) {
    final value = (_dashboard[key] as Map?)?['count'];
    return value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  }

  Set<String> get _availableSections {
    final raw = _dashboard['available_sections'];
    if (raw is List) {
      return raw.map((section) => section.toString()).toSet();
    }

    // Older responses may omit the explicit role list but still include a
    // zero-count map for each section available to this user. Use key presence
    // as the fallback so authorized empty sections remain visible.
    return _pendingSections
        .where((section) => _dashboard[section.keyName] is Map)
        .map((section) => section.keyName)
        .toSet();
  }

  Future<void> _openSection(_PendingSectionInfo section) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder:
            (_) => PendingSectionPage(
              title: section.title,
              icon: section.icon,
              section: section.keyName,
              isActive: true,
            ),
      ),
    );
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final visibleSections =
        _pendingSections
            .where((section) => _availableSections.contains(section.keyName))
            .toList();
    final total = visibleSections.fold<int>(
      0,
      (sum, section) => sum + _count(section.keyName),
    );
    final teamCards = <Widget>[];
    for (final team in ['Production Team', 'Sales Team']) {
      final teamSections =
          visibleSections.where((section) => section.team == team).toList();
      if (teamSections.isEmpty) continue;
      teamCards.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
          child: Text(
            team,
            style: const TextStyle(
              color: Color(0xFF263445),
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      );
      for (final section in teamSections) {
        teamCards.add(
          Card(
            color: Colors.white,
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: const Color(0xFFEAF3FF),
                child: Icon(section.icon, color: BrandColors.ink),
              ),
              title: Text(
                section.title,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${_count(section.keyName)}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
              onTap: () => _openSection(section),
            ),
          ),
        );
      }
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FB),
      appBar: brandAppBar(
        leading: const HomeBackButton(),
        title: const Text('Pending Work'),
      ),
      body: PullToRefresh(
        enabled: !_loading,
        onRefresh: _refresh,
        child:
            _loading && _dashboard.isEmpty
                ? const Center(child: AgPathLoadingIndicator())
                : _error != null && _dashboard.isEmpty
                ? Center(
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
                )
                : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Card(
                      color: BrandColors.ink,
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.pending_actions_rounded,
                              color: Colors.white,
                              size: 34,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Pending items',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                  Text(
                                    '$total',
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
                    ),
                    const SizedBox(height: 8),
                    if (visibleSections.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 28),
                        child: Center(
                          child: Text(
                            'No pending work is available for your roles.',
                          ),
                        ),
                      ),
                    ...teamCards,
                  ],
                ),
      ),
    );
  }
}

class _PendingSectionInfo {
  final String keyName;
  final String team;
  final String title;
  final IconData icon;

  const _PendingSectionInfo({
    required this.keyName,
    required this.team,
    required this.title,
    required this.icon,
  });
}
