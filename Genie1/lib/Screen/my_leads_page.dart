import '../utils/widget/ag_path_loading_indicator.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/api/lead_api.dart';
import '../utils/widget/home_back_button.dart';
import 'lead_creation_page.dart';
import 'lead_details_page.dart';
import 'my_opportunities_page.dart';

class MyLeadsPage extends StatefulWidget {
  const MyLeadsPage({super.key, this.showOpportunities = false});

  final bool showOpportunities;

  @override
  State<MyLeadsPage> createState() => _MyLeadsPageState();
}

class _MyLeadsPageState extends State<MyLeadsPage> {
  static const _statuses = [
    'Open',
    'Lead',
    'Junk',
    'Followup',
    'RNR',
    'Hot Followup',
    'Not Interested',
    'Duplicate Lead',
  ];
  final _phone = TextEditingController();
  String _status = '';
  int _section = 0;
  bool _opportunitiesOpened = false;
  List<Map<String, dynamic>> _leads = [];
  bool _loading = true;
  String? _error;

  @override
  void didUpdateWidget(covariant MyLeadsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.showOpportunities) {
      _section = 0;
      _opportunitiesOpened = false;
    }
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _filteredLeads =>
      _leads.where((lead) {
        if (_status.isNotEmpty &&
            lead['status']?.toString().trim() != _status) {
          return false;
        }
        final phone = _phone.text;
        return phone.isEmpty ||
            ['mobile_no', 'phone'].any(
              (field) => (lead[field]?.toString() ?? '')
                  .replaceAll(RegExp(r'\D'), '')
                  .contains(phone),
            );
      }).toList();

  Future<void> _chooseStatus() async {
    final selected = await showDialog<String>(
      context: context,
      builder:
          (context) => SimpleDialog(
            title: const Text('Filter by status'),
            children: [
              for (final status in _statuses)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, status),
                  child: Text(status),
                ),
              if (_status.isNotEmpty)
                TextButton(
                  onPressed: () => Navigator.pop(context, ''),
                  child: const Text('Clear filter'),
                ),
            ],
          ),
    );
    if (selected != null && mounted) setState(() => _status = selected);
  }

  @override
  void initState() {
    super.initState();
    _loadLeads();
  }

  Future<void> _loadLeads() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final leads = await LeadApi.getMyLeads();
      if (!mounted) return;
      setState(() {
        _leads = leads;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  Future<void> _createLead() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const LeadCreationPage()),
    );
    if (mounted) await _loadLeads();
  }

  String _leadTitle(Map<String, dynamic> lead) {
    for (final field in ['lead_name', 'first_name', 'name']) {
      final value = lead[field]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return 'Unnamed Lead';
  }

  String _leadSubtitle(Map<String, dynamic> lead) {
    final details = <String>[];
    final mobile = lead['mobile_no']?.toString().trim() ?? '';
    final status = lead['status']?.toString().trim() ?? '';
    final requirement = lead['custom_requirement']?.toString().trim() ?? '';
    if (mobile.isNotEmpty) details.add(mobile);
    if (status.isNotEmpty) details.add(status);
    if (requirement.isNotEmpty) details.add(requirement);
    return details.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final leads = _filteredLeads;
    final leadsPage = Scaffold(
      appBar:
          widget.showOpportunities
              ? null
              : brandAppBar(
                leading: const HomeBackButton(color: Colors.white),
                title: const Text('My Leads'),
              ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(15),
              ],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search by phone number',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon:
                    _phone.text.isEmpty
                        ? null
                        : IconButton(
                          tooltip: 'Clear phone search',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => setState(() => _phone.clear()),
                        ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _chooseStatus,
                icon: const Icon(Icons.filter_list_rounded),
                label: Text('Status: ${_status.isEmpty ? 'All' : _status}'),
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              color: BrandColors.ink,
              onRefresh: () async {
                if (!_loading) await _loadLeads();
              },
              child:
                  _loading && _leads.isEmpty
                      ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: ClampingScrollPhysics(),
                        ),
                        children: const [
                          SizedBox(height: 180),
                          Center(child: AgPathLoadingIndicator()),
                        ],
                      )
                      : _error != null && _leads.isEmpty
                      ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: ClampingScrollPhysics(),
                        ),
                        padding: const EdgeInsets.all(24),
                        children: [
                          const SizedBox(height: 100),
                          const Icon(
                            Icons.error_outline_rounded,
                            size: 42,
                            color: Color(0xFFD95060),
                          ),
                          const SizedBox(height: 12),
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                        ],
                      )
                      : leads.isEmpty
                      ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: ClampingScrollPhysics(),
                        ),
                        children: [
                          SizedBox(height: 150),
                          Icon(
                            Icons.handshake_outlined,
                            size: 44,
                            color: Color(0xFF9AA5B3),
                          ),
                          SizedBox(height: 12),
                          Center(
                            child: Text(
                              _status.isNotEmpty || _phone.text.isNotEmpty
                                  ? 'No leads match the selected filters.'
                                  : 'You have not created any leads yet.',
                              style: TextStyle(color: Color(0xFF7F8998)),
                            ),
                          ),
                        ],
                      )
                      : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: ClampingScrollPhysics(),
                        ),
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                        itemCount: leads.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final lead = leads[index];
                          final title = _leadTitle(lead);
                          final subtitle = _leadSubtitle(lead);
                          return Card(
                            elevation: 0,
                            color: const Color(0xFFF6F8FB),
                            child: ListTile(
                              onTap:
                                  () => Navigator.of(context).push<void>(
                                    MaterialPageRoute<void>(
                                      builder:
                                          (_) => LeadDetailsPage(lead: lead),
                                    ),
                                  ),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              leading: const CircleAvatar(
                                backgroundColor: Color(0xFFEAF3FF),
                                child: Icon(
                                  Icons.person_outline_rounded,
                                  color: BrandColors.ink,
                                ),
                              ),
                              title: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              subtitle:
                                  subtitle.isEmpty
                                      ? null
                                      : Text(
                                        subtitle,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                            ),
                          );
                        },
                      ),
            ),
          ),
        ],
      ),
      floatingActionButton: brandFloatingActionButton(
        onPressed: _createLead,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New Lead'),
      ),
    );
    if (!widget.showOpportunities) return leadsPage;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: brandAppBar(
          leading: const HomeBackButton(color: Colors.white),
          title: const Text('My Leads'),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(56),
            child: Container(
              decoration: const BoxDecoration(gradient: BrandColors.gradient),
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: TabBar(
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicator: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  dividerColor: Colors.transparent,
                  labelColor: BrandColors.ink,
                  unselectedLabelColor: Colors.white,
                  labelStyle: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                  onTap:
                      (index) => setState(() {
                        _section = index;
                        if (index == 1) _opportunitiesOpened = true;
                      }),
                  tabs: const [
                    Tab(text: 'My Leads'),
                    Tab(text: 'My Opportunities'),
                  ],
                ),
              ),
            ),
          ),
        ),
        body: IndexedStack(
          index: _section,
          children: [
            leadsPage,
            if (_opportunitiesOpened)
              const MyOpportunitiesPage(embedded: true)
            else
              const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }
}
