# RESTRICTED Server Script. Script Type: Scheduler Event; Frequency: Cron.
# Cron Format: 0 13 * * * (daily 1:00 PM, site timezone Asia/Kolkata).
# Deploy the updated itgenie/fcm/fcm_utils.py with the sales-summary functions first.
# No new DocType and no Notification rule are required.
if frappe.session.user != "Administrator":
    frappe.throw("This script must run through the ERP scheduler.", frappe.PermissionError)

frappe.enqueue(
    "itgenie.fcm.fcm_utils.send_document_notification",
    queue="long",
    timeout=600,
    enqueue_after_commit=True,
)
