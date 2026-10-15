import '../utils/widget/ag_path_loading_indicator.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'package:flutter/material.dart';

import '../utils/api/lead_api.dart';
import '../utils/widget/home_back_button.dart';
import 'lead_creation_page.dart';
import 'lead_details_page.dart';

class MyLeadsPage extends StatefulWidget {
  const MyLeadsPage({super.key});

  @override
  State<MyLeadsPage> createState() => _MyLeadsPageState();
}

class _MyLeadsPageState extends State<MyLeadsPage> {
  List<Map<String, dynamic>> _leads = [];
  bool _loading = true;
  String? _error;

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
    return Scaffold(
      appBar: brandAppBar(
        leading: const HomeBackButton(color: Colors.white),
        title: const Text('My Leads'),
      ),
      body: RefreshIndicator(
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
                : _leads.isEmpty
                ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: ClampingScrollPhysics(),
                  ),
                  children: const [
                    SizedBox(height: 150),
                    Icon(
                      Icons.handshake_outlined,
                      size: 44,
                      color: Color(0xFF9AA5B3),
                    ),
                    SizedBox(height: 12),
                    Center(
                      child: Text(
                        'You have not created any leads yet.',
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
                  itemCount: _leads.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final lead = _leads[index];
                    final title = _leadTitle(lead);
                    final subtitle = _leadSubtitle(lead);
                    return Card(
                      elevation: 0,
                      color: const Color(0xFFF6F8FB),
                      child: ListTile(
                        onTap:
                            () => Navigator.of(context).push<void>(
                              MaterialPageRoute<void>(
                                builder: (_) => LeadDetailsPage(lead: lead),
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
                          style: const TextStyle(fontWeight: FontWeight.w700),
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
      floatingActionButton: brandFloatingActionButton(
        onPressed: _createLead,
        icon: const Icon(Icons.add_rounded),
        label: const Text('New Lead'),
      ),
    );
  }
}
