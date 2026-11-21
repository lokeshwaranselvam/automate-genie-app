# Restricted API Server Script: event_visit_report. Allow Guest: disabled.
# ALL verification selection settings live here. Use exact ERP names/user IDs.
# Credentials are read privately from Webhook -> BioSTP -> webhook_headers.
WATI_WEBHOOK_NAME = "BioSTP"
# Required: use an approved OTP template and its ACTUAL OTP parameter name.
# remarketing_rnr has no OTP parameter in the supplied JSON; do not reuse it.
WATI_TEMPLATE_NAME = "happy_code"
WATI_OTP_PARAMETER_NAME = "1"
WATI_CHANNEL_NUMBER = ""  # Set only if your WATI account requires it.
# Optional: actual WATI parameter name -> customer_name or event_id.
WATI_EXTRA_PARAMETER_SOURCES = {}

VERIFICATION_ENABLED = True
VERIFICATION_TO_ALL = 0
VERIFICATION_CATEGORIES = ["Site Visit"]
VERIFICATION_COMPANIES = ["Bioman Sewage Solutions Private Limited", "Homegenie Building Products Private Limited"]
VERIFICATION_USERS = []
VERIFICATION_ROLES = []

action = (frappe.form_dict.get("action") or "get").strip().lower()
current_user = frappe.session.user
if not current_user or current_user == "Guest":
    frappe.throw("Sign in to view or submit a visit report.")
company_match = False
role_match = False
if VERIFICATION_ENABLED and VERIFICATION_TO_ALL and VERIFICATION_COMPANIES:
    company_match = bool(frappe.db.exists("Employee", {
        "user_id": current_user, "status": "Active",
        "company": ["in", VERIFICATION_COMPANIES],
    }))
if VERIFICATION_ENABLED and VERIFICATION_ROLES:
    role_match = bool(frappe.db.exists("Has Role", {
        "parent": current_user, "parenttype": "User", "parentfield": "roles",
        "role": ["in", VERIFICATION_ROLES],
    }))
verification_visible = bool(VERIFICATION_ENABLED and VERIFICATION_CATEGORIES and (
    current_user in VERIFICATION_USERS or role_match or company_match
))
verification_policy = {"current_user": current_user, "visible": verification_visible,
    "categories": VERIFICATION_CATEGORIES if verification_visible else [], "otp_length": 6}

if action == "verification_policy":
    # Internal document-event callers receive flags without replacing their response.
    frappe.flags.verification_policy = verification_policy
elif action == "send_checkout_otp":
    # BEGIN CHECKOUT DELIVERY
    SENT_MARKER = "EVENT_CHECKOUT_OTP_ACCEPTED|"
    current_user = frappe.session.user
    if not current_user or current_user == "Guest":
        frappe.throw("Sign in before processing customer OTP delivery.")
    event_id = frappe.form_dict.get("event_id")
    ticket_id = frappe.form_dict.get("ticket_id")
    if not isinstance(event_id, str) or not event_id.strip() or not isinstance(ticket_id, str) or not ticket_id.strip():
        frappe.throw("Event and queued delivery ticket are required.")
    ticket = frappe.get_doc("Comment", ticket_id, for_update=True)
    if (ticket.get("subject") != "Genie OTP queued delivery"
        or ticket.get("reference_doctype") != "Event" or ticket.get("reference_name") != event_id
        or ticket.get("owner") != current_user or ticket.get("comment_type") != "Info"):
        frappe.throw("This OTP delivery ticket does not belong to your user and Event.")
    doc = frappe.get_doc("Event", event_id, for_update=True)
    delivery_allowed = bool(ticket.get("content") == "Queued"
        and doc.get("status") == "Completed" and (doc.get("custom_check_out") or doc.get("custom_out"))
        and not frappe.db.exists("Comment", {"reference_doctype": "Event", "reference_name": event_id,
            "subject": "EVENT_CHECKOUT_OTP_ATTEMPTED|" + event_id}))
    if delivery_allowed:
        # Diagnostic context only; the checkout/sending conditions are unchanged.
        error_stage = "Load verification policy"
        otp = ""
        digits = ""
        customer_mobile = ""
        provider_detail = ""
        wati_authorization = ""
        wati_token = ""
        try:
            policy = frappe.call("event_visit_report", action="verification_policy")["verification_policy"]
            category = doc.get("event_category") or doc.get("custom_event_category") or ""
            eligible = policy["visible"] and category in policy["categories"]
            error_stage = "Check duplicate-send marker"
            already_sent = frappe.db.exists("Comment", {"reference_doctype": "Event",
                "reference_name": doc.name, "subject": SENT_MARKER + doc.name})
            if eligible and not already_sent:
                error_stage = "Claim queued delivery attempt"
                ticket.content = "Attempt started; do not automatically resend."
                ticket.save(ignore_permissions=True)
                error_stage = "Read WATI credentials from Webhook BioSTP"
                wati_webhook = frappe.get_doc("Webhook", WATI_WEBHOOK_NAME)
                wati_url = str(wati_webhook.get("request_url") or "").strip()
                if wati_url.rstrip("/") != "https://live-mt-server.wati.io/423524/api/v1/sendTemplateMessages":
                    frappe.throw("BioSTP Request URL must be the configured WATI tenant 423524 sendTemplateMessages endpoint.")
                for header in wati_webhook.get("webhook_headers") or []:
                    if str(header.get("key") or "").strip().lower() == "authorization":
                        if wati_authorization:
                            frappe.throw("BioSTP must have exactly one Authorization header.")
                        wati_authorization = str(header.get("value") or "").strip()
                if not wati_authorization.lower().startswith("bearer "):
                    frappe.throw("BioSTP Authorization header must contain Bearer followed by its WATI token.")
                wati_token = wati_authorization[7:].strip()
                if not wati_token or wati_token.lower().startswith("bearer ") or "\r" in wati_authorization or "\n" in wati_authorization:
                    frappe.throw("BioSTP Authorization header is invalid. Store Bearer and the token once only.")
                error_stage = "Validate approved WATI OTP template configuration"
                if (not WATI_TEMPLATE_NAME.strip() or not WATI_OTP_PARAMETER_NAME.strip()
                    or WATI_TEMPLATE_NAME.strip() == "remarketing_rnr"):
                    frappe.throw("Configure WATI_TEMPLATE_NAME and WATI_OTP_PARAMETER_NAME for an approved OTP template. remarketing_rnr has no OTP parameter in the supplied request.")
                error_stage = "Prepare customer OTP through event_visit_report"
                generated = frappe.call("event_visit_report", action="ensure_otp", event_id=doc.name)["otp_generation"]
                if generated.get("event_id") != doc.name or not generated.get("otp_ready"):
                    frappe.throw("The customer OTP is not ready.")
                # The API intentionally does not return the expected OTP to clients.
                error_stage = "Read and validate stored OTP"
                otp = str(frappe.db.get_value("Event", doc.name, "custom_otp") or "").strip()
                if len(otp) != 6 or otp.strip("0123456789"):
                    frappe.throw("Existing six-digit customer OTP is missing.")
                error_stage = "Find linked Opportunity and customer mobile"
                opportunity_id = ""
                for participant in doc.get("event_participants") or []:
                    if participant.get("reference_doctype") == "Opportunity" and participant.get("reference_docname"):
                        opportunity_id = participant.get("reference_docname")
                        break
                customer = frappe.db.get_value("Opportunity", opportunity_id, ["title", "contact_mobile"], as_dict=True) if opportunity_id else None
                if not customer:
                    frappe.throw("A linked Opportunity with a customer mobile is required.")
                error_stage = "Normalize customer mobile"
                customer_mobile = str(customer.get("contact_mobile") or "")
                digits = ""
                for character in str(customer.get("contact_mobile") or ""):
                    if character in "0123456789":
                        digits = digits + character
                if len(digits) == 11 and digits.startswith("0"):
                    digits = digits[1:]
                if len(digits) == 10:
                    digits = "91" + digits
                if len(digits) != 12 or not digits.startswith("91"):
                    frappe.throw("Customer mobile must be a valid Indian phone number.")
                error_stage = "Build WATI OTP template payload"
                wati_parameters = [{"name": WATI_OTP_PARAMETER_NAME, "value": otp}]
                for parameter_name in WATI_EXTRA_PARAMETER_SOURCES:
                    source_name = WATI_EXTRA_PARAMETER_SOURCES[parameter_name]
                    if source_name == "customer_name":
                        parameter_value = str(customer.get("title") or "Customer")
                    elif source_name == "event_id":
                        parameter_value = doc.name
                    else:
                        frappe.throw("Unsupported WATI extra parameter source. Use customer_name or event_id.")
                    if not parameter_name or parameter_name == WATI_OTP_PARAMETER_NAME:
                        frappe.throw("WATI template parameter names must be nonempty and unique.")
                    wati_parameters.append({"name": parameter_name, "value": parameter_value})
                wati_payload = {"template_name": WATI_TEMPLATE_NAME,
                    "broadcast_name": "event_otp_" + doc.name,
                    "receivers": [{"whatsappNumber": digits, "customParams": wati_parameters}]}
                if WATI_CHANNEL_NUMBER.strip():
                    wati_payload["channel_number"] = WATI_CHANNEL_NUMBER.strip()
                # Persist the one-shot claim and release Event locks before I/O.
                frappe.get_doc({"doctype": "Comment", "comment_type": "Info",
                    "reference_doctype": "Event", "reference_name": event_id,
                    "subject": "EVENT_CHECKOUT_OTP_ATTEMPTED|" + event_id,
                    "content": "WATI attempt started. Check provider history before any manual resend."}).insert(ignore_permissions=True)
                frappe.db.commit()
                error_stage = "Send WhatsApp template request to WATI"
                result = frappe.make_post_request(wati_url,
                    headers={"Authorization": wati_authorization, "Content-Type": "application/json", "Accept": "application/json"},
                    json=wati_payload)
                error_stage = "Check WATI acceptance response"
                accepted = False
                if isinstance(result, dict) and result.get("result") is True and not result.get("error"):
                    batch_errors = result.get("errors")
                    has_batch_errors = False
                    if isinstance(batch_errors, dict):
                        for error_key in batch_errors:
                            if batch_errors[error_key]:
                                has_batch_errors = True
                    elif batch_errors:
                        has_batch_errors = True
                    if not has_batch_errors:
                        if ("receivers" not in result and isinstance(batch_errors, dict)
                            and "error" in batch_errors
                            and isinstance(batch_errors.get("invalidWhatsappNumbers"), list)
                            and isinstance(batch_errors.get("invalidCustomParameters"), list)):
                            # Legacy WATI v1 batch success has no recipient IDs.
                            accepted = True
                        else:
                            for receiver in result.get("receivers") or []:
                                if (isinstance(receiver, dict) and str(receiver.get("waId") or "").strip() == digits
                                    and receiver.get("isValidWhatsAppNumber") is not False
                                    and not receiver.get("errors") and receiver.get("localMessageId")):
                                    accepted = True
                if not accepted:
                    if isinstance(result, dict):
                        provider_detail = str(result.get("error") or result.get("message") or "WATI response did not confirm a successful send without validation errors.")
                        # Capture the actual response shape for diagnosis. The
                        # catch block redacts credentials, OTP and phone first.
                        provider_detail = provider_detail + "\nWATI response: " + str(result)
                    else:
                        provider_detail = "Provider returned an unexpected response type."
                    frappe.throw("WhatsApp provider did not confirm acceptance.")
                # No code or phone number in comments/logs.
                error_stage = "Save acceptance marker (WATI already accepted the message)"
                frappe.get_doc({"doctype": "Comment", "comment_type": "Info",
                    "reference_doctype": "Event", "reference_name": doc.name,
                    "subject": SENT_MARKER + doc.name,
                    "content": "Customer OTP WhatsApp template accepted by WATI."}).insert(ignore_permissions=True)
        except Exception as error:
            # Never roll back completed checkout because delivery failed.
            error_detail = str(error) or "No exception message was provided."
            # HTTPError normally has a response; timeouts generally do not.
            # Capture provider explanation rather than guessing from HTTP status.
            try:
                http_response = error.response
                if http_response is not None:
                    error_detail = error_detail + "\nHTTP status: " + str(http_response.status_code)
                    error_detail = error_detail + "\nProvider response: " + str(http_response.text or "[empty body]")
            except Exception:
                pass
            if provider_detail:
                error_detail = error_detail + "\nProvider detail: " + provider_detail
            # Provider/HTTP exceptions may echo request data. Redact before truncating.
            for sensitive_value in [wati_authorization, wati_token, otp, digits, customer_mobile]:
                if sensitive_value:
                    error_detail = error_detail.replace(str(sensitive_value), "[REDACTED]")
            frappe.log_error(title="Event checkout OTP delivery failed",
                message="Event: " + doc.name
                    + "\nSource: event_visit_report / send_checkout_otp"
                    + "\nStage: " + error_stage
                    + "\nReason: " + error_detail[:2000]
                    + "\nCheckout is preserved. No automatic resend on later saves.")
    # END CHECKOUT DELIVERY
elif action == "verification_states":
    event_ids = frappe.form_dict.get("event_ids") or "[]"
    if isinstance(event_ids, str):
        event_ids = json.loads(event_ids)
    if not isinstance(event_ids, list) or len(event_ids) > 50:
        frappe.throw("Supply at most 50 Event IDs.")
    for requested_id in event_ids:
        if not isinstance(requested_id, str) or not requested_id.strip() or len(requested_id) > 140:
            frappe.throw("Invalid Event ID.")
    states = []
    if verification_visible and event_ids:
        # Fetch in batches; return only explicit state fields after assignment checks.
        events = frappe.get_all("Event", filters={"name": ["in", event_ids]},
            fields=["*"], limit_page_length=50)
        participants = frappe.get_all("Event Participants",
            filters={"parent": ["in", event_ids], "parenttype": "Event"},
            fields=["*"], limit_page_length=1000)
        for row in events:
            assigned = row.get("owner") == current_user or row.get("assigned_to") == current_user
            assigned = assigned or ('"' + current_user + '"') in str(row.get("_assign") or "")
            for participant in participants:
                if participant.get("parent") == row.get("name") and (
                    participant.get("email") == current_user or participant.get("user") == current_user
                    or participant.get("assigned_to") == current_user
                ):
                    assigned = True
            if assigned:
                required = (row.get("event_category") or row.get("custom_event_category") or "") in VERIFICATION_CATEGORIES
                completed = row.get("status") == "Completed" and bool(row.get("custom_check_out") or row.get("custom_out"))
                states.append({"event_id": row.get("name"), "verification_required": bool(required and completed),
                    "is_verified": bool(str(row.get("custom_validate") or "").strip())})
    frappe.response["message"] = {"status": "success", "verification_policy": verification_policy, "events": states}
else:
    # Frappe Server Script settings:
    #   Script Type: API
    #   API Method: event_visit_report
    #   Allow Guest: Disabled
    #   Enable Rate Limit: Enabled
    #
    # GET  /api/method/event_visit_report?action=get&event_id=EVENT-ID
    # POST /api/method/event_visit_report
    #      form fields: action=save, event_id, observation, outcome
    # Post-checkout verification is independent of report submission.

    # Business settings are defined once in mobile_business_policy.

    action = (frappe.form_dict.get("action") or "get").strip().lower()
    event_id = (frappe.form_dict.get("event_id") or "").strip()
    current_user = frappe.session.user

    if not current_user or current_user == "Guest":
        frappe.throw("Sign in to view or submit a visit report.")

    if not event_id:
        frappe.throw("event_id is required.")

    event = frappe.get_doc("Event", event_id, for_update=action in ["ensure_otp", "verify"])
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

    if action == "ensure_otp":
        # Called explicitly by Desk after_save or the checkout sender. No OTP is
        # returned to the caller. Selection rules stay in this one API script.
        otp_required = bool(verification_visible and
            (event.get("event_category") or event.get("custom_event_category") or "") in VERIFICATION_CATEGORIES)
        otp_ready = False
        if otp_required:
            otp = str(event.get("custom_otp") or "").strip()
            existing_log = frappe.db.get_value("Number Log", {"event_name": event_id}, ["name", "otp"], as_dict=True)
            if not otp:
                # Preserve an already-generated Number Log code if one exists.
                otp = str(existing_log.get("otp") or "").strip() if existing_log else ""
                if not otp:
                    rows = frappe.db.sql("SELECT CAST(100000 + MOD(CAST(CONV(HEX(RANDOM_BYTES(4)), 16, 10) AS UNSIGNED), 900000) AS CHAR) AS otp", as_dict=True)
                    otp = str(rows[0]["otp"]).strip()
                if len(otp) != 6 or otp.strip("0123456789"):
                    frappe.throw("A valid six-digit customer OTP could not be generated.")
                # Direct update avoids recursively saving Event during its After Save hook.
                frappe.db.set_value("Event", event_id, "custom_otp", otp, update_modified=False)
            if len(otp) != 6 or otp.strip("0123456789"):
                frappe.throw("The existing customer OTP must contain six digits. Contact your administrator.")
            if existing_log and str(existing_log.get("otp") or "").strip() != otp:
                frappe.throw("Event OTP and Number Log do not match. Contact your administrator.")
            if not existing_log:
                log = frappe.get_doc({"doctype": "Number Log", "event_name": event_id, "otp": otp})
                log.insert(ignore_permissions=True)
                existing_log = {"name": log.name}
            # Some sites have Number Log without an Event.number_log link field.
            # Keep the log record, but only write the optional link if configured.
            if frappe.get_meta("Event").get_field("number_log") and not event.get("number_log"):
                frappe.db.set_value("Event", event_id, "number_log", existing_log["name"], update_modified=False)
            otp_ready = True
        # Flags are returned by Frappe to API callers and internal frappe.call;
        # do not overwrite the checkout request's existing response.
        frappe.flags.otp_generation = {"status": "success", "event_id": event_id,
            "otp_required": otp_required, "otp_ready": otp_ready}
    else:
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

        verification_required = bool(verification_visible and
            (event.get("event_category") or event.get("custom_event_category") or "") in VERIFICATION_CATEGORIES)
        verification_completed = event.get("status") == "Completed" and bool(event.get("custom_check_out") or event.get("custom_out"))

        if action == "verify":
            if not verification_required:
                frappe.throw("OTP verification is not enabled for this user and Event category.")
            if not verification_completed:
                frappe.throw("Complete checkout before verifying this Event.")
            entered_otp = frappe.form_dict.get("custom_validate")
            if not isinstance(entered_otp, str) or len(entered_otp.strip()) != 6 or entered_otp.strip().strip("0123456789"):
                frappe.throw("Enter the 6-digit customer OTP.")
            entered_otp = entered_otp.strip()
            # Serialize attempts without changing the completed status or report.
            attempts = frappe.get_all("Comment", filters={"reference_doctype": "Event",
                "reference_name": event_id, "subject": "Genie OTP attempt",
                "creation": [">=", frappe.utils.add_to_date(frappe.utils.now_datetime(), minutes=-15)]},
                fields=["name"], limit_page_length=5)
            if len(attempts) >= 5:
                frappe.throw("Too many OTP attempts. Try again in 15 minutes.")
            if bool(str(event.get("custom_validate") or "").strip()):
                frappe.response["message"] = {"status": "success", "event_id": event_id, "is_verified": True}
            else:
                expected_otp = str(event.get("custom_otp") or "").strip()
                if len(expected_otp) != 6 or expected_otp.strip("0123456789"):
                    frappe.throw("The customer OTP is not ready. Contact your administrator.")
                matched = entered_otp == expected_otp
                if matched:
                    event.custom_validate = entered_otp
                    event.save(ignore_permissions=True)
                frappe.get_doc({"doctype": "Comment", "comment_type": "Info",
                    "reference_doctype": "Event", "reference_name": event_id,
                    "subject": "Genie OTP attempt", "content": "Customer verification attempt recorded."}).insert(ignore_permissions=True)
                # An error response, rather than throw, retains the failed attempt for throttling.
                frappe.response["message"] = {"status": "success" if matched else "error",
                    "event_id": event_id, "is_verified": matched,
                    "detail": "OTP verified." if matched else "Invalid OTP."}
        elif action == "get":
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
                "verification_required": bool(verification_required and verification_completed),
                "is_verified": bool(str(event.get("custom_validate") or "").strip()),
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
                "is_submitted": True,
                "can_edit_report": allow_report_edit_after_submit,
                "outcomes": allowed_outcomes,
                "description": report_description,
            }

        else:
            frappe.throw("Invalid action. Use get, save, verify, ensure_otp, send_checkout_otp, verification_policy, or verification_states.")
