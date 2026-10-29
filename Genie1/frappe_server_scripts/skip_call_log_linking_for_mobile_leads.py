# Configure this as a separate Frappe Server Script:
#   Script Type: DocType Event
#   Reference Document Type: Contact
#   Event: Before Insert
#   Disabled: unchecked
#
# Lead creation through this API still creates its Contact. This flag only
# skips relinking all historical Call Logs to that newly-created Contact.

# Contacts are also inserted outside HTTP requests (background jobs, data
# import), where Safe Exec exposes no request or only a request dictionary.
request = frappe.request
request_path = ""
if isinstance(request, dict):
    request_path = request.get("path") or ""
elif request:
    request_path = request.path or ""
if "create_lead_from_mobile" in request_path:
    doc.flags.ignore_auto_link_call_log = True
