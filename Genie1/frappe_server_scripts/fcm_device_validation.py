# Restricted Frappe Server Script. No imports or custom functions.
# Script Type: DocType Event; Reference DocType: FCM Device; Event: Before Save.
# Permanent login validation runs in itgenie.mobile_auth BEFORE session creation.
# This hook preserves notification metadata ownership during document saves.

user = (doc.get("user") or "").strip()
device_id = (doc.get("device_id") or "").strip()

if not user:
    frappe.throw("User is required.")

# First login creates an inactive row before Firebase registers its device ID.
# Active notification registrations still require the device ID, as before.
if not device_id and doc.get("is_active"):
    frappe.throw("Device ID is required.")

if not doc.is_new():
    old_device = frappe.db.get_value(
        "FCM Device", doc.name, ["user", "employee", "device_id"], as_dict=True
    )
    if old_device:
        old_id = (old_device.get("device_id") or "").strip()
        if (
            old_device.get("user") != user
            or old_device.get("employee") != doc.get("employee")
            or (old_id and old_id != device_id)
        ):
            frappe.throw("Wrong User", title="Device Verification Failed")

if device_id:
    registered_devices = frappe.get_all(
        "FCM Device",
        filters={"user": user, "name": ["!=", doc.name], "device_id": ["is", "set"]},
        fields=["device_id"], order_by="creation asc", limit_page_length=1,
    )
    if registered_devices:
        registered_id = (registered_devices[0].get("device_id") or "").strip()
        if registered_id and registered_id != device_id:
            frappe.throw("Wrong User", title="Device Verification Failed")

    if frappe.db.exists("FCM Device", {"device_id": device_id, "user": ["!=", user]}):
        frappe.throw("Wrong User", title="Device Verification Failed")
