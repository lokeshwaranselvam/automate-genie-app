# Restricted API Server Script: mobile_business_policy. Allow Guest: disabled.
# Return flags deliberately: frappe.call can reuse the same policy internally
# without overwriting the calling endpoint's response.
user = frappe.session.user
if not user or user == "Guest":
    frappe.throw("Sign in to load mobile business rules.")

# Supported business configuration. ERP mandatory fields/permissions still apply.
policies = {
    "attendance": {"fields": {}, "rules": {}},
    "navigation": {
        "fields": {},
        "rules": {"pending_drawer": False},
    },
    "general_upload": {"fields": {}, "rules": {},
        "uploads": {"min_count": 0, "max_count": 0, "max_bytes": 0, "extensions": []}},
    "opportunity": {
        "fields": {
            "note": {"visible": True, "read_only": False, "required": False},
            "status": {"visible": True, "read_only": False, "required": False},
            "followup_date": {"visible": True, "read_only": False, "required": False},
        },
        "rules": {
            "note_on_status_change": True, "note_on_followup_change": True,
            "preserve_note_history": True,
            "dependencies": [{"statuses": ["Demo"], "doctype": "Event",
                "table_fields": ["event_participants", "participants"],
                "reference_doctype_field": "reference_doctype", "reference_name_field": "reference_docname",
                "message": "Create an event first for this Opportunity before saving Demo. If an event already exists, check that it is linked to this Opportunity in ERP, then try again."}],
        },
    },
    "visit": {
        "fields": {
            "summary": {"required": True, "visible": True, "read_only": False, "max_length": 140},
            "product_enquired": {"required": False, "visible": True, "read_only": False},
            "assigned_to": {"required": True, "visible": True, "read_only": False},
            "location_type": {"required": False, "visible": True, "read_only": False},
        },
        "rules": {
            "location_types": ["Site", "Home", "Others"],
            "require_employee_attendance": True, "attendance_exempt_roles": [],
            "event_day_only": True, "allow_multiple_active_visits": False,
            "check_in_enabled": True, "check_out_enabled": True,
            "check_in_disabled_reason": "Visit check-in is currently unavailable.",
            "check_out_disabled_reason": "Visit checkout is currently unavailable.",
            "requires_saved_location": False, "visit_geofencing_enabled": False,
            "visit_checkin_radius_meters": 100, "visit_monitoring_enabled": True,
            "visit_monitoring_radius_meters": 200,
            "checkout_location_categories": ["Site Visit", "Installation", "Complaint Visit"],
            "checkout_location_visit_types": ["New"],
        },
        "uploads": {"min_count": 1, "max_count": 0, "max_bytes": 0, "extensions": []},
    },
    "visit_report": {
        "fields": {
            "observation": {"required": True, "visible": True, "read_only": False},
            "outcome": {"required": True, "visible": True, "read_only": False,
                "options": ["Interested", "Not Interested", "Follow-up Required"]},
        },
        "rules": {"allow_edit_after_submit": False, "submit_enabled": True,
            "disabled_reason": "Visit report submission is currently unavailable."},
    },
    "lead": {
        "fields": {
            "first_name": {"required": True, "visible": True, "read_only": False},
            "mobile_no": {"required": True, "visible": True, "read_only": False},
            "whatsapp_no": {"required": True, "visible": True, "read_only": False},
            "custom_requirement": {"required": True, "visible": True, "read_only": False},
            "source": {"required": True, "visible": True, "read_only": False},
            "custom_product_enquired": {"required": True, "visible": True, "read_only": False},
            "custom_citytown": {"required": True, "visible": True, "read_only": False},
            "custom_district": {"required": True, "visible": True, "read_only": False},
            "custom_address": {"required": False, "visible": True, "read_only": False},
        }, "rules": {},
    },
    "expense": {
        "fields": {
            "description": {"required": True, "visible": True, "read_only": False},
            "expense_type": {"required": True, "visible": True, "read_only": False},
            "amount": {"required": True, "visible": True, "read_only": False, "type": "number", "min_exclusive": 0},
            "expense_date": {"required": True, "visible": True, "read_only": False},
        }, "rules": {"max_expense_rows": 0},
        "uploads": {"min_count": 1, "max_count": 0, "max_bytes": 0, "extensions": []},
    },
    "leave": {
        "fields": {
            "from_date": {"required": True, "visible": True, "read_only": False},
            "to_date": {"required": True, "visible": True, "read_only": False},
            "half_day": {"required": False, "visible": True, "read_only": False},
            "description": {"required": True, "visible": True, "read_only": False},
            "leave_type": {"required": True, "visible": True, "read_only": False},
        },
        "rules": {"earliest_date": "", "latest_date": "", "max_days": 0, "half_day_allowed": True},
    },
}
# Exact authenticated-user overrides. Fields/rules/uploads are merged by key.
policy_by_user = {}
feature = (frappe.form_dict.get("feature") or "").strip()
if feature not in policies:
    frappe.throw("Choose a supported mobile policy feature.")
policy = policies[feature]
override = (policy_by_user.get(user) or {}).get(feature) or {}
for section in ["fields", "rules", "uploads"]:
    if section in override:
        policy[section] = dict(policy.get(section) or {})
        if section == "fields":
            for name in override[section]:
                merged = dict(policy[section].get(name) or {})
                merged.update(override[section][name])
                policy[section][name] = merged
        else:
            policy[section].update(override[section])
policy["version"] = 1
policy["current_user"] = user

if feature == "attendance":
    # Self-service display only: never accept a client-supplied employee/user.
    attendance_date = frappe.utils.today()
    employees = frappe.get_all("Employee", filters={"user_id": user, "status": "Active"},
        fields=["name", "default_shift"], limit_page_length=2)
    attendance_shift = ""
    shift_source = ""
    checkin_location = ""
    attendance_status = {"attendance_records_verified": False}
    if len(employees) == 1:
        employee = employees[0]
        requests = frappe.get_all("Shift Request", filters={
            "employee": employee.name, "docstatus": 1, "status": "Approved",
            "from_date": ["<=", attendance_date],
        }, or_filters=[["to_date", ">=", attendance_date], ["to_date", "is", "not set"]],
            fields=["shift_type"], order_by="from_date desc, modified desc, name desc", limit_page_length=1)
        if requests and requests[0].shift_type:
            attendance_shift = requests[0].shift_type
            shift_source = "shift_request"
        elif employee.default_shift:
            attendance_shift = employee.default_shift
            shift_source = "employee_default"
        # Table MultiSelect values live in child rows, not an Employee column.
        office_mappings = frappe.get_all("Employee Office Type Mapping", filters={
            "parent": employee.name, "parenttype": "Employee", "parentfield": "custom_office_type_mapping",
        }, fields=["office_type"], order_by="idx asc", limit_page_length=100)
        office_names = []
        for mapping in office_mappings:
            office_name = (mapping.get("office_type") or "").strip()
            if office_name and office_name not in office_names:
                office_names.append(office_name)
        checkin_location = ", ".join(office_names)
        # Attendance data stays server-owned; location comes from Employee.
        latest_logs = frappe.get_all("Employee Checkin", filters=[
            ["employee", "=", employee.name],
            ["time", ">=", attendance_date + " 00:00:00"],
            ["time", "<", str(frappe.utils.add_days(attendance_date, 1)) + " 00:00:00"],
        ], fields=["log_type", "time"], order_by="time desc, creation desc", limit_page_length=1000)
        in_logs = [row for row in latest_logs if row.log_type == "IN"]
        out_logs = [row for row in latest_logs if row.log_type == "OUT"]
        previous_logs = []
        if not latest_logs:
            previous_logs = frappe.get_all("Employee Checkin", filters=[
                ["employee", "=", employee.name], ["time", "<", attendance_date + " 00:00:00"],
            ], fields=["log_type", "time"], order_by="time desc, creation desc", limit_page_length=1)
        previous_pending = bool(previous_logs and previous_logs[0].log_type == "IN")
        active = bool(in_logs and latest_logs[0].log_type == "IN")
        completed = bool(in_logs and out_logs and not active)
        attendance_status = {
            "attendance_records_verified": not any(row.log_type not in ["IN", "OUT"] for row in latest_logs),
            "attendance_status_source": "business_policy",
            "checked_in": active, "checked_out": completed, "completed_today": completed,
            "check_in_exists_today": bool(in_logs), "check_out_exists_today": bool(out_logs),
            "previous_checkout_pending": previous_pending,
            "check_in_time": str(in_logs[0].time) if in_logs else str(previous_logs[0].time) if previous_pending else "",
            "check_out_time": str(out_logs[0].time) if completed else "",
        }
    policy["attendance"] = {"shift": attendance_shift, "shift_source": shift_source,
        "date": attendance_date, "checkin_location": checkin_location, "status": attendance_status}

if feature == "leave":
    year = frappe.utils.getdate(frappe.utils.today()).year
    if not policy["rules"]["earliest_date"]:
        policy["rules"]["earliest_date"] = str(year - 5) + "-01-01"
    if not policy["rules"]["latest_date"]:
        policy["rules"]["latest_date"] = str(year + 5) + "-12-31"
    if frappe.utils.getdate(policy["rules"]["earliest_date"]) > frappe.utils.getdate(policy["rules"]["latest_date"]):
        frappe.throw("The configured leave date range is invalid.")

if feature == "visit" and frappe.form_dict.get("event_id"):
    event_id = str(frappe.form_dict.get("event_id"))
    event = frappe.get_doc("Event", event_id)
    category = (event.get("event_category") or "").strip().lower()
    optional_attachment_categories = [
        "other", "others", "bank", "head office", "head office ch",
        "timbe office", "timbe / bioman office ch", "measurement", "installation", "collection", "maintenance",
    ]
    if category in optional_attachment_categories:
        policy["uploads"]["min_count"] = 0
    assigned = event.owner == user or event.get("assigned_to") == user or ('"' + user + '"') in str(event.get("_assign") or "")
    for table in ["event_participants", "participants"]:
        for row in event.get(table) or []:
            if row.get("email") == user or row.get("user") == user or row.get("assigned_to") == user:
                assigned = True
    common_reason = "" if assigned else "This Event is not assigned to your user."
    # Event-day restriction applies to check-in only; a visit left open past
    # midnight must still be closable or it blocks attendance checkout.
    day_reason = ""
    if not common_reason and policy["rules"]["event_day_only"]:
        if not event.get("starts_on") or str(frappe.utils.getdate(event.starts_on)) != str(frappe.utils.today()):
            day_reason = "You can only check in on the event day."
    in_reason = common_reason or day_reason or ("" if policy["rules"]["check_in_enabled"] else policy["rules"]["check_in_disabled_reason"])
    out_reason = common_reason or ("" if policy["rules"]["check_out_enabled"] else policy["rules"]["check_out_disabled_reason"])
    if not in_reason and event.get("custom_check_in"):
        in_reason = "Already Checked In"
    if not out_reason and not event.get("custom_check_in"):
        out_reason = "Cannot check out before check-in"
    if not common_reason and event.get("custom_check_out"):
        in_reason = "Already Checked Out"
        out_reason = "Already Checked Out"
    can_prepare_checkout = False
    if not out_reason and (policy["uploads"]["min_count"] or policy["uploads"]["max_count"]):
        file_filters = {"attached_to_doctype": "Event", "attached_to_name": event_id,
            "is_folder": 0, "file_url": ["is", "set"]}
        count = frappe.db.count("File", file_filters) if policy["uploads"]["max_count"] or policy["uploads"]["min_count"] > 1 else int(bool(frappe.db.exists("File", file_filters)))
        policy["uploads"]["current_count"] = count
        if count < policy["uploads"]["min_count"]:
            out_reason = "Attach a visit photo before checking out." if policy["uploads"]["min_count"] == 1 else "Attach the required visit photos before checking out."
            # UI may prepare/upload files; the write endpoint still requires allowed.
            can_prepare_checkout = True
    employee = None
    if not in_reason:
        employee = frappe.db.get_value("Employee", {"user_id": user, "status": "Active"}, "name")
        if not employee:
            in_reason = "Employee not found or inactive"
    exempt = False
    exemption_roles = policy["rules"]["attendance_exempt_roles"]
    if not in_reason and exemption_roles:
        exempt = bool(frappe.db.exists("Has Role", {"parent": user, "parenttype": "User", "parentfield": "roles", "role": ["in", exemption_roles]}))
    if not in_reason and policy["rules"]["require_employee_attendance"] and not exempt:
        attendance = frappe.get_all("Employee Checkin", filters={"employee": employee},
            fields=["log_type", "time"], order_by="time desc, creation desc", limit_page_length=1)
        if not attendance or attendance[0].log_type != "IN" or str(frappe.utils.getdate(attendance[0].time)) != str(frappe.utils.today()):
            in_reason = "Please complete your Employee Check-in for today before checking in to this visit."
    if not in_reason and not policy["rules"]["allow_multiple_active_visits"] and frappe.db.exists("Visit", {
        "employee": employee, "event_id": ["!=", event_id], "custom_check_in_time": ["is", "set"],
        "custom_check_out_time": ["is", "not set"],
    }):
        in_reason = "You are already checked in to another event. Please check out before starting a new event."
    policy["actions"] = {
        "check_in": {"allowed": not bool(in_reason), "reason": in_reason},
        "check_out": {"allowed": not bool(out_reason), "reason": out_reason, "can_prepare": can_prepare_checkout},
    }

action = frappe.form_dict.get("action") or "get"
if action == "validate":
    error_prefix = str(frappe.form_dict.get("error_prefix") or "")
    values = frappe.form_dict.get("values") or {}
    if isinstance(values, str):
        values = json.loads(values)
    if not isinstance(values, dict):
        frappe.throw(error_prefix + "Form values must be an object.")
    original_values = frappe.form_dict.get("original_values") or {}
    if isinstance(original_values, str): original_values = json.loads(original_values)
    if not isinstance(original_values, dict): frappe.throw(error_prefix + "Original values must be an object.")
    for fieldname in policy["fields"]:
        rule = policy["fields"][fieldname]
        value = values.get(fieldname)
        if rule.get("read_only"):
            if fieldname not in original_values and "default" not in rule:
                frappe.throw(error_prefix + "Configure a default for read-only field " + fieldname + ".")
            if value != original_values.get(fieldname, rule.get("default")):
                frappe.throw(error_prefix + fieldname + " is read-only.")
        if rule.get("required") and (value is None or str(value).strip() == ""):
            frappe.throw(error_prefix + fieldname.replace("_", " ").capitalize() + " is required.")
        if value is not None and rule.get("max_length") and len(str(value)) > rule["max_length"]:
            frappe.throw(error_prefix + fieldname + " is too long.")
        if value and rule.get("options") is not None and value not in rule["options"]:
            frappe.throw(error_prefix + "Choose a valid " + fieldname.replace("_", " ") + ".")
        if value is not None and str(value).strip() and rule.get("type") == "number":
            try: number = float(str(value).replace(",", ""))
            except Exception: frappe.throw(error_prefix + "Choose a valid number for " + fieldname + ".")
            if number != number or number in [float("inf"), -float("inf")]: frappe.throw(error_prefix + "Choose a finite number for " + fieldname + ".")
            if rule.get("min_exclusive") is not None and number <= rule["min_exclusive"]:
                frappe.throw(error_prefix + fieldname + " must be greater than " + str(rule["min_exclusive"]) + ".")
            if rule.get("max_value") is not None and number > rule["max_value"]:
                frappe.throw(error_prefix + fieldname + " exceeds the permitted amount.")
    if feature == "leave":
        start = frappe.utils.getdate(values.get("from_date"))
        end = frappe.utils.getdate(values.get("to_date"))
        if end < start or str(start) < policy["rules"]["earliest_date"] or str(end) > policy["rules"]["latest_date"]:
            frappe.throw(error_prefix + "Choose leave dates within the permitted date range.")
        if policy["rules"]["max_days"] and (end - start).days + 1 > policy["rules"]["max_days"]:
            frappe.throw(error_prefix + "The leave exceeds the permitted number of days.")
        if values.get("half_day") and not policy["rules"]["half_day_allowed"]:
            frappe.throw(error_prefix + "Half-day leave is not available.")
elif action == "upload":
    upload = policy.get("uploads") or {}
    filename = str(frappe.form_dict.get("file_name") or "").lower()
    size = int(frappe.form_dict.get("file_size") or 0)
    count = int(frappe.form_dict.get("file_count") or 1)
    if upload.get("max_bytes") and size > upload["max_bytes"]:
        frappe.throw("The attachment exceeds the permitted file size.")
    if upload.get("max_count") and count > upload["max_count"]:
        frappe.throw("The permitted attachment count has been exceeded.")
    if upload.get("extensions") and not any(filename.endswith(extension.lower()) for extension in upload["extensions"]):
        frappe.throw("This attachment format is not allowed.")
elif action != "get":
    frappe.throw("Unsupported policy action.")
frappe.flags.policy = policy
