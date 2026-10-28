# Restricted Server Script. Script Type: API. API Method: mobile_fcm_notification.
# Allow Guest: disabled. No imports or custom functions.
# This is a bridge-invoked script, NOT a public send-message endpoint.
# Required custom-app integration (not implemented by this file): after Frappe
# evaluates the Notification trigger/condition, queue once after commit and use
# safe_exec(script.script, _locals={"fcm_trigger": {
#     "notification_name": rule.name, "doctype": doc.doctype,
#     "docname": doc.name, "context": get_context(doc),
# }}, script_filename=script.name).
# fcm_trigger must originate inside trusted app code, never HTTP form parameters.
# The generic, background-safe send_fcm_to_user implementation is also required.

try:
    trigger = fcm_trigger
except Exception:
    frappe.throw("This script must be invoked by the trusted FCM Notification bridge.")

if not isinstance(trigger, dict):
    frappe.throw("Invalid FCM Notification trigger context.")

for key in ["notification_name", "doctype", "docname"]:
    value = trigger.get(key)
    if not isinstance(value, str) or not value.strip() or len(value) > 140:
        frappe.throw("A valid " + key + " is required.")

notification = frappe.get_doc("Notification", trigger["notification_name"].strip())
result = {"status": "skipped", "sent": 0, "failed": 0, "skipped": 0}

# Other Notification channels never call the FCM sender.
if notification.get("enabled") and notification.get("channel") == "FCM":
    if notification.get("document_type") != trigger["doctype"].strip():
        frappe.throw("The Notification rule does not match the triggering DocType.")

    doc = frappe.get_doc(trigger["doctype"].strip(), trigger["docname"].strip())
    context = trigger.get("context")
    if not isinstance(context, dict):
        frappe.throw("The Notification bridge must provide its evaluated template context.")
    context = dict(context)
    context.update({"doc": doc, "alert": notification})

    title_template = notification.get("subject") or ""
    body_template = notification.get("message") or ""
    title = frappe.utils.strip_html_tags(frappe.render_template(title_template, context)).strip()
    body = frappe.utils.strip_html_tags(frappe.render_template(body_template, context)).strip()
    if not title:
        frappe.throw("Configure a Subject for this FCM rule.")
    if not body:
        frappe.throw("Configure a Message for this FCM rule.")

    # Reuse Frappe's recipient field/role/condition/assignee resolution.
    recipients, cc, bcc = notification.get_list_of_recipients(doc, context)
    candidates = []
    for value in recipients + cc + bcc:
        user = str(value or "").strip()
        if user and user != "Guest" and user not in candidates:
            candidates.append(user)

    enabled_users = []
    if candidates:
        users = frappe.get_all("User", filters={"name": ["in", candidates], "enabled": 1},
            fields=["name"], limit_page_length=0)
        enabled_users = [row.name for row in users]

    result["status"] = "processed"
    for user in candidates:
        # Document references/messages go only to enabled, authorized users.
        if user not in enabled_users or not doc.has_permission("read", user=user):
            result["skipped"] = result["skipped"] + 1
            continue

        payload = {
            "type": "DOCUMENT_NOTIFICATION",
            "notification_name": notification.name,
            "doctype": doc.doctype,
            "docname": doc.name,
            "assignment_id": "",
            "for_user": user,
            "title": title[:200],
            "body": body[:240],
        }
        # The generic sender must validate this dispatch and calculate
        # alarm_enabled from this recipient's Sales User/Designer roles itself.
        try:
            delivery = frappe.call("itgenie.fcm.fcm_utils.send_fcm_to_user",
                user=user, payload=payload)
            if isinstance(delivery, dict) and delivery.get("status") == "sent":
                result["sent"] = result["sent"] + 1
            else:
                result["failed"] = result["failed"] + 1
        except Exception:
            result["failed"] = result["failed"] + 1
            frappe.log_error(title="FCM Notification dispatch failed",
                message="Notification " + notification.name + "; " + doc.doctype + " " + doc.name)

# Do not overwrite the response of an API which created the business document.
frappe.flags.fcm_notification_result = result
