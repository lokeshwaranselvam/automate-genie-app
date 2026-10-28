# Frappe Server Script settings:
#   Script Type: API
#   API Method: event_visit_report
#   Allow Guest: Disabled
#   Enable Rate Limit: Enabled
#
# GET  /api/method/event_visit_report?action=get&event_id=EVENT-ID
# POST /api/method/event_visit_report
#      form fields: action=save, event_id, observation, outcome
# OTP is no longer collected or validated. Existing OTP field data is retained.

# Business settings are defined once in mobile_business_policy.

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

visit_policy = frappe.call("mobile_business_policy", feature="visit", action="get", event_id=event_id)["policy"]
report_policy = frappe.call("mobile_business_policy", feature="visit_report", action="get", event_id="")["policy"]
requires_saved_location = visit_policy["rules"]["requires_saved_location"]
visit_geofencing_enabled = visit_policy["rules"]["visit_geofencing_enabled"]
requires_checkout_photo = visit_policy["uploads"]["min_count"] > 0
visit_checkin_radius_meters = visit_policy["rules"]["visit_checkin_radius_meters"]
visit_monitoring_enabled = visit_policy["rules"]["visit_monitoring_enabled"]
visit_monitoring_radius_meters = visit_policy["rules"]["visit_monitoring_radius_meters"]
checkout_location_categories = visit_policy["rules"]["checkout_location_categories"]
checkout_location_visit_types = visit_policy["rules"]["checkout_location_visit_types"]
allowed_outcomes = report_policy["fields"]["outcome"]["options"]
allow_report_edit_after_submit = report_policy["rules"]["allow_edit_after_submit"]

description = event.get("description") or ""
prefix = "observation : "
separator = "\nOutcome:"
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
has_report_format = False
if report_text.startswith(prefix) and separator in report_text:
    has_report_format = True
    report_body = report_text[len(prefix):]
    split_at = report_body.rfind(separator)
    observation = report_body[:split_at].strip()
    outcome = report_body[split_at + len(separator):].strip()

# Keep historical reports submitted even if their outcome is later retired.
is_submitted = has_report_format
report_block_reason = ""
if is_submitted and not allow_report_edit_after_submit:
    report_block_reason = "This visit report has already been submitted and cannot be edited."
elif not report_policy["rules"]["submit_enabled"]:
    report_block_reason = report_policy["rules"]["disabled_reason"]
can_edit_report = not bool(report_block_reason)
report_policy["actions"] = {
    "edit": {"allowed": can_edit_report, "reason": report_block_reason},
    "submit": {"allowed": can_edit_report, "reason": report_block_reason},
}

if action == "get":
    # Assignment was verified above. Return only files attached to this Event.
    attachments = frappe.get_all(
        "File",
        filters={
            "attached_to_doctype": "Event",
            "attached_to_name": event_id,
            "is_folder": 0,
            "file_url": ["is", "set"],
        },
        fields=["name", "file_name", "file_url", "is_private", "creation"],
        order_by="creation asc, name asc",
        limit_page_length=100,
    )
    frappe.response["message"] = {
        "status": "success",
        "action": "get",
        "requires_saved_location": requires_saved_location,
        "visit_geofencing_enabled": visit_geofencing_enabled,
        "requires_checkout_photo": requires_checkout_photo,
        "visit_checkin_radius_meters": visit_checkin_radius_meters,
        "visit_monitoring_enabled": visit_monitoring_enabled,
        "visit_monitoring_radius_meters": visit_monitoring_radius_meters,
        "checkout_location_categories": checkout_location_categories,
        "checkout_location_visit_types": checkout_location_visit_types,
        "event_id": event_id,
        "observation": observation,
        "outcome": outcome,
        "custom_otp": event.get("custom_otp") or "",
        "is_submitted": is_submitted,
        "can_edit_report": can_edit_report,
        "description": description,
        "outcomes": allowed_outcomes,
        "business_policy": report_policy,
        "visit_policy": visit_policy,
        "event_category": event.get("event_category") or event.get("custom_event_category") or "",
        "attachments": attachments,
    }

elif action == "save":
    if not can_edit_report:
        frappe.throw(report_block_reason)

    observation = (frappe.form_dict.get("observation") or "").strip()
    outcome = (frappe.form_dict.get("outcome") or "").strip()

    if report_policy["fields"]["observation"]["required"] and not observation:
        frappe.throw("Observation is required.")
    if (outcome or report_policy["fields"]["outcome"]["required"]) and outcome not in allowed_outcomes:
        frappe.throw("Choose a valid visit outcome.")
    frappe.call("mobile_business_policy", feature="visit_report", action="validate", original_values={},
        values={"observation": observation, "outcome": outcome})

    report_description = "observation : " + observation + "\nOutcome: " + outcome
    event.description = report_description
    event.save(ignore_permissions=True)

    frappe.response["message"] = {
        "status": "success",
        "action": "save",
        "requires_saved_location": requires_saved_location,
        "visit_geofencing_enabled": visit_geofencing_enabled,
        "requires_checkout_photo": requires_checkout_photo,
        "visit_checkin_radius_meters": visit_checkin_radius_meters,
        "visit_monitoring_enabled": visit_monitoring_enabled,
        "visit_monitoring_radius_meters": visit_monitoring_radius_meters,
        "checkout_location_categories": checkout_location_categories,
        "checkout_location_visit_types": checkout_location_visit_types,
        "event_id": event.name,
        "observation": observation,
        "outcome": outcome,
        "custom_otp": event.get("custom_otp") or "",
        "is_submitted": True,
        "can_edit_report": allow_report_edit_after_submit,
        "outcomes": allowed_outcomes,
        "description": report_description,
    }

else:
    frappe.throw("Invalid action. Use 'get' or 'save'.")
