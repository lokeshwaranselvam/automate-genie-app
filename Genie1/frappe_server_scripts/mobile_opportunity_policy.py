# Restricted API Server Script. API Method: mobile_opportunity_policy
# Allow Guest: Disabled. Enable Rate Limit: Enabled.
# GET ?action=get&name=OPPORTUNITY (name is optional for list/filter options)
# POST action=save, name, modified, changes (JSON object)
# GET action=owner_options, name, txt; POST action=change_owner, name, modified, new_owner
# GET action=list, detail (name required), count; read visibility uses the fields below.
# Install here only: API Method mobile_opportunity_policy, NOT mobile_business_policy.

# These fields must store User IDs, not Employee IDs or display names.
# Highest priority first. Only the first non-empty field controls read visibility.
visibility_owner_fields = [
    "custom_field_owner_2",
    "custom_field_owner_1",
    "opportunity_owner",
]

# Policy settings. Add server-side role/user conditions here when needed.
editable_statuses = [
    "Open", "Follow-up", "Demo", "VC", "Duplicate Lead", "Junk",
    "Not Interested", "Hot Followup", "RNR", "B2B Database",
]
# Empty mapping preserves the current transitions among editable statuses.
# Example: {"Open": ["Follow-up", "Demo"]} restricts transitions FROM Open.
status_transitions = {}
allow_past_followup = False
earliest_followup_date = ""
opportunity_policy_by_user = {}

current_user = frappe.session.user
if not current_user or current_user == "Guest":
    frappe.throw("Sign in to access Opportunity settings.")
action = (frappe.form_dict.get("action") or "get").strip().lower()
if action in ["list", "detail", "count"]:
    meta = frappe.get_meta("Opportunity")
    if not visibility_owner_fields:
        frappe.throw("Configure at least one Opportunity visibility owner field.")
    owner_filters = []
    priority_columns = []
    for fieldname in visibility_owner_fields:
        owner_field = meta.get_field(fieldname)
        if not owner_field or owner_field.fieldtype not in ["Link", "Data"]:
            frappe.throw("Invalid Opportunity visibility owner field configuration.")
        if owner_field.fieldtype == "Link" and owner_field.options != "User":
            frappe.throw("Opportunity visibility Link fields must link to User.")
        owner_filters.append([fieldname, "=", current_user])
        priority_columns.append("NULLIF(o.`" + fieldname.replace("`", "``") + "`, '')")
    # Field Owner 2 wins whenever populated, even when assigned to another user.
    priority_condition = "COALESCE(" + ", ".join(priority_columns) + ", '') = " + frappe.db.escape(current_user, percent=False)

    if action == "detail":
        name = frappe.form_dict.get("name")
        if not isinstance(name, str) or not name.strip() or len(name) > 140:
            frappe.throw("A valid Opportunity ID is required.")
        opportunity = frappe.get_doc("Opportunity", name)
        opportunity.check_permission("read")
        visibility_owner = ""
        for fieldname in visibility_owner_fields:
            if opportunity.get(fieldname):
                visibility_owner = opportunity.get(fieldname)
                break
        if visibility_owner != current_user:
            frappe.throw("You cannot view this Opportunity.", frappe.PermissionError)
        can_edit = opportunity.get("opportunity_owner") == current_user and opportunity.has_permission("write")
        opportunity.apply_fieldlevel_read_permissions()
        frappe.response["message"] = {
            "current_user": current_user,
            "document": opportunity.as_dict(),
            "can_edit": bool(can_edit),
        }
    else:
        start_text = str(frappe.form_dict.get("start") or "0")
        if not start_text.isdigit() or len(start_text) > 9:
            frappe.throw("Invalid page offset.")
        start = int(start_text)
        status = frappe.form_dict.get("status") or ""
        phone = frappe.form_dict.get("phone") or ""
        if not isinstance(status, str) or len(status) > 140:
            frappe.throw("Invalid Opportunity status.")
        if not isinstance(phone, str) or len(phone) > 40:
            frappe.throw("Enter a valid phone number.")
        for separator in ["+", " ", "\t", "\r", "\n", "(", ")", ".", "-"]:
            phone = phone.replace(separator, "")
        if phone and (not phone.isascii() or not phone.isdigit() or len(phone) > 15):
            frappe.throw("Enter a valid phone number.")
        filters = []
        if status:
            filters.append(["status", "=", status])
        # Let Frappe build its normal role, sharing, User Permission and owner scope.
        # run=False returns SQL without fetching an unbounded list of records.
        scope_sql = frappe.get_list(
            "Opportunity", fields=["name"], filters=filters,
            or_filters=owner_filters, limit_page_length=0,
            order_by="name asc", run=False,
        )
        phone_sql = ""
        if phone:
            phone_filters = []
            for fieldname in ["contact_mobile", "phone"]:
                if meta.get_field(fieldname):
                    phone_filters.append([fieldname, "like", "%" + "%".join(phone) + "%"])
            if not phone_filters:
                frappe.throw("Opportunity phone search fields are not configured.")
            phone_scope = frappe.get_list(
                "Opportunity", fields=["name"], or_filters=phone_filters,
                limit_page_length=0, order_by="name asc", run=False,
            )
            phone_sql = " AND o.name IN (" + phone_scope + ")"
        # Both subqueries are framework-generated permission-aware SELECTs.
        # Escape their literal percent signs before binding pagination parameters.
        from_sql = (
            " FROM `tabOpportunity` o WHERE o.name IN (" + scope_sql + ")" + phone_sql
            + " AND " + priority_condition
        )
        if action == "count":
            totals = frappe.db.sql("SELECT COUNT(*) AS total" + from_sql, as_dict=True)
            frappe.response["message"] = {"current_user": current_user, "count": int(totals[0].total)}
        else:
            names = frappe.db.sql(
                "SELECT o.name" + from_sql.replace("%", "%%") + " ORDER BY o.creation DESC, o.name DESC LIMIT %(page_limit)s OFFSET %(start)s",
                {"page_limit": 51, "start": start}, as_dict=True,
            )
            selected_names = [row.name for row in names[:50]]
            items = []
            if selected_names:
                # Normal get_list also enforces field-level read permissions.
                items_sql = frappe.get_list(
                    "Opportunity",
                    fields=["name", "owner", "opportunity_owner", "customer_name", "party_name", "status", "creation"],
                    filters=filters + [["name", "in", selected_names]], or_filters=owner_filters,
                    order_by="creation desc, name desc", limit_page_length=50, run=False,
                )
                # Recheck priority when fetching rows, retaining Frappe's field permissions.
                items = frappe.db.sql(
                    "SELECT visible_rows.* FROM (" + items_sql + ") visible_rows"
                    + " INNER JOIN `tabOpportunity` o ON o.name = visible_rows.name"
                    + " WHERE " + priority_condition + " ORDER BY o.creation DESC, o.name DESC",
                    as_dict=True,
                )
            frappe.response["message"] = {
                "current_user": current_user, "items": items,
                "has_more": len(names) > 50, "next_start": start + len(selected_names),
            }
else:
    user_policy = opportunity_policy_by_user.get(current_user) or {}
    business_policy = frappe.call("mobile_business_policy", feature="opportunity", action="get", event_id="")["policy"]
    editable_statuses = user_policy.get("editable_statuses", editable_statuses)
    status_transitions = user_policy.get("status_transitions", status_transitions)
    allow_past_followup = user_policy.get("allow_past_followup", allow_past_followup)
    earliest_followup_date = user_policy.get("earliest_followup_date", earliest_followup_date)
    action = (frappe.form_dict.get("action") or "get").strip().lower()
    if action not in ["get", "save", "owner_options", "change_owner"]:
        frappe.throw("Invalid Opportunity action.")

    name = (frappe.form_dict.get("name") or "").strip()
    opportunity = None
    if name:
        opportunity = frappe.get_doc("Opportunity", name)
        opportunity.check_permission("read")
        if opportunity.get("opportunity_owner") != current_user:
            frappe.throw("Only the Opportunity Owner can access this Opportunity here.")
    else:
        # get_list enforces normal read permissions without exposing records.
        frappe.get_list("Opportunity", fields=["name"], limit_page_length=1)

    meta = frappe.get_meta("Opportunity")
    status_field = meta.get_field("status")
    configured_statuses = []
    for value in ((status_field.options if status_field else "") or "").splitlines():
        value = value.strip()
        if value and value not in configured_statuses:
            configured_statuses.append(value)
    allowed_statuses = [value for value in editable_statuses if value in configured_statuses]
    if "options" in business_policy["fields"]["status"]:
        allowed_statuses = [value for value in allowed_statuses if value in business_policy["fields"]["status"]["options"]]
    if not allowed_statuses:
        frappe.throw("No mobile Opportunity statuses are configured in ERP.")

    followup_fields = []
    for field in meta.fields:
        normalized_label = "".join(char for char in (field.label or "").lower() if char.isalpha())
        normalized_name = "".join(char for char in field.fieldname.lower() if char.isalpha())
        if field.fieldtype == "Date" and (
            normalized_label == "nextfollowupdate" or normalized_name.replace("custom", "", 1) == "nextfollowupdate"
        ):
            followup_fields.append(field.fieldname)
    followup_field = followup_fields[0] if len(followup_fields) == 1 else None
    earliest = earliest_followup_date
    if earliest and str(frappe.utils.getdate(earliest)) != earliest:
        frappe.throw("Configure the earliest follow-up date as YYYY-MM-DD.")
    today = frappe.utils.nowdate()
    if not allow_past_followup and (not earliest or earliest < today):
        earliest = today

    if action in ["owner_options", "change_owner"]:
        if not opportunity:
            frappe.throw("Opportunity name is required.")
        opportunity.check_permission("write")
        owner_field = meta.get_field("opportunity_owner")
        if not owner_field or owner_field.fieldtype != "Link" or owner_field.options != "User" or owner_field.get("read_only"):
            frappe.throw("Opportunity Owner is not editable in ERP.")
        if action == "owner_options":
            search_text = frappe.form_dict.get("txt") or ""
            if not isinstance(search_text, str) or len(search_text) > 140:
                frappe.throw("Search text must be at most 140 characters.")
            matches = frappe.call("frappe.desk.search.search_link", doctype="User",
                txt=search_text.strip(), page_length=20, reference_doctype="Opportunity",
                ignore_user_permissions=False, filters={"enabled": 1})
            frappe.response["message"] = {"options": matches, "current_user": current_user}
        else:
            request_method = frappe.request.get("method") if isinstance(frappe.request, dict) else frappe.request.method
            if request_method and request_method != "POST":
                frappe.throw("Use POST to update an Opportunity.")
            if not frappe.form_dict.get("csrf_token") or frappe.form_dict.get("csrf_token") != frappe.session.csrf_token:
                frappe.throw("Your update session expired. Refresh before retrying.")
            if str(opportunity.modified) != str(frappe.form_dict.get("modified") or ""):
                frappe.throw("This opportunity changed. Refresh it before editing again.")
            new_owner = frappe.form_dict.get("new_owner") or ""
            if not isinstance(new_owner, str) or not new_owner.strip() or len(new_owner) > 140:
                frappe.throw("Select a valid Opportunity Owner.")
            new_owner = new_owner.strip()
            matches = frappe.call("frappe.desk.search.search_link", doctype="User",
                txt=new_owner, page_length=20, reference_doctype="Opportunity",
                ignore_user_permissions=False, filters={"enabled": 1})
            owner_allowed = False
            for match in matches:
                if match.get("value") == new_owner:
                    owner_allowed = True
            if not owner_allowed:
                frappe.throw("Select an enabled, permitted ERP user as Opportunity Owner.")
            if new_owner != opportunity.opportunity_owner:
                opportunity.opportunity_owner = new_owner
                opportunity.save()
                if opportunity.opportunity_owner != new_owner:
                    frappe.throw("You do not have permission to change Opportunity Owner.")
            # Do not return the full document after transferring ownership.
            frappe.response["message"] = {"status": "success", "current_user": current_user,
                "name": opportunity.name, "opportunity_owner": new_owner}
    elif action == "get":
        frappe.response["message"] = {
            "status": "success", "current_user": current_user,
            "editable_statuses": allowed_statuses,
            "status_transitions": status_transitions,
            "followup_policy": {"allow_past": allow_past_followup, "earliest_date": earliest},
            "business_policy": business_policy,
        }
    else:
        # Hardened Safe Exec versions expose only a request dictionary, without
        # its HTTP method. Always require the session CSRF token; also enforce
        # POST when the request method is exposed by this Frappe version.
        request_method = frappe.request.get("method") if isinstance(frappe.request, dict) else frappe.request.method
        if request_method and request_method != "POST":
            frappe.throw("Use POST to update an Opportunity.")
        if not frappe.form_dict.get("csrf_token") or frappe.form_dict.get("csrf_token") != frappe.session.csrf_token:
            frappe.throw("Your update session expired. Refresh before retrying.")
        if not opportunity:
            frappe.throw("Opportunity name is required.")
        opportunity.check_permission("write")
        modified = str(frappe.form_dict.get("modified") or "")
        if not modified or str(opportunity.modified) != modified:
            frappe.throw("This opportunity changed. Refresh it before editing again.")
        changes = frappe.form_dict.get("changes") or {}
        if isinstance(changes, str):
            changes = json.loads(changes)
        if not isinstance(changes, dict):
            frappe.throw("Opportunity changes must be an object.")
        allowed_fields = ["status"]
        notes_field = meta.get_field("notes")
        if notes_field and notes_field.fieldtype == "Table":
            allowed_fields.append("notes")
        if followup_field:
            allowed_fields.append(followup_field)
        if "notes" in changes and (
            not isinstance(changes["notes"], list)
            or any(not isinstance(row, dict) for row in changes["notes"])
        ):
            frappe.throw("Notes must be a list of note rows.")
        for key in changes:
            if key not in allowed_fields:
                frappe.throw("Only status, notes and next follow-up date can be updated.")
        if "status" in changes and changes["status"] != opportunity.status:
            if changes["status"] not in allowed_statuses:
                frappe.throw("Select a valid Opportunity status.")
            targets = status_transitions.get(opportunity.status)
            if targets is not None and changes["status"] not in targets:
                frappe.throw("This Opportunity status transition is not allowed.")
        if followup_field:
            date_value = changes.get(followup_field, opportunity.get(followup_field))
            if followup_field in changes or date_value:
                date_text = str(date_value or "")
                if not date_text or str(frappe.utils.getdate(date_text)) != date_text:
                    frappe.throw("Choose a valid next follow-up date.")
                if earliest and date_text < earliest:
                    frappe.throw("Choose a next follow-up date on or after " + earliest + ".")
        note_required = (
            business_policy["rules"]["note_on_status_change"] and "status" in changes and changes["status"] != opportunity.status
        ) or (
            business_policy["rules"]["note_on_followup_change"] and followup_field in changes
            and changes[followup_field] != str(opportunity.get(followup_field) or "")
        )
        new_note_found = False
        new_note_text = ""
        policy_values = {"status": changes.get("status", opportunity.status),
            "followup_date": str(changes.get(followup_field, opportunity.get(followup_field)) or "") if followup_field else ""}
        original_values = {"status": opportunity.status, "followup_date": str(opportunity.get(followup_field) or "") if followup_field else ""}
        old_notes = {row.get("name"): row.get("note") for row in opportunity.get("notes") or [] if row.get("name")}
        for row in changes.get("notes") or []:
            if not row.get("name") or row.get("name") not in old_notes:
                plain = ""
                inside_tag = False
                for character in str(row.get("note") or ""):
                    if character == "<": inside_tag = True
                    elif character == ">": inside_tag = False
                    elif not inside_tag: plain = plain + character
                for old, new in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"'), ("&#39;", "'"), ("&#x27;", "'"), ("&#x2F;", "/"), ("&nbsp;", " "), ("&amp;", "&")]:
                    plain = plain.replace(old, new)
                if plain.replace("&nbsp;", " ").strip():
                    new_note_found = True
                    new_note_text = plain
                    policy_values["note"] = plain
                    frappe.call("mobile_business_policy", feature="opportunity", action="validate", values=policy_values, original_values=original_values)
        if not new_note_found:
            policy_values["note"] = new_note_text
            frappe.call("mobile_business_policy", feature="opportunity", action="validate", values=policy_values, original_values=original_values)
        if note_required and not new_note_found:
            frappe.throw("Note required: Please add a new note explaining the status or next follow-up date change, then tap Save.")
        if "notes" in changes and business_policy["rules"]["preserve_note_history"]:
            submitted_notes = {row.get("name"): row.get("note") for row in changes["notes"] if row.get("name")}
            for note_name in old_notes:
                if submitted_notes.get(note_name) != old_notes[note_name]:
                    frappe.throw("Existing note history must be retained.")
        for dependency in business_policy["rules"]["dependencies"]:
            if changes.get("status") in dependency["statuses"] and changes.get("status") != opportunity.status:
                found = False
                target_meta = frappe.get_meta(dependency["doctype"])
                if dependency.get("link_field"):
                    field = target_meta.get_field(dependency["link_field"])
                    if not field or field.fieldtype != "Link" or field.options != "Opportunity":
                        frappe.throw("The related document policy has an invalid Opportunity link field.")
                    found = bool(frappe.db.exists(dependency["doctype"], {dependency["link_field"]: name}))
                else:
                    for table_field in dependency.get("table_fields") or []:
                        field = target_meta.get_field(table_field)
                        if field and field.fieldtype == "Table":
                            child_meta = frappe.get_meta(field.options)
                            if child_meta.get_field(dependency["reference_doctype_field"]) and child_meta.get_field(dependency["reference_name_field"]):
                                if frappe.db.exists(field.options, {
                                    "parenttype": dependency["doctype"],
                                    dependency["reference_doctype_field"]: "Opportunity",
                                    dependency["reference_name_field"]: name,
                                }): found = True
                if not found: frappe.throw(dependency["message"])
        if "notes" in changes:
            note_meta = frappe.get_meta(notes_field.options)
            old_note_rows = {row.get("name"): row for row in opportunity.get("notes") or [] if row.get("name")}
            note_time = frappe.utils.now_datetime()
            for row in changes["notes"]:
                previous = old_note_rows.get(row.get("name"))
                if previous is None or row.get("note") != previous.get("note"):
                    if not note_meta.get_field("added_by") or not note_meta.get_field("added_on"):
                        frappe.throw("The Opportunity notes table must contain Added By and Added On fields.")
                    # Never accept author/time supplied by a client for a new or edited note.
                    row["added_by"] = current_user
                    row["added_on"] = note_time
                else:
                    # Parent saves must not reattribute an unchanged historical note.
                    for audit_field in ["added_by", "added_on"]:
                        if previous.get(audit_field) is not None:
                            row[audit_field] = previous.get(audit_field)
                        elif audit_field in row:
                            row.pop(audit_field)
        original_status = opportunity.status
        opportunity.update(changes)
        if "status" in changes and changes["status"] != original_status:
            opportunity.sales_stage = changes["status"]
        # Preserve normal ERP permissions, field permissions, workflows and hooks.
        opportunity.save()
        opportunity.apply_fieldlevel_read_permissions()
        frappe.response["data"] = opportunity.as_dict()
        frappe.response["message"] = {"status": "success", "current_user": current_user}
