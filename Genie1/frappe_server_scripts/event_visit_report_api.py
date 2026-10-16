# Frappe Server Script settings:
#   Script Type: API
#   API Method: event_visit_report
#   Allow Guest: Disabled
#   Enable Rate Limit: Enabled
#
# GET  /api/method/event_visit_report?action=get&event_id=EVENT-ID
# POST /api/method/event_visit_report
#      form fields: action=save, event_id, observation, outcome, custom_otp (optional)
# POST action=save_otp, event_id, custom_otp saves OTP before event checkout.
# Report saves preserve an existing OTP when custom_otp is omitted.

action = (frappe.form_dict.get("action") or "get").strip().lower()
event_id = (frappe.form_dict.get("event_id") or "").strip()
current_user = frappe.session.user

if not current_user or current_user == "Guest":
    frappe.throw("Sign in to view or submit a visit report.")

if not event_id:
    frappe.throw("event_id is required.")

event = frappe.get_doc("Event", event_id)
assigned_users = str(event.get("_assign") or "")
is_assigned = (
    event.owner == current_user
    or event.get("assigned_to") == current_user
    or ('"' + current_user + '"') in assigned_users
)

# Some Event setups assign the user through the Event Participants child table.
for participant_field in ["event_participants", "participants"]:
    for participant in event.get(participant_field) or []:
        if (
            participant.get("email") == current_user
            or participant.get("user") == current_user
            or participant.get("assigned_to") == current_user
        ):
            is_assigned = True

if not is_assigned:
    frappe.throw("This Event is not assigned to your user.")

description = event.get("description") or ""
prefix = "observation : "
separator = "\nOutcome: "
observation = ""
outcome = ""

report_text = description
for old, new in [
    ("<br />", "\n"),
    ("<br/>", "\n"),
    ("<br>", "\n"),
    ("</p>", "\n"),
    ("</div>", "\n"),
    ('<div class="ql-editor read-mode">', ""),
    ('<div class="ql-editor">', ""),
    ("<p>", ""),
    ("<div>", ""),
    ("&nbsp;", " "),
]:
    report_text = report_text.replace(old, new)

report_text = report_text.strip()
if report_text.startswith(prefix) and separator in report_text:
    report_body = report_text[len(prefix):]
    split_at = report_body.rfind(separator)
    observation = report_body[:split_at].strip()
    outcome = report_body[split_at + len(separator):].strip()

allowed_outcomes = ["Interested", "Not Interested", "Follow-up Required"]
is_submitted = bool(observation and outcome in allowed_outcomes)

if action == "get":
    frappe.response["message"] = {
        "status": "success",
        "action": "get",
        "event_id": event_id,
        "observation": observation,
        "outcome": outcome,
        "custom_otp": event.get("custom_otp") or "",
        "is_submitted": is_submitted,
        "description": description,
        "outcomes": allowed_outcomes,
    }

elif action == "save_otp":
    custom_otp = frappe.form_dict.get("custom_otp")
    if not isinstance(custom_otp, str) or not custom_otp.strip():
        frappe.throw("OTP is required before checking out.")

    custom_otp = custom_otp.strip()
    if len(custom_otp) != 4 or custom_otp.strip("0123456789"):
        frappe.throw("OTP must contain exactly 4 digits.")
    event.custom_otp = custom_otp
    event.save(ignore_permissions=True)
    stored_otp = frappe.db.get_value("Event", event.name, "custom_otp")
    if str(stored_otp or "").strip() != custom_otp:
        frappe.throw("OTP could not be saved. Contact your administrator before checking out.")

    frappe.response["message"] = {
        "status": "success",
        "action": "save_otp",
        "event_id": event.name,
        "custom_otp": stored_otp,
        "otp_saved": True,
    }

elif action == "save":
    if is_submitted:
        frappe.throw("This visit report has already been submitted and cannot be edited.")

    observation = (frappe.form_dict.get("observation") or "").strip()
    outcome = (frappe.form_dict.get("outcome") or "").strip()

    if not observation:
        frappe.throw("Observation is required.")
    if outcome not in allowed_outcomes:
        frappe.throw("Choose a valid visit outcome.")

    custom_otp = frappe.form_dict.get("custom_otp")
    if custom_otp is not None:
        if not isinstance(custom_otp, str) or not custom_otp.strip():
            frappe.throw("OTP cannot be empty.")
        if len(custom_otp.strip()) != 4 or custom_otp.strip().strip("0123456789"):
            frappe.throw("OTP must contain exactly 4 digits.")
        event.custom_otp = custom_otp.strip()

    report_description = "observation : " + observation + "\nOutcome: " + outcome
    event.description = report_description
    event.save(ignore_permissions=True)

    frappe.response["message"] = {
        "status": "success",
        "action": "save",
        "event_id": event.name,
        "observation": observation,
        "outcome": outcome,
        "custom_otp": event.get("custom_otp") or "",
        "is_submitted": True,
        "description": report_description,
    }

else:
    frappe.throw("Invalid action. Use 'get', 'save', or 'save_otp'.")
