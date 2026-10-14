# Frappe Server Script settings:
#   Script Type: API
#   API Method: mobile_face_auth
#   Allow Guest: Disabled
#   Enable Rate Limit: Enabled (for example, 60 requests per minute)
#
# GET  ?action=status
# POST JSON action=enroll, image_base64, csrf_token, model_version, blink_completed
# POST JSON action=record_verification, csrf_token,
#   reference_file, reference_version, attendance verification_action,
#   model_version, similarity, blink_completed, latitude, longitude, captured_on
#
# This script stores the first live selfie on the authenticated User and
# records DEVICE-REPORTED matching. Server Scripts cannot run the on-device
# recognition model or establish that a modified client really blinked.
# Only the enrollment photo is stored. Attendance sends matching metadata,
# never a selfie image. Enrollment is immediate; the account holder chooses the face.
# No imports, extra DocTypes, request.files, or unsupported cache APIs are used.

current_user = frappe.session.user
if not current_user or current_user == "Guest":
    frappe.throw("Sign in before registering or verifying your face.")

action = (frappe.form_dict.get("action") or "status").strip().lower()
# The mobile app initializes this token by loading /app with the same sid
# session when it is missing. Server Script safe_exec exposes the session token
# as frappe.session.csrf_token, but does not expose token-generation functions.
csrf_token = frappe.session.get("csrf_token") or frappe.session.data.csrf_token
reference_name = "GENIE-FACE-REF-" + frappe.utils.sha256_hash(current_user)[:32]
model_version = "opencv-sface-2021dec-v1"
# Starting threshold for the selected SFace model; evaluate and calibrate with
# the actual phone fleet before rollout. This is a similarity, not confidence.
minimum_similarity = 0.5
max_jpeg_bytes = 2 * 1024 * 1024
include_timings = frappe.form_dict.get("include_timings") in [True, 1, "1", "true"]
timings = {}


def timing_start():
    return frappe.utils.now_datetime() if include_timings else None


def timing_end(stage, started):
    if include_timings:
        timings[stage] = max(0, round(frappe.utils.time_diff_in_seconds(
            frappe.utils.now_datetime(), started
        ) * 1000, 3))


def reference_file():
    row = frappe.db.get_value(
        "File", reference_name,
        ["name", "owner", "is_private", "attached_to_doctype", "attached_to_name",
         "file_url", "content_hash", "file_name"], as_dict=True,
    )
    if not row:
        return None
    if (
        row.owner != current_user or not row.is_private
        or row.attached_to_doctype != "User"
        or row.attached_to_name != current_user
        or not (row.file_url or "").startswith("/private/files/")
    ):
        frappe.throw("Your face reference is invalid. Contact your administrator.")
    return {
        "name": row.name, "url": row.file_url,
        "version": row.content_hash or row.name,
    }


def require_csrf():
    # Some Frappe safe_exec versions do not expose the HTTP method. Requiring
    # the session token in the form also prevents a GET action from bypassing
    # the framework's POST-only CSRF validation. Flutter sends a POST plus the
    # normal X-Frappe-CSRF-Token header and this explicit body value.
    if not csrf_token or frappe.form_dict.get("csrf_token") != csrf_token:
        frappe.throw("Your session token has changed. Reload and try again.")


def jpeg_file(filename, attached_doctype=None, attached_name=None):
    encoded = frappe.form_dict.get("image_base64")
    if not isinstance(encoded, str) or not encoded:
        frappe.throw("A live selfie JPEG is required.")
    # Limit before decoding so oversized JSON cannot cause a large allocation.
    if len(encoded) > ((max_jpeg_bytes + 2) // 3) * 4:
        frappe.throw("The selfie must be smaller than 2 MB.")
    # strip removes only allowed characters at either end. Any invalid
    # character (including one in the middle) leaves a nonempty remainder.
    # This keeps the same alphabet check without a sandboxed Python loop.
    if len(encoded) % 4 or encoded.strip(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
    ):
        frappe.throw("The selfie encoding is invalid.")
    file_doc = frappe.get_doc({
        "doctype": "File", "file_name": filename, "is_private": 1,
        "folder": "Home/Attachments", "content": encoded, "decode": True,
        "attached_to_doctype": attached_doctype,
        "attached_to_name": attached_name,
    })
    try:
        content = file_doc.get_content()
    except Exception:
        frappe.throw("The selfie encoding is invalid.")
    if not isinstance(content, bytes):
        frappe.throw("ERP did not decode the selfie into binary JPEG data.")
    if not content or len(content) > max_jpeg_bytes:
        frappe.throw("The selfie must be a nonempty JPEG smaller than 2 MB.")
    if not content.startswith(b"\xff\xd8\xff") or not content.endswith(b"\xff\xd9"):
        frappe.throw("The selfie must be a JPEG image.")
    # Reuse the exact bytes just validated; File.insert still runs its normal
    # validation, storage, hashing, permission and rollback hooks.
    file_doc.content = content
    file_doc.decode = False
    return file_doc


if action == "status":
    reference = reference_file()
    frappe.response["message"] = {
        "status": "success", "current_user": current_user,
        "enrolled": bool(reference), "reference_file": reference,
        "model_version": model_version, "minimum_similarity": minimum_similarity,
        "csrf_token": csrf_token, "verification_receipt_version": 2,
    }

elif action == "enroll":
    require_csrf()
    if frappe.form_dict.get("model_version") != model_version:
        frappe.throw("The face model has changed. Update the app before registering.")
    if frappe.form_dict.get("blink_completed") not in [True, 1, "1", "true"]:
        frappe.throw("Complete the live blink scan before registering your face.")
    reference = reference_file()
    if reference:
        frappe.throw("Your face is already registered. Contact your administrator to reset it.")
    file_doc = jpeg_file("genie-face-reference-v1.jpg", "User", current_user)
    # A deterministic primary key provides a DB unique constraint even if two
    # devices try to enroll the same account concurrently. Existing references
    # are never overwritten; an administrator must deliberately remove one.
    file_doc.insert(ignore_permissions=True, set_name=reference_name)
    frappe.response["message"] = {
        "status": "success", "current_user": current_user, "enrolled": True,
        "reference_file": {
            "name": file_doc.name, "url": file_doc.file_url,
            "version": file_doc.content_hash or file_doc.name,
        },
        "model_version": model_version, "minimum_similarity": minimum_similarity,
        "csrf_token": csrf_token, "verification_receipt_version": 2,
    }

elif action == "record_verification":
    verification_started = timing_start()
    stage_started = timing_start()
    verification_stage = "validating session and request"
    try:
        require_csrf()
        reference = reference_file()
        if not reference:
            frappe.throw("Register your face before checking in or out.")
        if (
            frappe.form_dict.get("reference_file") != reference["name"]
            or frappe.form_dict.get("reference_version") != reference["version"]
        ):
            frappe.throw("The face reference has changed. Scan your face again.")
        verification_action = (frappe.form_dict.get("verification_action") or "").strip()
        if verification_action not in ["attendance_in", "attendance_out"]:
            frappe.throw("Face verification is only available for attendance check-in and check-out.")
        if frappe.form_dict.get("model_version") != model_version:
            frappe.throw("The face model has changed. Update the app and register again if required.")
        if frappe.form_dict.get("blink_completed") not in [True, 1, "1", "true"]:
            frappe.throw("Complete the live blink scan before checking in or out.")

        verification_stage = "validating match and GPS values"
        similarity = frappe.utils.flt(frappe.form_dict.get("similarity"))
        if not minimum_similarity <= similarity <= 1:
            frappe.throw("Your face did not match your registered selfie. Please try again.")
        if frappe.form_dict.get("latitude") is None or frappe.form_dict.get("longitude") is None:
            frappe.throw("A fresh GPS location is required for face verification.")
        latitude = frappe.utils.flt(frappe.form_dict.get("latitude"))
        longitude = frappe.utils.flt(frappe.form_dict.get("longitude"))
        if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
            frappe.throw("The GPS coordinates are invalid.")
        event_name = (frappe.form_dict.get("event") or "").strip()
        if event_name:
            frappe.throw("Face verification receipts cannot be used for Events.")

        timing_end("request_validation", stage_started)
        received_on = frappe.utils.now()
        captured_on = str(frappe.form_dict.get("captured_on") or "")[:64]
        metadata = {
            "version": 2, "current_user": current_user,
            "action": verification_action,
            "reference_file": reference["name"], "reference_version": reference["version"],
            "model_version": model_version, "similarity": similarity,
            "blink_completed": True, "latitude": latitude, "longitude": longitude,
            "captured_on": captured_on, "received_on": received_on,
            "verification_source": "device_reported", "used": False,
        }
        verification_stage = "saving verification receipt"
        stage_started = timing_start()
        record = frappe.get_doc({
            "doctype": "Comment", "comment_type": "Info",
            "reference_doctype": "User", "reference_name": current_user,
            "subject": "Genie Face Verification v1",
            # Comment.content is a Text Editor field. Escaping HTML-sensitive
            # characters as JSON unicode prevents its sanitizer from changing
            # valid usernames or interpreting a client capture string as markup.
            "content": json.dumps(metadata).replace("&", "\\u0026").replace("<", "\\u003c").replace(">", "\\u003e"),
        })
        record.insert(ignore_permissions=True)
        timing_end("receipt_insert", stage_started)
        # Keep the receipt system-owned so users cannot modify it through
        # Frappe's comment update API.
        verification_stage = "securing verification receipt"
        stage_started = timing_start()
        frappe.db.set_value("Comment", record.name, "owner", "Administrator")
        timing_end("receipt_secure", stage_started)
        timing_end("verification_total", verification_started)
        if include_timings:
            # Diagnostic durations only. Excludes request parsing/queueing,
            # transaction commit and response transmission outside this script.
            frappe.response["attendance_timings_ms"] = timings
        frappe.response["message"] = {
            "status": "success", "current_user": current_user,
            "record_id": record.name, "receipt_version": 2,
            "verification_source": "device_reported",
            "csrf_token": csrf_token, "verification_receipt_version": 2,
        }
    except TypeError as error:
        frappe.log_error(
            title="Genie Face Verification TypeError",
            message="Stage: " + verification_stage + "\nError: " + str(error),
            defer_insert=True,
        )
        raise

else:
    frappe.throw("Use status, enroll, or record_verification.")
