"""Custom Frappe application Python, NOT a restricted Server Script.

Replace only register_device in apps/itgenie/itgenie/fcm/devices.py.
Keep all other functions/imports in that deployed module unchanged.
"""
import frappe
from frappe.utils import now_datetime


@frappe.whitelist()
def register_device(
    fcm_token=None,
    platform=None,
    device_id=None,
    app_version=None,
    build_version=None,
):
    user = frappe.session.user
    if not user or user == "Guest":
        frappe.throw("Login required", frappe.PermissionError)

    fcm_token = (fcm_token or "").strip()
    platform = (platform or "").strip().lower()
    if not fcm_token:
        frappe.throw("Missing FCM token")
    if platform not in ("android", "ios", "web"):
        frappe.throw("Platform must be android, ios or web")

    # FCM Device is named by Employee, which is also unique. Lock that
    # employee row so simultaneous login/token-refresh requests serialize,
    # including the first registration when no FCM Device exists yet.
    employee = frappe.db.get_value(
        "Employee", {"user_id": user}, "name", for_update=True,
    )
    if not employee:
        frappe.throw("No Employee is linked to the logged-in user")

    values = {
        "user": user,
        "employee": employee,
        "fcm_token": fcm_token,
        "platform": platform,
        "is_active": 1,
        "last_seen": now_datetime(),
        "device_id": device_id,
        "app_version": app_version,
        "build_version": build_version,
    }

    # The token can rotate; Employee is the stable identity of this DocType.
    existing_name = frappe.db.get_value(
        "FCM Device", {"employee": employee}, "name", for_update=True,
    )
    if existing_name:
        doc = frappe.get_doc("FCM Device", existing_name, for_update=True)
        for field, value in values.items():
            if value is not None:
                doc.set(field, value)
        doc.save(ignore_permissions=True)
    else:
        frappe.get_doc({"doctype": "FCM Device", **values}).insert(
            ignore_permissions=True,
        )

    # Frappe commits the successful POST transaction and releases row locks.
    return {"status": "success", "user": user}
