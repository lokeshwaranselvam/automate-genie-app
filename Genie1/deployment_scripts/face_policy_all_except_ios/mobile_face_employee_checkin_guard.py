# Frappe Server Script settings:
#   Script Type: DocType Event
#   Reference DocType: Employee Checkin
#   DocType Event: Before Insert
#   Allow Guest: Disabled
#
# Install with the paired shutter-capable mobile_face_auth API. Existing
# APK blink receipts remain valid; FaceRes shutter receipts record no blink.
# This
# protects the existing *.checkin / *.checkout methods when they use normal
# Employee Checkin.insert(). It leaves ERP Desk/manual/import flows unchanged.
# Methods using direct DB writes must call equivalent validation themselves.
# The receipt verifies submission/audit linkage, not a client AI assertion.

command = str(frappe.form_dict.get("cmd") or "")
expected_action = None
expected_log_type = None
if command.endswith(".checkin"):
    expected_action = "attendance_in"
    expected_log_type = "IN"
elif command.endswith(".checkout"):
    expected_action = "attendance_out"
    expected_log_type = "OUT"

if expected_action:
    include_timings = frappe.form_dict.get("include_timings") in [True, 1, "1", "true"]
    guard_started = frappe.utils.now_datetime() if include_timings else None
    current_user = frappe.session.user
    if not current_user or current_user == "Guest":
        frappe.throw("Sign in before checking in or out.")
    employee_record = frappe.db.get_value(
        "Employee", doc.employee, ["user_id", "department"], as_dict=True,
    )
    if not employee_record or employee_record.user_id != current_user or doc.log_type != expected_log_type:
        frappe.throw("The attendance employee or action does not match your face scan.")
    # Only the exact IOS User role exempts the authenticated user.
    face_required = not bool(frappe.db.exists("Has Role", {
        "parent": current_user, "parenttype": "User", "parentfield": "roles",
        "role": ["in", ["IOS User", "System Manager"]],
    }))
    if face_required:
        record_id = frappe.form_dict.get("face_verification")
        if not isinstance(record_id, str):
            frappe.throw("Complete face verification before checking in or out.")
        record_id = record_id.strip()
        if not record_id or not frappe.db.exists("Comment", record_id):
            frappe.throw("Complete face verification before checking in or out.")
        # DB row lock is held until the existing attendance transaction completes;
        # a second request cannot consume this receipt concurrently.
        lock_started = frappe.utils.now_datetime() if include_timings else None
        record = frappe.get_doc("Comment", record_id, for_update=True)
        if include_timings:
            lock_ms = max(0, frappe.utils.time_diff_in_seconds(
                frappe.utils.now_datetime(), lock_started
            ) * 1000)
        if (
            record.owner != "Administrator" or record.comment_type != "Info"
            or record.subject != "Genie Face Verification v1"
            or record.reference_doctype != "User" or record.reference_name != current_user
        ):
            frappe.throw("The face verification does not belong to your account.")
        try:
            metadata = json.loads(record.content or "{}")
        except Exception:
            frappe.throw("The face verification is invalid. Scan again.")
        age = frappe.utils.time_diff_in_seconds(frappe.utils.now(), record.creation)
        if not isinstance(metadata, dict) or metadata.get("used") or not 0 <= age <= 120:
            frappe.throw("The face verification was used or expired. Scan again.")
        model_thresholds = {
            "opencv-sface-2021dec-v1": 0.5,
            "opencv-sface-2021dec-int8bq-v1": 0.5,
            "human-faceres-fivepoint-rgb-1024-v1": 0.65,
        }
        receipt_model = metadata.get("model_version")
        if not isinstance(receipt_model, str) or receipt_model not in model_thresholds:
            frappe.throw("The face verification does not match this attendance action.")
        minimum_similarity = model_thresholds[receipt_model]
        capture_mode = metadata.get("capture_mode") or "blink"
        capture_valid = (
            (capture_mode == "blink" and metadata.get("blink_completed") is True)
            or (capture_mode == "shutter"
                and receipt_model == "human-faceres-fivepoint-rgb-1024-v1"
                and metadata.get("blink_completed") is False)
        )
        if (
            metadata.get("current_user") != current_user or metadata.get("action") != expected_action
            or metadata.get("event")
            or not capture_valid
            or not minimum_similarity <= frappe.utils.flt(metadata.get("similarity")) <= 1
        ):
            frappe.throw("The face verification does not match this attendance action.")
        reference_id = "GENIE-FACE-REF-" + frappe.utils.sha256_hash(current_user)[:32]
        reference = frappe.db.get_value(
            "File", reference_id, ["owner", "is_private", "attached_to_doctype", "attached_to_name", "content_hash"], as_dict=True,
        )
        if (
            not reference or reference.owner != current_user or not reference.is_private
            or reference.attached_to_doctype != "User" or reference.attached_to_name != current_user
            or metadata.get("reference_file") != reference_id
            or metadata.get("reference_version") != (reference.content_hash or reference_id)
        ):
            frappe.throw("Your face reference has changed. Scan again.")
        if metadata.get("version") != 2 or metadata.get("evidence_file") or metadata.get("photo_url"):
            frappe.throw("The face receipt format has changed. Update the app and scan again.")
        metadata["used"] = True
        metadata["used_on"] = frappe.utils.now()
        metadata["used_for_doctype"] = "Employee Checkin"
        record.content = json.dumps(metadata).replace("&", "\\u0026").replace("<", "\\u003c").replace(">", "\\u003e")
        record.save(ignore_permissions=True)
        if include_timings:
            timings = frappe.response.get("attendance_timings_ms") or {}
            timings["receipt_lock"] = round(lock_ms, 3)
            timings["guard_total"] = max(0, round(frappe.utils.time_diff_in_seconds(
                frappe.utils.now_datetime(), guard_started
            ) * 1000, 3))
            frappe.response["attendance_timings_ms"] = timings
