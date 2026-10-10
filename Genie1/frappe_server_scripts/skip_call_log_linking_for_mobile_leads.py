# Configure this as a separate Frappe Server Script:
#   Script Type: DocType Event
#   Reference Document Type: Contact
#   Event: Before Insert
#   Disabled: unchecked
#
# Lead creation through this API still creates its Contact. This flag only
# skips relinking all historical Call Logs to that newly-created Contact.

if "create_lead_from_mobile" in frappe.request.path:
    doc.flags.ignore_auto_link_call_log = True
