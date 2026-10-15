import 'package:flutter/material.dart';

import '../utils/theme/brand_theme.dart';
import '../utils/widget/home_back_button.dart';

/// Read-only details from the authenticated, owner-filtered Lead list.
class LeadDetailsPage extends StatelessWidget {
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
    'custom_product_enquired': 'Product Category',
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
  Widget build(BuildContext context) {
    final fields = _fields.entries.where(
      (field) => (lead[field.key]?.toString().trim() ?? '').isNotEmpty,
    );
    return Scaffold(
      appBar: brandAppBar(
        leading: const HomeBackButton(color: Colors.white),
        title: const Text('Lead Details'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final field in fields)
            Card(
              elevation: 0,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      field.value,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 6),
                    SelectableText(lead[field.key].toString().trim()),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
