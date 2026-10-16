import 'package:flutter/material.dart';
import '../utils/api/lead_api.dart';
import '../utils/widget/pull_to_refresh.dart';

import '../utils/theme/brand_theme.dart';
import '../utils/widget/home_back_button.dart';
import '../utils/widget/crm_document_details.dart';

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

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final updated = await LeadApi.getLeadDetails(lead['name'].toString());
      if (mounted) setState(() => lead = updated);
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
      actions: [
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: Colors.white),
          tooltip: 'More options',
          onSelected: (_) => _refresh(),
          itemBuilder:
              (_) => [
                PopupMenuItem(
                  value: 'refresh',
                  enabled: !_refreshing,
                  child: const Text('Refresh'),
                ),
              ],
        ),
      ],
    ),
    body: PullToRefresh(
      onRefresh: _refresh,
      enabled: !_refreshing,
      child: CrmDocumentDetails(
        document: lead,
        documentType: 'Lead',
        fieldLabels: LeadDetailsPage._fields,
        refreshing: _refreshing,
      ),
    ),
  );
}
