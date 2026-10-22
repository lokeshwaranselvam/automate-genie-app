import 'package:flutter/material.dart';

import '../theme/brand_theme.dart';
import '../opportunity_contact.dart';

/// Shared read-only presentation. Uses only the document already loaded.
class CrmDocumentDetails extends StatelessWidget {
  const CrmDocumentDetails({
    super.key,
    required this.document,
    required this.documentType,
    this.fieldLabels = const {},
    this.refreshing = false,
    this.onCallContact,
    this.callInProgress = false,
    this.onEditOpportunity,
    this.creatorFullName,
  });

  final Map<String, dynamic> document;
  final String documentType;
  final Map<String, String> fieldLabels;
  final bool refreshing;
  final ValueChanged<String>? onCallContact;
  final bool callInProgress;
  final VoidCallback? onEditOpportunity;
  final String? creatorFullName;

  static const background = Color(0xFFF3F7FC);
  static const _ink = Color(0xFF101A36);
  static const _muted = Color(0xFF66738C);
  static const _internal = {
    'doctype',
    'parent',
    'parenttype',
    'parentfield',
    'idx',
  };
  static const _audit = ['owner', 'creation', 'modified', 'modified_by'];
  static const _document = ['docstatus', 'naming_series'];
  static const _contact = [
    'contact_person',
    'job_title',
    'contact_email',
    'email_id',
    'contact_mobile',
    'mobile_no',
    'phone',
    'phone_ext',
    'whatsapp_no',
    'whatsapp',
    'contact_display',
    'contact_html',
  ];
  static const _address = [
    'custom_address',
    'address_display',
    'address_html',
    'customer_address',
    'territory',
    'city',
    'state',
    'country',
    'custom_pincode',
    'pincode',
  ];
  static const _valueFields = [
    'company',
    'currency',
    'conversion_rate',
    'opportunity_amount',
    'base_opportunity_amount',
    'base_total',
    'total',
    'annual_revenue',
  ];
  static const _information = [
    'opportunity_from',
    'party_name',
    'customer_name',
    'lead_name',
    'first_name',
    'middle_name',
    'last_name',
    'company_name',
    'opportunity_type',
    'source',
    'custom_source',
    'opportunity_owner',
    'lead_owner',
    'sales_stage',
    'expected_closing',
    'probability',
    'custom_requirement',
    'custom_product_enquired',
    'custom_customer_category',
    'custom_sales_person',
  ];

  bool _present(dynamic value) =>
      value != null &&
      value.toString().trim().isNotEmpty &&
      !(value is List && value.isEmpty);

  String _label(String key) {
    const labels = {
      'owner': 'Created By',
      'creation': 'Creation',
      'modified': 'Modified',
      'modified_by': 'Modified By',
      'docstatus': 'Docstatus',
      'naming_series': 'Naming Series',
      'name': 'ID',
      'email_id': 'Email',
      'contact_email': 'Contact Email',
    };
    if (labels.containsKey(key)) return labels[key]!;
    if (fieldLabels.containsKey(key)) return fieldLabels[key]!;
    return key
        .replaceFirst(RegExp(r'^custom_'), '')
        .split('_')
        .map(
          (word) =>
              word.isEmpty
                  ? word
                  : '${word[0].toUpperCase()}${word.substring(1)}',
        )
        .join(' ');
  }

  IconData _icon(String key) {
    if (key.contains('creation') ||
        key.contains('modified') && !key.endsWith('_by') ||
        key.contains('date') ||
        key.contains('closing')) {
      return Icons.calendar_today_outlined;
    }
    if (key == 'owner' ||
        key.endsWith('_by') ||
        key.contains('owner') ||
        key.contains('person')) {
      return Icons.person_outline_rounded;
    }
    if (key.contains('whatsapp')) return Icons.chat_bubble_outline_rounded;
    if (key.contains('phone') || key.contains('mobile')) {
      return Icons.phone_outlined;
    }
    if (key.contains('email')) return Icons.mail_outline_rounded;
    if (key.contains('address') ||
        key == 'territory' ||
        key == 'city' ||
        key == 'country' ||
        key.contains('pincode')) {
      return Icons.location_on_outlined;
    }
    if (key.contains('amount') ||
        key.contains('total') ||
        key.contains('revenue') ||
        key == 'currency') {
      return Icons.payments_outlined;
    }
    if (key == 'naming_series') return Icons.settings_outlined;
    if (key == 'party_name' || key.contains('company')) {
      return Icons.apartment_rounded;
    }
    if (key == 'opportunity_from') return Icons.track_changes_rounded;
    return Icons.description_outlined;
  }

  Color _accent(String key) {
    if (key == 'creation' || key == 'opportunity_from') {
      return const Color(0xFF27994D);
    }
    if (key == 'modified_by') return const Color(0xFFE58B2A);
    if (key == 'docstatus') return const Color(0xFFE45170);
    if (key == 'owner' || key == 'naming_series') {
      return BrandColors.electricBlue;
    }
    return BrandColors.ink;
  }

  Widget _iconBadge(IconData icon, Color accent, {double size = 34}) =>
      Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.09),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: accent, size: size * 0.56),
      );

  Widget _surface(Widget child) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      boxShadow: const [
        BoxShadow(
          color: Color(0x080E2651),
          blurRadius: 18,
          offset: Offset(0, 5),
        ),
      ],
    ),
    child: child,
  );

  Widget _summary(BuildContext context) {
    final status = document['status']?.toString().trim() ?? '';
    final source =
        document[documentType == 'Opportunity'
                ? 'opportunity_from'
                : 'custom_source']
            ?.toString()
            .trim() ??
        '';
    final statusColor = switch (status.toLowerCase()) {
      'open' ||
      'converted' ||
      'qualified' ||
      'replied' => const Color(0xFF298E2C),
      'lost' || 'do not contact' || 'not interested' => const Color(0xFFD44C62),
      _ => BrandColors.ink,
    };
    final identity = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 42,
          height: 52,
          decoration: BoxDecoration(
            color: BrandColors.purple.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            documentType == 'Opportunity'
                ? Icons.workspace_premium_rounded
                : Icons.person_outline_rounded,
            color: BrandColors.ink,
            size: 31,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${documentType.toUpperCase()} ID',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: _muted,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                document['name']?.toString() ?? '',
                style: const TextStyle(
                  fontSize: 16,
                  height: 1.15,
                  fontWeight: FontWeight.w800,
                  color: _ink,
                ),
              ),
              if (source.isNotEmpty) ...[
                const SizedBox(height: 7),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF3FF),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'From $source',
                    style: const TextStyle(
                      fontSize: 11,
                      color: BrandColors.electricBlue,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
    final statusWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'STATUS',
          style: TextStyle(
            fontSize: 10,
            color: _muted,
            letterSpacing: 1.1,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 7),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Text(
            '●  $status',
            softWrap: true,
            style: TextStyle(
              color: statusColor,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
    return _surface(
      Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (status.isEmpty) return identity;
            if (constraints.maxWidth < 280 ||
                MediaQuery.textScalerOf(context).scale(1) > 1.35) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [identity, const SizedBox(height: 14), statusWidget],
              );
            }
            return Row(
              children: [
                Expanded(child: identity),
                Container(
                  width: 1,
                  height: 58,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  color: const Color(0xFFE1E7F0),
                ),
                Flexible(
                  flex: 0,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 100),
                    child: statusWidget,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _renderValue(dynamic value) {
    if (value is List) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < value.length; i++)
            if (value[i] is Map)
              ExpansionTile(
                key: PageStorageKey('crm_row_$i'),
                title: Text(
                  'Row ${i + 1}',
                  style: const TextStyle(fontSize: 13),
                ),
                tilePadding: EdgeInsets.zero,
                children: [
                  for (final entry in (value[i] as Map).entries)
                    if (!_internal.contains(entry.key) &&
                        !entry.key.toString().startsWith('_') &&
                        _present(entry.value))
                      _field(entry.key.toString(), entry.value),
                ],
              )
            else
              SelectableText(value[i].toString()),
        ],
      );
    }
    if (value is Map) {
      return Column(
        children: [
          for (final entry in value.entries)
            if (!_internal.contains(entry.key) &&
                !entry.key.toString().startsWith('_') &&
                _present(entry.value))
              _field(entry.key.toString(), entry.value),
        ],
      );
    }
    final text = value
        .toString()
        .replaceAll(
          RegExp(r'<br\s*/?>|</p>|</div>', caseSensitive: false),
          '\n',
        )
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&');
    return SelectableText(
      text.trim(),
      style: const TextStyle(fontSize: 13, color: _ink, height: 1.4),
    );
  }

  dynamic _visibleValue(String key, dynamic value) {
    if (documentType != 'Opportunity' || key != 'notes' || value is! List) {
      return value;
    }
    // Sort a separate view; editing must still receive the complete notes list.
    final notes =
        value.indexed.map((entry) {
          final row = entry.$2;
          final created =
              row is Map
                  ? DateTime.tryParse(row['added_on']?.toString() ?? '') ??
                      DateTime.tryParse(row['creation']?.toString() ?? '')
                  : null;
          return (row: row, created: created, index: entry.$1);
        }).toList();
    notes.sort((a, b) {
      if (a.created != null && b.created != null) {
        final order = b.created!.compareTo(a.created!);
        if (order != 0) return order;
      } else if (a.created != null || b.created != null) {
        return a.created != null ? -1 : 1;
      }
      return b.index.compareTo(a.index);
    });
    return notes.take(3).map((entry) => entry.row).toList();
  }

  Widget _field(String key, dynamic value) => Padding(
    key: PageStorageKey('crm_field_$key'),
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _iconBadge(_icon(key), _accent(key)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _label(key),
                style: const TextStyle(
                  fontSize: 13,
                  color: _muted,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 3),
              _renderValue(_visibleValue(key, value)),
            ],
          ),
        ),
        if (documentType == 'Opportunity' &&
            onCallContact != null &&
            OpportunityContact.isPhoneField(key) &&
            OpportunityContact.number(value).isNotEmpty)
          IconButton(
            tooltip: 'Call ${OpportunityContact.number(value)}',
            onPressed:
                callInProgress
                    ? null
                    : () => onCallContact!(OpportunityContact.number(value)),
            color: BrandColors.ink,
            icon: const Icon(Icons.call_rounded),
          ),
      ],
    ),
  );

  Widget _section(String title, IconData icon, List<String> keys) => _surface(
    ExpansionTile(
      key: PageStorageKey('crm_${documentType}_$title'),
      initiallyExpanded: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 3),
      childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      shape: const Border(),
      collapsedShape: const Border(),
      leading: _iconBadge(icon, BrandColors.ink),
      iconColor: const Color(0xFF586785),
      collapsedIconColor: const Color(0xFF586785),
      title: Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: _ink,
        ),
      ),
      children: [
        for (var i = 0; i < keys.length; i++) ...[
          if (i > 0) const Divider(height: 1, color: Color(0xFFE1E7F0)),
          _field(
            keys[i],
            (documentType == 'Opportunity' || documentType == 'Lead') &&
                    keys[i] == 'owner'
                ? creatorFullName ?? 'Full name unavailable'
                : document[keys[i]],
          ),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final remaining =
        document.keys
            .where(
              (key) =>
                  !key.startsWith('_') &&
                  !_internal.contains(key) &&
                  key != 'name' &&
                  key != 'status' &&
                  _present(document[key]),
            )
            .toSet();
    final sections = <Widget>[];
    if (documentType == 'Opportunity') {
      remaining.removeAll(_document);
      remaining.removeAll(_valueFields.skip(2));
      remaining.removeAll(_audit.skip(1));
    }
    if (documentType == 'Lead') {
      remaining.removeAll(_document);
      remaining.removeAll(_audit.skip(1));
    }
    void add(String title, IconData icon, List<String> fields) {
      final keys = fields.where(remaining.contains).toList();
      remaining.removeAll(keys);
      if (keys.isNotEmpty) sections.add(_section(title, icon, keys));
    }

    add('Audit Information', Icons.description_rounded, _audit);
    add('Document Information', Icons.description_rounded, _document);
    String fieldKind(String key) => key
        .replaceFirst(RegExp(r'^custom_'), '')
        .toLowerCase()
        .replaceAll(RegExp('[^a-z]'), '');
    add('$documentType Information', Icons.pie_chart_rounded, [
      ..._information,
      if (documentType == 'Opportunity')
        ...remaining.where((key) => fieldKind(key) == 'nextfollowupdate'),
    ]);
    add(
      'Contact Information',
      Icons.contact_phone_outlined,
      {
        ..._contact,
        if (documentType == 'Opportunity')
          for (final key in document.keys)
            if (OpportunityContact.isPhoneField(key)) key,
      }.toList(),
    );
    add('Address Information', Icons.location_on_outlined, _address);
    add('Value & Company', Icons.payments_outlined, _valueFields);
    final tables = remaining.where((key) => document[key] is List).toList();
    add(
      'Additional Information',
      Icons.info_outline_rounded,
      documentType == 'Opportunity'
          ? [
            for (final kind in ['customertype', 'citytown', 'district'])
              ...remaining.where(
                (key) => fieldKind(key) == kind && !tables.contains(key),
              ),
          ]
          : remaining.where((key) => !tables.contains(key)).toList(),
    );
    for (final key in tables) {
      add(_label(key), Icons.table_rows_outlined, [key]);
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
      children: [
        if (refreshing) const LinearProgressIndicator(minHeight: 2),
        _summary(context),
        if (documentType == 'Opportunity' && onEditOpportunity != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: refreshing ? null : onEditOpportunity,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Edit status, notes & follow-up'),
            ),
          ),
        ...sections,
      ],
    );
  }
}
