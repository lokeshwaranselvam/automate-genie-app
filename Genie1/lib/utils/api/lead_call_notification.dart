/// Data-only payload emitted by itgenie.lead_calling.fcm_trigger.
class LeadCallNotification {
  const LeadCallNotification({
    required this.doctype,
    required this.docname,
    required this.customerName,
    required this.phone,
  });

  final String doctype;
  final String docname;
  final String customerName;
  final String phone;

  String get title => 'New ${doctype.toLowerCase()} assigned';
  String get body => '$customerName ? $phone. Tap to call.';
  Uri get dialUri => Uri(scheme: 'tel', path: phone);

  static LeadCallNotification? fromData(Map<String, dynamic> data) {
    if (data['type'] != 'NEW_LEAD_CALL') return null;
    final doctype = data['doctype']?.toString() ?? '';
    final docname = data['docname']?.toString().trim() ?? '';
    if (!const ['Lead', 'Opportunity'].contains(doctype) || docname.isEmpty) {
      return null;
    }
    final raw = data['mobile_no']?.toString().trim() ?? '';
    if (raw.length > 64 || !RegExp(r'^\+?[0-9 ().-]+$').hasMatch(raw)) {
      return null;
    }
    final phone = raw.replaceAll(RegExp(r'[ ().-]'), '');
    if (!RegExp(r'^\+?[0-9]{7,15}$').hasMatch(phone)) return null;
    final customer = data['customer_name']?.toString().trim() ?? '';
    return LeadCallNotification(
      doctype: doctype,
      docname: docname,
      customerName: customer.isEmpty ? docname : customer,
      phone: phone,
    );
  }
}
