# Frappe Server Script settings:
#   Script Type: DocType Event
#   Reference DocType: Employee Checkin
#   DocType Event: After Insert
#
# Install together with mobile_face_employee_checkin_guard. It attaches the
# consumed receipt to the Checkin name. No attendance image is stored or attached.

command = str(frappe.form_dict.get("cmd") or "")
if command.endswith(".checkin") or command.endswith(".checkout"):
    include_timings = frappe.form_dict.get("include_timings") in [True, 1, "1", "true"]
    attach_started = frappe.utils.now_datetime() if include_timings else None
    current_user = frappe.session.user
    if not current_user or current_user == "Guest":
        frappe.throw("Sign in before checking in or out.")
    # Use the same server-side policy as the Before Insert guard.
    employee_record = frappe.db.get_value(
        "Employee", doc.employee, ["user_id", "department"], as_dict=True,
    )
    user_email = str(frappe.db.get_value("User", current_user, "email") or "").strip().lower()
    email_local_part = user_email.split("@", 1)[0] if "@" in user_email else ""
    face_required = (
        employee_record
        and employee_record.user_id == current_user
        and (".trainee" in email_local_part or ".itdigital" in email_local_part)
        and employee_record.department == "IT And Digital - HBPPL"
    )
    if face_required:
        record_id = frappe.form_dict.get("face_verification")
        if not isinstance(record_id, str):
            frappe.throw("The face verification receipt is missing.")
        record_id = record_id.strip()
        if not record_id:
            frappe.throw("The face verification receipt is missing.")
        record = frappe.get_doc("Comment", record_id)
        if (
            record.owner != "Administrator"
            or record.comment_type != "Info"
            or record.subject != "Genie Face Verification v1"
            or record.reference_doctype != "User"
            or record.reference_name != current_user
        ):
            frappe.throw("The face verification does not belong to your account.")
        try:
            metadata = json.loads(record.content or "{}")
        except Exception:
            frappe.throw("The face verification is invalid. Scan again.")
        if (
            not isinstance(metadata, dict)
            or metadata.get("current_user") != current_user
            or metadata.get("used") is not True
            or metadata.get("used_for_doctype") != "Employee Checkin"
            or metadata.get("event")
            or metadata.get("action")
            != ("attendance_in" if command.endswith(".checkin") else "attendance_out")
        ):
            frappe.throw("The face verification does not belong to this check-in.")
        if metadata.get("version") != 2 or metadata.get("evidence_file") or metadata.get("photo_url"):
            frappe.throw("The face receipt format has changed. Update the app and scan again.")
        if metadata.get("used_for_name"):
            frappe.throw("The face verification is already linked to attendance.")
        metadata["used_for_name"] = doc.name
        record.content = json.dumps(metadata).replace("&", "\\u0026").replace("<", "\\u003c").replace(">", "\\u003e")
        record.save(ignore_permissions=True)
        if include_timings:
            timings = frappe.response.get("attendance_timings_ms") or {}
            timings["attach_total"] = max(0, round(frappe.utils.time_diff_in_seconds(
                frappe.utils.now_datetime(), attach_started
            ) * 1000, 3))
            frappe.response["attendance_timings_ms"] = timings
