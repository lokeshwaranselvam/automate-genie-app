"""Custom Frappe application Python, NOT a restricted Server Script.

Replace only register_device in apps/itgenie/itgenie/lead_calling/mobile_api.py.
Keep all other functions/imports in that deployed module unchanged.
The existing FCM Device schema stores one employee-keyed record per employee.
"""
import frappe


@frappe.whitelist()
def register_device(
    fcm_token,
    device_id=None,
    platform="android",
    app_version=None,
    build_version=None,
):
    user = frappe.session.user
    if not user or user == "Guest":
        frappe.throw("Login required", frappe.PermissionError)

    fcm_token = (fcm_token or "").strip()
    platform = (platform or "android").strip().lower()
    if not fcm_token:
        frappe.throw("Missing FCM token")
    if platform not in ("android", "ios"):
        frappe.throw("Platform must be android or ios")
    try:
        build_version = int(build_version or 0)
    except (TypeError, ValueError):
        frappe.throw("Invalid build version")

    # Serialize this employee's registrations, including the first insert.
    # Frappe holds the row lock until this POST commits or rolls back.
    employee = frappe.db.get_value(
        "Employee", {"user_id": user}, "name", for_update=True,
    )
    if not employee:
        frappe.throw("No Employee is linked to the logged-in user")

    # Login may already have created an inactive Android-labelled record.
    # A browser can send another platform/token/device ID; these are not the
    # identity of the employee-keyed FCM Device record.
    existing = frappe.db.get_value(
        "FCM Device", {"employee": employee}, ["name", "user"],
        as_dict=True, for_update=True,
    )
    if existing and existing.get("user") != user:
        frappe.throw("FCM Device belongs to another user", frappe.PermissionError)

    data = {
        "user": user,
        "employee": employee,
        "fcm_token": fcm_token,
        "device_id": device_id,
        "platform": platform,
        "is_active": 1,
        "last_seen": frappe.utils.now(),
        "app_version": app_version,
        "build_version": build_version,
    }

    if existing:
        name = existing["name"]
        # Keep the deployed function's existing metadata update behavior.
        # Only the fields above change; login binding fields are untouched.
        frappe.db.set_value("FCM Device", name, data)
    else:
        doc = frappe.get_doc({"doctype": "FCM Device", **data})
        doc.insert(ignore_permissions=True)
        name = doc.name

    frappe.db.commit()
    return {
        "status": "success", "device": name,
        "app_version": app_version, "build_version": build_version,
    }
