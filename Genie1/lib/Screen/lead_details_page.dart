import 'package:flutter/material.dart';
import '../utils/api/lead_api.dart';
import '../utils/api/opportunity_api.dart';
import '../utils/api/session_auth.dart';
import '../utils/widget/pull_to_refresh.dart';

import '../utils/theme/brand_theme.dart';
import '../utils/widget/home_back_button.dart';
import '../utils/widget/crm_document_details.dart';
import 'opportunity_details_page.dart';

/// Read-only details from the authenticated, owner-filtered Lead list.
class LeadDetailsPage extends StatefulWidget {
  LeadDetailsPage({super.key, required Map<String, dynamic> lead})
    : lead = Map<String, dynamic>.unmodifiable(lead);

  final Map<String, dynamic> lead;

  static const _fields = {
    'name': 'Lead ID',
    'lead_name': 'Lead Name',
    'first_name': 'Customer Name',
    'status': 'Status',
    'mobile_no': 'Mobile Number',
    'phone': 'Phone',
    'whatsapp_no': 'WhatsApp Number',
    'email_id': 'Email',
    'custom_requirement': 'Requirement',
    'custom_source': 'Lead Source',
    'source': 'Source',
    'custom_product_enquired': 'Product Enquired',
    'custom_address': 'Address',
    'custom_pincode': 'Pincode',
    'company_name': 'Company',
    'territory': 'Territory',
    'custom_sales_person': 'Sales Person',
    'custom_customer_category': 'Customer Category',
    'lead_owner': 'Lead Owner',
    'creation': 'Created On',
    'modified': 'Last Updated',
  };

  @override
  State<LeadDetailsPage> createState() => _LeadDetailsPageState();
}

class _LeadDetailsPageState extends State<LeadDetailsPage> {
  late Map<String, dynamic> lead = widget.lead;
  bool _refreshing = false;
  String? _creatorFullName;
  bool _openingOpportunity = false;

  Future<void> _openLinkedOpportunity() async {
    if (_openingOpportunity || _refreshing) return;
    setState(() => _openingOpportunity = true);
    try {
      final leadId = lead['name']?.toString() ?? '';
      var page = await OpportunityApi.getForLead(leadId);
      if (!mounted) return;
      setState(() => _openingOpportunity = false);
      if (page.isEmpty) {
        throw StateError(
          'No linked Opportunity is available for your account.',
        );
      }
      String? id;
      if (page.length == 1) {
        id = page.single['name'].toString();
      } else {
        var offset = 0;
        var loading = false;
        String? pageError;
        id = await showDialog<String>(
          context: context,
          builder:
              (dialogContext) => StatefulBuilder(
                builder: (context, update) {
                  Future<void> loadPage(int nextOffset) async {
                    if (loading) return;
                    update(() {
                      loading = true;
                      pageError = null;
                    });
                    try {
                      final next = await OpportunityApi.getForLead(
                        leadId,
                        offset: nextOffset,
                      );
                      if (!context.mounted) return;
                      update(() {
                        page = next;
                        offset = nextOffset;
                      });
                    } catch (error) {
                      if (context.mounted) {
                        update(
                          () =>
                              pageError = error.toString().replaceFirst(
                                'Bad state: ',
                                '',
                              ),
                        );
                      }
                    } finally {
                      if (context.mounted) update(() => loading = false);
                    }
                  }

                  return AlertDialog(
                    title: const Text('Choose Opportunity'),
                    content: SizedBox(
                      width: 360,
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (loading) const LinearProgressIndicator(),
                            if (pageError != null) Text(pageError!),
                            for (final item in page)
                              ListTile(
                                title: Text(item['name'].toString()),
                                subtitle: Text(
                                  item['customer_name']?.toString() ?? '',
                                ),
                                enabled: !loading,
                                onTap:
                                    () => Navigator.pop(
                                      dialogContext,
                                      item['name'].toString(),
                                    ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    actions: [
                      if (offset > 0)
                        TextButton(
                          onPressed:
                              loading
                                  ? null
                                  : () => loadPage(
                                    offset - OpportunityApi.pageSize,
                                  ),
                          child: const Text('Previous'),
                        ),
                      if (page.length == OpportunityApi.pageSize)
                        TextButton(
                          onPressed:
                              loading
                                  ? null
                                  : () => loadPage(
                                    offset + OpportunityApi.pageSize,
                                  ),
                          child: const Text('Next'),
                        ),
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Cancel'),
                      ),
                    ],
                  );
                },
              ),
        );
      }
      if (!mounted || id == null) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => OpportunityDetailsPage(opportunityId: id!),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Bad state: ', '')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _openingOpportunity = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _loadCreatorName();
  }

  Future<void> _loadCreatorName() async {
    final owner = lead['owner']?.toString().trim() ?? '';
    if (owner.isEmpty) return;
    try {
      final name = await SessionAuthApi.getUserFullName(owner);
      if (mounted && lead['owner'] == owner) {
        setState(() => _creatorFullName = name);
      }
    } catch (_) {
      // A missing full name must not prevent displaying existing Lead details.
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final updated = await LeadApi.getLeadDetails(lead['name'].toString());
      if (mounted) {
        setState(() {
          lead = updated;
          _creatorFullName = null;
        });
        await _loadCreatorName();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Bad state: ', '')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: CrmDocumentDetails.background,
    appBar: brandAppBar(
      leading: const HomeBackButton(color: Colors.white),
      title: const Text(
        'Lead Details',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    body: PullToRefresh(
      onRefresh: _refresh,
      enabled: !_refreshing,
      child: CrmDocumentDetails(
        document: lead,
        documentType: 'Lead',
        creatorFullName: _creatorFullName,
        fieldLabels: LeadDetailsPage._fields,
        refreshing: _refreshing,
        openingOpportunity: _openingOpportunity,
        onOpenOpportunity:
            lead['status']?.toString().trim().toLowerCase() == 'opportunity'
                ? _openLinkedOpportunity
                : null,
      ),
    ),
  );
}
