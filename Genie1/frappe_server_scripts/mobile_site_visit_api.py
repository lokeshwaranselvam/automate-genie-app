# Frappe Server Script settings:
#   Script Type: API
#   API Method: mobile_site_visit
#   Allow Guest: Disabled
#   Enable Rate Limit: Enabled
#
# GET  /api/method/mobile_site_visit?action=can_create
# GET  /api/method/mobile_site_visit?action=get
# GET  /api/method/mobile_site_visit?action=search_by_mobile&mobile=98765
# GET  /api/method/mobile_site_visit?action=search_opportunities&query=CRM-OPP
# GET  /api/method/mobile_site_visit?action=get_references&category=Measurement&mobile=98765
# Measurement/Installation create_event uses reference_name/reference_doctype
# plus the Event map fields; company remains a read-only reference detail.
# POST /api/method/mobile_site_visit
#   action=save_location, opportunity, map_link, latitude, longitude,
#   location_type
#   action=create_event, opportunity, location_row, summary, starts_on, ends_on,
#   assigned_to, category, product_enquired (optional)
#   Other/Bank/Head Office/Timbe office/Collection omit location fields.
#   Measurement/Installation send map_link, latitude, longitude, location_type.

action = (frappe.form_dict.get("action") or "get").strip().lower()
current_user = frappe.session.user

# Mobile visit scheduling policy. Empty earliest date adds no extra date limit.
schedule_interval_minutes = 15
schedule_allow_past = False
schedule_earliest_booking_date = ""
tracking_allowed_roles = ["Sales User", "Designer"]
tracking_user_overrides = {}
# Optional UI visibility overrides; these never grant create/edit permissions.
feature_visibility_overrides = {}
feature_visibility_by_user = {}

if not current_user or current_user == "Guest":
    frappe.throw("Sign in to create a site visit.")

has_sales_manager_role = bool(frappe.db.exists(
    "Has Role",
    {"parent": current_user, "parenttype": "User", "parentfield": "roles",
     "role": "Sales Manager"},
))
has_sales_user_role = bool(frappe.db.exists(
    "Has Role",
    {"parent": current_user, "parenttype": "User", "parentfield": "roles",
     "role": "Sales User"},
))
has_designer_role = bool(frappe.db.exists(
    "Has Role",
    {"parent": current_user, "parenttype": "User", "parentfield": "roles",
     "role": "Designer"},
))
has_accounts_user_role = bool(frappe.db.exists(
    "Has Role",
    {"parent": current_user, "parenttype": "User", "parentfield": "roles",
     "role": "Accounts User"},
))
has_visit_operations_role = bool(frappe.db.exists(
    "Has Role",
    {"parent": current_user, "parenttype": "User", "parentfield": "roles",
     "role": ["in", ["SCM Manager", "Delivery Manager"]]},
))
can_create_visit = has_sales_manager_role or has_accounts_user_role or has_visit_operations_role
if action != "can_create" and not can_create_visit:
    frappe.throw("Only users with the Sales Manager role, Accounts User role, SCM Manager role, or Delivery Manager role can create site visits.")

business_policy = None
if action in ["get", "create_event"]:
    business_policy = frappe.call("mobile_business_policy", feature="visit", action="get", event_id="")["policy"]

# Combine category grants from every applicable creation role.
# Sales Manager retains its company policy; other roles add their own grants.
# Resolve the creator's company from Employee, never from request parameters
# or the selected customer's/reference document's company.
allowed_category_names = None
if action in ["get", "get_references", "create_event"]:
    employee_company = frappe.db.get_value(
        "Employee", {"user_id": current_user}, "company",
    )
    allowed_category_names = []
    if has_sales_manager_role:
        if employee_company in [
            "Bioman Sewage Solutions Private Limited",
            "Homegenie Building Products Private Limited",
        ]:
            allowed_category_names = [
                "sitevisit", "installation", "collection", "measurement", "complaintvisit",
            ]
        elif employee_company in [
            "Doortisan Creations Private Limited", "Timbe Windows Private Limited",
        ]:
            allowed_category_names = ["measurement", "collection", "sitevisit"]
        else:
            # Existing Sales Manager behavior: all configured categories.
            allowed_category_names = None
    if allowed_category_names is not None:
        if has_accounts_user_role:
            for category_name in ["bank", "collection", "other", "others"]:
                if category_name not in allowed_category_names:
                    allowed_category_names.append(category_name)
        if has_visit_operations_role:
            for category_name in ["installation", "complaintvisit", "sitevisit", "maintenance", "other", "others"]:
                if category_name not in allowed_category_names:
                    allowed_category_names.append(category_name)


# Category reference policy. Unlisted categories keep the Opportunity workflow.
# Empty reference means no customer/reference/location is collected.
CATEGORY_REFERENCE_TYPES = {
    "measurement": "Measurement",
    "installation": "Installation Note",
    "other": "", "others": "", "bank": "", "head office ch": "",
    "timbe / bioman office ch": "", "collection": "",
}
REFERENCE_DOCUMENT_FIELDS = {
    "Measurement": ["contact_number", "company"],
    "Installation Note": ["contact_mobile", "company"],
}


def get_category_rule(category):
    reference_doctype = CATEGORY_REFERENCE_TYPES.get(category.strip().lower(), "Opportunity")
    required_fields = ["category", "summary", "starts_on", "ends_on", "assigned_to"]
    mode = "none"
    if reference_doctype == "Opportunity":
        mode = "opportunity"
        required_fields = required_fields + ["opportunity", "location_row"]
    elif reference_doctype:
        if reference_doctype not in REFERENCE_DOCUMENT_FIELDS:
            frappe.throw("Unsupported visit reference DocType in category configuration.")
        mode = "document"
        required_fields = required_fields + [
            "reference_name", "map_link", "latitude", "longitude", "location_type",
        ]
    if business_policy:
        required_fields = [name for name in required_fields if name not in business_policy["fields"] or business_policy["fields"][name]["required"]]
    return {
        "reference_mode": mode,
        "reference_doctype": reference_doctype,
        "required_fields": required_fields,
    }


schedule_policy = {}
if action in ["get", "create_event"]:
    if not isinstance(schedule_interval_minutes, int) or isinstance(schedule_interval_minutes, bool) or schedule_interval_minutes < 1 or schedule_interval_minutes > 60 or 60 % schedule_interval_minutes:
        frappe.throw("Configure a visit interval that divides 60 minutes.")
    earliest = schedule_earliest_booking_date
    if earliest and str(frappe.utils.get_datetime(earliest).date()) != earliest:
        frappe.throw("Configure the earliest visit date as YYYY-MM-DD.")
    today = str(frappe.utils.now_datetime().date())
    if not schedule_allow_past and (not earliest or earliest < today):
        earliest = today
    schedule_policy = {
        "interval_minutes": schedule_interval_minutes,
        "allow_past": schedule_allow_past,
        "earliest_booking_date": earliest,
    }


def get_opportunity(opportunity_name):
    if not opportunity_name:
        return None
    if not frappe.db.exists("Opportunity", opportunity_name):
        return None
    return frappe.get_doc("Opportunity", opportunity_name)


def field_names(meta):
    return [field.fieldname for field in meta.fields if field.fieldname]


def get_opportunity_location_table():
    """Find the Opportunity child table by its actual child field schema."""
    opportunity_meta = frappe.get_meta("Opportunity")
    for table_field in opportunity_meta.fields:
        if table_field.fieldtype != "Table" or not table_field.options:
            continue
        child_meta = frappe.get_meta(table_field.options)
        child_fields = field_names(child_meta)
        has_required_fields = True
        for fieldname in ["location", "latitude", "longitude", "location_type"]:
            if fieldname not in child_fields:
                has_required_fields = False
                break
        if has_required_fields:
            return {"table_field": table_field, "child_meta": child_meta}

    frappe.throw(
        "Opportunity has no child table containing location, latitude, "
        "longitude, and location_type fields. Check the Opportunity Table field configuration."
    )


def get_location_types():
    location_table = get_opportunity_location_table()
    location_meta = location_table["child_meta"]
    location_field = location_meta.get_field("location_type")
    if not location_field:
        frappe.throw("Customer Location is missing its location_type field.")

    if location_field.fieldtype == "Select":
        options = [
            option.strip()
            for option in (location_field.options or "").splitlines()
            if option.strip()
        ]
        return {"options": options, "free_text": not options}
    if location_field.fieldtype == "Link" and location_field.options:
        options = [
            row.name
            for row in frappe.get_all(
                location_field.options,
                fields=["name"],
                order_by="name asc",
                limit_page_length=500,
            )
        ]
        return {"options": options, "free_text": False}
    if location_field.fieldtype in ["Data", "Small Text", "Text"]:
        return {"options": [], "free_text": True}
    return {"options": [], "free_text": False}


MOBILE_FIELD_CANDIDATES = [
    "contact_mobile",
    "phone",
    "mobile_no",
    "whatsapp",
    "whatsapp_no",
    "custom_mobile_no",
]


def existing_fields(meta, candidates):
    available = field_names(meta)
    found = []
    for candidate in candidates:
        if candidate in available:
            found.append(candidate)
    return found


def digits_only(value):
    digits = ""
    for char in str(value or ""):
        if char.isdigit():
            digits = digits + char
    # Compare on the last 10 digits so +91 / 0 prefixes still match.
    return digits[-10:]


def get_product_options():
    field = frappe.get_meta("Opportunity").get_field("custom_product_enquired")
    if not field:
        frappe.throw("Opportunity is missing its custom_product_enquired field.")
    if field.fieldtype == "Select":
        options = []
        for option in (field.options or "").splitlines():
            value = option.strip()
            if value and value not in options:
                options.append(value)
        return options
    if field.fieldtype == "Link" and field.options:
        return [
            row.name
            for row in frappe.get_all(
                field.options, fields=["name"], order_by="name asc",
                limit_page_length=0,
            )
        ]
    frappe.throw("Opportunity custom_product_enquired must be a Select or Link field.")


def get_event_category_config():
    # Preserve configured ERP labels while restricting the creator's options.
    event_meta = frappe.get_meta("Event")
    for candidate in ["event_category", "custom_event_category", "event_type"]:
        field = event_meta.get_field(candidate)
        if not field:
            continue
        options = []
        if field.fieldtype == "Select":
            for option in (field.options or "").splitlines():
                value = option.strip()
                if value and value not in options:
                    options.append(value)
        elif field.fieldtype == "Link" and field.options:
            options = [
                row.name for row in frappe.get_all(
                    field.options, fields=["name"], order_by="name asc",
                    limit_page_length=0,
                )
            ]
        if options:
            if allowed_category_names is not None:
                options = [
                    value for value in options
                    if "".join(value.lower().split()) in allowed_category_names
                ]
                if not options:
                    frappe.throw("Event has no configured categories allowed for your company.")
            return {"fieldname": candidate, "options": options}
    frappe.throw("Event has no configured category options.")


def phone_matches(row, mobile_fields, query_digits):
    for fieldname in mobile_fields:
        if query_digits in digits_only(row.get(fieldname)):
            return True
    return False


def get_mobile_opportunity_names(opportunity_meta, query_digits):
    # Prefilter in the database, including formatted phone numbers. Validate
    # only these candidates with the existing last-10-digits comparison.
    pattern = "%" + "%".join(query_digits) + "%"
    mobile_fields = existing_fields(opportunity_meta, MOBILE_FIELD_CANDIDATES)
    names = []
    if mobile_fields:
        for row in frappe.get_all(
            "Opportunity",
            or_filters=[[fieldname, "like", pattern] for fieldname in mobile_fields],
            fields=["name"] + mobile_fields,
            limit_page_length=0,
        ):
            if phone_matches(row, mobile_fields, query_digits):
                names.append(row.name)

    available = field_names(opportunity_meta)
    if "opportunity_from" in available and "party_name" in available:
        lead_meta = frappe.get_meta("Lead")
        lead_mobile_fields = existing_fields(
            lead_meta, ["mobile_no", "phone", "whatsapp_no"]
        )
        lead_names = []
        if lead_mobile_fields:
            for lead in frappe.get_all(
                "Lead",
                or_filters=[
                    [fieldname, "like", pattern] for fieldname in lead_mobile_fields
                ],
                fields=["name"] + lead_mobile_fields,
                limit_page_length=0,
            ):
                if phone_matches(lead, lead_mobile_fields, query_digits):
                    lead_names.append(lead.name)
        if lead_names:
            for row in frappe.get_all(
                "Opportunity",
                filters={
                    "opportunity_from": "Lead", "party_name": ["in", lead_names],
                },
                fields=["name"],
                limit_page_length=0,
            ):
                if row.name not in names:
                    names.append(row.name)
    return names


def get_opportunities(query_digits=None, text_query=None):
    """Fetch form fields only for the dropdown or matching phone results."""
    opportunity_meta = frappe.get_meta("Opportunity")
    available = field_names(opportunity_meta)
    title_field = "name"
    for candidate in [
        "title", opportunity_meta.title_field, "opportunity_name", "customer_name",
    ]:
        if candidate and candidate != "party_name" and candidate in available:
            title_field = candidate
            break
    opportunity_fields = ["name", "owner"]
    for candidate in [
        title_field, "party_name", "custom_product_enquired", "opportunity_owner",
        "contact_mobile", "phone",
    ]:
        if candidate in available and candidate not in opportunity_fields:
            opportunity_fields.append(candidate)
    filters = {}
    if query_digits:
        names = get_mobile_opportunity_names(opportunity_meta, query_digits)
        if not names:
            return []
        filters = {"name": ["in", names]}

    if text_query:
        search_fields = ["name"]
        for candidate in [title_field, "opportunity_name", "customer_name"]:
            if candidate == "party_name":
                continue
            if candidate in available and candidate not in search_fields:
                search_fields.append(candidate)
        # Escape LIKE wildcards so input is treated as literal search text.
        pattern = "%" + text_query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
        opportunities = frappe.get_list(
            "Opportunity",
            or_filters=[[fieldname, "like", pattern] for fieldname in search_fields],
            fields=opportunity_fields,
            order_by="modified desc",
            limit_page_length=50,
        )
    else:
        opportunities = frappe.get_all(
            "Opportunity",
            filters=filters,
            fields=opportunity_fields,
            order_by="modified desc",
            limit_page_length=0 if query_digits else 500,
        )
    results = []
    for row in opportunities:
        product = (row.get("custom_product_enquired") or "").strip()

        entry = {
            "name": row.name,
            "title": row.get(title_field) or row.name,
            "party_name": row.get("party_name") or "",
            "contact_mobile": row.get("contact_mobile") or "",
            "phone": row.get("phone") or "",
            "product_enquired": product,
            "assigned_to": (
                row.get("opportunity_owner") or row.get("owner") or current_user
            ).strip(),
        }
        results.append(entry)
    return results


if action == "can_create":
    can_create_lead = has_sales_manager_role or has_sales_user_role
    can_view_pending = can_create_lead or bool(frappe.db.exists(
        "Has Role",
        {"parent": current_user, "parenttype": "User", "parentfield": "roles",
         "role": ["in", ["Production Manager", "Production User"]]},
    ))
    can_track = bool(tracking_allowed_roles) and bool(frappe.db.exists(
        "Has Role",
        {"parent": current_user, "parenttype": "User", "parentfield": "roles",
         "role": ["in", tracking_allowed_roles]},
    ))
    if current_user in tracking_user_overrides:
        can_track = tracking_user_overrides[current_user] == True
    feature_visibility = {
        "visits": True, "leads": can_create_lead, "schedule": can_create_lead,
        "opportunities": has_sales_manager_role, "pending": can_view_pending,
        "add_lead": can_create_lead, "new_visit": can_create_visit,
        "tasks": True, "attendance": True, "new_task": True,
        "performance": True, "dashboards": True, "leave": True,
        "expenses": True, "canteen": True,
    }
    for feature in feature_visibility_overrides:
        if feature in feature_visibility:
            feature_visibility[feature] = feature_visibility_overrides[feature] == True
    user_visibility = feature_visibility_by_user.get(current_user) or {}
    for feature in user_visibility:
        if feature in feature_visibility:
            feature_visibility[feature] = user_visibility[feature] == True
    frappe.response["message"] = {
        "status": "success",
        "current_user": current_user,
        "can_create": can_create_visit,
        "can_view_opportunities": has_sales_manager_role,
        "can_view_visits": True,
        "can_create_lead": can_create_lead,
        "can_view_pending": can_view_pending,
        "can_track": can_track,
        "feature_visibility": feature_visibility,
    }

elif action == "get":
    opportunities = get_opportunities()
    user_rows = frappe.get_all(
        "User",
        filters={"enabled": 1, "user_type": "System User"},
        fields=["name", "full_name"],
        order_by="full_name asc",
        limit_page_length=500,
    )
    location_type_config = get_location_types()
    location_types = location_type_config["options"]
    current_user_found = False
    for row in user_rows:
        if row.name == current_user:
            current_user_found = True
            break
    if not current_user_found:
        user_rows.append(
            {
                "name": current_user,
                "full_name": frappe.db.get_value("User", current_user, "full_name")
                or current_user,
            }
        )

    event_category_options = get_event_category_config()["options"]
    frappe.response["message"] = {
        "status": "success",
        "action": "get",
        "current_user": current_user,
        "opportunities": opportunities,
        "product_enquired_options": get_product_options(),
        "event_categories": event_category_options,
        "schedule_policy": schedule_policy,
        "business_policy": business_policy,
        "event_location_types": business_policy["rules"]["location_types"],
        "event_category_rules": {
            category: get_category_rule(category)
            for category in event_category_options
        },
        "location_types": location_types,
        "users": user_rows,
        # Server Script safe_exec blocks the token helper; read the active
        # session token directly, as used by the mobile task API.
        "csrf_token": frappe.session.get("csrf_token") or frappe.session.data.csrf_token,
    }

elif action == "get_references":
    requested_category = (frappe.form_dict.get("category") or "").strip()
    allowed_categories = get_event_category_config()["options"]
    if "".join(requested_category.lower().split()) not in [
        "".join(value.lower().split()) for value in allowed_categories
    ]:
        frappe.throw("Choose a valid event category.")
    # These two routes use their own permission-filtered documents, never
    # Opportunity or Lead records. Metadata supplies the display title only.
    category_rule = get_category_rule(requested_category)
    if category_rule["reference_mode"] != "document":
        frappe.throw("Choose Measurement or Installation to select a reference.")
    reference_doctype = category_rule["reference_doctype"]
    phone_field = REFERENCE_DOCUMENT_FIELDS[reference_doctype][0]
    detail_field = REFERENCE_DOCUMENT_FIELDS[reference_doctype][1]
    reference_meta = frappe.get_meta(reference_doctype)
    reference_fields = field_names(reference_meta)
    for required_field in [phone_field, detail_field]:
        if required_field not in reference_fields:
            frappe.throw(reference_doctype + " is missing its " + required_field + " field.")
    title_field = reference_meta.title_field
    fields = ["name", phone_field, detail_field]
    if title_field and title_field in reference_fields and title_field not in fields:
        fields.append(title_field)
    mobile = (frappe.form_dict.get("mobile") or "").strip()
    query_digits = digits_only(mobile)
    if mobile and len(query_digits) < 5:
        frappe.throw("Enter at least 5 digits of the mobile number.")
    filters = {"docstatus": ["<", 2]}
    if mobile:
        filters[phone_field] = ["like", "%" + "%".join(query_digits) + "%"]
    reference_rows = frappe.get_list(
        reference_doctype, filters=filters, fields=fields,
        order_by="modified desc", limit_page_length=500,
    )
    references = []
    for row in reference_rows:
        if not mobile or query_digits in digits_only(row.get(phone_field)):
            references.append({
                "name": row.name,
                "title": row.get(title_field) if title_field else row.name,
                "mobile": row.get(phone_field) or "",
                "company": row.get("company") or "",
            })
    frappe.response["message"] = {
        "status": "success", "action": "get_references",
        "current_user": current_user, "reference_doctype": reference_doctype,
        "references": references, "csrf_token": frappe.session.get("csrf_token") or frappe.session.data.csrf_token,
    }

elif action == "search_by_mobile":
    query_digits = digits_only(frappe.form_dict.get("mobile"))
    if len(query_digits) < 5:
        frappe.throw("Enter at least 5 digits of the mobile number.")

    matches = get_opportunities(query_digits)

    frappe.response["message"] = {
        "status": "success",
        "action": "search_by_mobile",
        "current_user": current_user,
        "opportunities": matches,
        "csrf_token": frappe.session.get("csrf_token") or frappe.session.data.csrf_token,
    }

elif action == "search_opportunities":
    text_query = frappe.form_dict.get("query") or ""
    if not isinstance(text_query, str):
        frappe.throw("Enter an Opportunity ID or name.")
    text_query = text_query.strip()
    if len(text_query) < 2 or len(text_query) > 140:
        frappe.throw("Enter between 2 and 140 characters of the Opportunity ID or name.")
    frappe.response["message"] = {
        "status": "success",
        "action": "search_opportunities",
        "current_user": current_user,
        "opportunities": get_opportunities(text_query=text_query),
        "csrf_token": frappe.session.get("csrf_token") or frappe.session.data.csrf_token,
    }

elif action == "save_location":
    opportunity_name = (frappe.form_dict.get("opportunity") or "").strip()
    map_link = (frappe.form_dict.get("map_link") or "").strip()
    location_type = (frappe.form_dict.get("location_type") or "").strip()
    latitude = frappe.utils.flt(frappe.form_dict.get("latitude"))
    longitude = frappe.utils.flt(frappe.form_dict.get("longitude"))

    if not opportunity_name or not map_link or not location_type:
        frappe.throw("Opportunity, map link, and location type are required.")
    if latitude < -90 or latitude > 90 or longitude < -180 or longitude > 180:
        frappe.throw("The map link must resolve to valid coordinates.")

    opportunity = get_opportunity(opportunity_name)
    if not opportunity:
        frappe.throw("Choose an existing opportunity.")

    location_type_config = get_location_types()
    allowed_types = location_type_config["options"]
    location_type_free_text = location_type_config["free_text"]
    if not location_type_free_text and location_type not in allowed_types:
        frappe.throw("Choose a valid location type.")

    location_table = get_opportunity_location_table()
    table_field = location_table["table_field"]
    child_meta = location_table["child_meta"]
    child_fields = field_names(child_meta)
    location_row = {"doctype": child_meta.name}
    required_values = {
        "location": map_link,
        "latitude": latitude,
        "longitude": longitude,
        "location_type": location_type,
    }
    for fieldname in required_values:
        if fieldname not in child_fields:
            frappe.throw("Customer Location is missing the " + fieldname + " field.")
        location_row[fieldname] = required_values[fieldname]

    opportunity.append(table_field.fieldname, location_row)
    opportunity.save()
    saved_row = opportunity.get(table_field.fieldname)[-1]

    frappe.response["message"] = {
        "status": "success",
        "action": "save_location",
        "current_user": current_user,
        "opportunity": opportunity.name,
        "location_row": saved_row.name,
        "csrf_token": frappe.session.get("csrf_token") or frappe.session.data.csrf_token,
    }

elif action == "create_event":
    opportunity_name = (frappe.form_dict.get("opportunity") or "").strip()
    location_row_name = (frappe.form_dict.get("location_row") or "").strip()
    summary = (frappe.form_dict.get("summary") or "").strip()
    starts_on_value = (frappe.form_dict.get("starts_on") or "").strip()
    ends_on_value = (frappe.form_dict.get("ends_on") or "").strip()
    assigned_to = (frappe.form_dict.get("assigned_to") or "").strip()
    category = (frappe.form_dict.get("category") or "").strip()
    product_enquired = (frappe.form_dict.get("product_enquired") or "").strip()

    category_config = get_event_category_config()
    if category not in category_config["options"]:
        frappe.throw("Choose a valid event category.")
    category_rule = get_category_rule(category)
    direct_event = category_rule["reference_mode"] == "none"
    required_values = [
        summary if business_policy["fields"]["summary"]["required"] else "optional",
        starts_on_value,
        ends_on_value,
        assigned_to,
        category,
    ]
    missing_required_value = False
    for value in required_values:
        if not value:
            missing_required_value = True
            break
    if missing_required_value:
        frappe.throw("Start/end times, event category, assignee, and summary are required.")
    frappe.call("mobile_business_policy", feature="visit", action="validate", original_values={}, event_id="", values={
        "summary": summary, "assigned_to": assigned_to, "product_enquired": product_enquired,
    })

    reference_doctype = (
        category_rule["reference_doctype"]
        if category_rule["reference_mode"] == "document" else None
    )
    reference_name = (frappe.form_dict.get("reference_name") or "").strip()
    supplied_doctype = (frappe.form_dict.get("reference_doctype") or "").strip()
    reference_doc = None
    if reference_doctype:
        if opportunity_name or location_row_name:
            frappe.throw("This category must reference " + reference_doctype + ", not Opportunity.")
        if supplied_doctype and supplied_doctype != reference_doctype:
            frappe.throw("The reference DocType does not match the event category.")
        if not reference_name or not frappe.db.exists(reference_doctype, reference_name):
            frappe.throw("Choose an existing " + reference_doctype + ".")
        reference_doc = frappe.get_doc(reference_doctype, reference_name)
        reference_doc.check_permission("read")
        if reference_doc.get("docstatus") == 2:
            frappe.throw("A cancelled document cannot be selected for this visit.")
        if product_enquired:
            frappe.throw("Company is a reference detail, not Product enquired.")
    elif reference_name or supplied_doctype:
        frappe.throw("This event category does not accept a Measurement or Installation Note reference.")

    opportunity = None
    saved_location = None
    if direct_event:
        if opportunity_name or location_row_name:
            frappe.throw("This category does not use an Opportunity location.")
    elif reference_doctype:
        if opportunity_name or location_row_name:
            frappe.throw("This category uses an Event location without an Opportunity.")
        map_link = (frappe.form_dict.get("map_link") or "").strip()
        location_type = (frappe.form_dict.get("location_type") or "").strip()
        latitude_value = str(frappe.form_dict.get("latitude") or "").strip()
        longitude_value = str(frappe.form_dict.get("longitude") or "").strip()
        if not map_link or not latitude_value or not longitude_value:
            frappe.throw("Choose an Event map location with valid coordinates.")
        # float() rejects nonnumeric input; comparisons also reject NaN/infinity.
        latitude = float(latitude_value)
        longitude = float(longitude_value)
        if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
            frappe.throw("Choose valid Event coordinates.")
        if location_type not in business_policy["rules"]["location_types"]:
            frappe.throw("Choose a valid location type.")
        # Embed resolved coordinates so eventSelectedLocations can read
        # custom_validate directly, even when the original link was shortened.
        saved_location = {
            "name": "",
            "location": "https://www.google.com/maps/search/?api=1&query="
                + str(latitude) + "," + str(longitude),
            "latitude": latitude,
            "longitude": longitude,
            "location_type": location_type,
        }
    else:
        if not opportunity_name or not location_row_name:
            frappe.throw("Opportunity and location are required for this category.")
        opportunity = get_opportunity(opportunity_name)
        if not opportunity:
            frappe.throw("Choose an existing opportunity.")
        location_table = get_opportunity_location_table()
        table_field = location_table["table_field"]
        saved_location = None
        for row in opportunity.get(table_field.fieldname) or []:
            if row.name == location_row_name:
                saved_location = {
                    "name": row.name,
                    "location": row.location,
                    "location_type": row.location_type,
                    "latitude": row.latitude,
                    "longitude": row.longitude,
                }
                break
        if not saved_location:
            frappe.throw("The selected location does not belong to this opportunity.")

    assigned_user = frappe.db.get_value(
        "User", {"name": assigned_to, "enabled": 1}, ["name", "full_name"], as_dict=True
    )
    if not assigned_user:
        frappe.throw("Choose an enabled ERP user to assign this event to.")

    starts_on = frappe.utils.get_datetime(starts_on_value)
    ends_on = frappe.utils.get_datetime(ends_on_value)
    for value in [starts_on, ends_on]:
        if value.minute % schedule_policy["interval_minutes"] or value.second or value.microsecond:
            frappe.throw("Start and end times must use " + str(schedule_policy["interval_minutes"]) + "-minute intervals.")
    if not schedule_policy["allow_past"] and starts_on < frappe.utils.now_datetime():
        frappe.throw("The visit start time cannot be in the past.")
    if schedule_policy["earliest_booking_date"] and str(starts_on.date()) < schedule_policy["earliest_booking_date"]:
        frappe.throw("Choose a visit date on or after " + schedule_policy["earliest_booking_date"] + ".")
    if ends_on <= starts_on:
        frappe.throw("The visit end time must be after the start time.")
    if product_enquired and product_enquired not in get_product_options():
        frappe.throw("Choose a valid product enquired.")
    event_meta = frappe.get_meta("Event")
    event_fields = field_names(event_meta)
    if "ends_on" not in event_fields:
        frappe.throw("Event is missing its ends_on field.")
    if product_enquired and "custom_product_enquired" not in event_fields:
        frappe.throw("Event is missing its custom_product_enquired field.")
    if saved_location:
        if "location" not in event_fields and "custom_location_type" not in event_fields:
            frappe.throw("Event needs a location field to save the selected Home/Site/Others type.")
        if "custom_location" not in event_fields and "custom_validate" not in event_fields:
            frappe.throw("Event needs a map location field to save the selected customer coordinates.")

        if reference_doctype and "custom_validate" not in event_fields:
            frappe.throw("Event needs custom_validate to save this category location.")
    category_field = category_config["fieldname"]

    event_doc = frappe.new_doc("Event")
    event_doc.subject = summary
    event_doc.starts_on = starts_on
    event_doc.ends_on = ends_on
    event_doc.set(category_field, category)
    if saved_location:
        # Keep the human-readable type separate from the map URL. The app's
        # existing updateEventLocationType also uses Event.location for this type.
        if "location" in event_fields:
            event_doc.location = saved_location["location_type"]
        if "custom_location" in event_fields:
            event_doc.custom_location = saved_location["location"]
        if "custom_location_type" in event_fields:
            event_doc.custom_location_type = saved_location["location_type"]
        # Existing event-location reporting reads the map URL from this field.
        if "custom_validate" in event_fields:
            event_doc.custom_validate = saved_location["location"]
    if "assigned_to" in event_fields:
        event_doc.assigned_to = assigned_to
    if product_enquired:
        event_doc.custom_product_enquired = product_enquired

    reference_linked = False
    for candidate in ["event_participants", "participants"]:
        field = event_meta.get_field(candidate)
        if field and field.fieldtype == "Table":
            participant_meta = frappe.get_meta(field.options)
            participant_fields = field_names(participant_meta)
            if reference_doctype and (
                "reference_doctype" not in participant_fields
                or "reference_docname" not in participant_fields
            ):
                continue
            participant_row = {"doctype": field.options}
            participant_values = {
                "reference_doctype": reference_doctype or ("Opportunity" if opportunity else "User"),
                "reference_docname": reference_name if reference_doc else (opportunity.name if opportunity else assigned_to),
                "email": assigned_to,
                "user": assigned_to,
                "assigned_to": assigned_to,
                "full_name": assigned_user.full_name or assigned_to,
                "role": "Required",
            }
            for fieldname in participant_values:
                if fieldname in participant_fields:
                    participant_row[fieldname] = participant_values[fieldname]
            event_doc.append(candidate, participant_row)
            reference_linked = True
            break

    if reference_doctype and not reference_linked:
        frappe.throw("Event needs a participant table with document reference fields.")
    event_doc.insert()

    if saved_location:
        # Keep the coordinate comment used by the existing Event location report.
        # Coordinates come from the saved Opportunity row or the direct Event pin.
        coordinate_comment = frappe.get_doc(
            {
                "doctype": "Comment",
                "comment_type": "Comment",
                "reference_doctype": "Event",
                "reference_name": event_doc.name,
                "subject": str(saved_location["latitude"])
                + ","
                + str(saved_location["longitude"]),
                "content": saved_location["location"],
            }
        )
        coordinate_comment.insert(ignore_permissions=True)

    # Add a Frappe assignment record so the Event appears in the assignee's work list.
    todo = frappe.get_doc(
        {
            "doctype": "ToDo",
            "allocated_to": assigned_to,
            "description": summary,
            "reference_type": "Event",
            "reference_name": event_doc.name,
            "status": "Open",
            "date": starts_on.date(),
        }
    )
    todo.insert(ignore_permissions=True)

    # Call while the API's HTTP request exists. This site's safe_enqueue
    # routes whitelisted calls through HTTP method validation in a worker,
    # which fails there with AttributeError: request.
    alarm_sent = False
    try:
        alarm_result = frappe.call(
            "itgenie.fcm.fcm_utils.send_fcm_to_user",
            user=assigned_to,
            payload={
                "type": "EVENT_ASSIGNED",
                "doctype": "Event",
                "docname": event_doc.name,
                "assignment_id": todo.name,
                "for_user": assigned_to,
                "title": "New event assigned",
                "body": summary,
            },
        )
        if isinstance(alarm_result, dict) and alarm_result.get("status") == "sent":
            alarm_sent = True
        else:
            alarm_failure = "FCM sender did not confirm delivery acceptance."
            if isinstance(alarm_result, dict) and alarm_result.get("message"):
                alarm_failure = str(alarm_result.get("message"))
            frappe.log_error(
                title="Mobile Event assignment alarm failed",
                message="Event " + event_doc.name + ": " + alarm_failure,
            )
    except Exception as alarm_error:
        # Keep the existing Event/ToDo save when notification delivery fails.
        frappe.log_error(
            title="Mobile Event assignment alarm failed",
            message="Event " + event_doc.name + ": " + str(alarm_error),
        )

    frappe.response["message"] = {
        "status": "success",
        "action": "create_event",
        "current_user": current_user,
        "event": event_doc.name,
        "alarm_queued": False,
        "alarm_sent": alarm_sent,
        "reference_doctype": reference_doctype or ("Opportunity" if opportunity else ""),
        "reference_name": reference_name if reference_doc else (opportunity.name if opportunity else ""),
        "opportunity": opportunity.name if opportunity else "",
        "location_row": saved_location["name"] if saved_location else "",
        "location_type": saved_location["location_type"] if saved_location else "",
        "csrf_token": frappe.session.get("csrf_token") or frappe.session.data.csrf_token,
    }

else:
    frappe.throw(
        "Invalid action. Use get, get_references, search_by_mobile, search_opportunities, save_location, or create_event."
    )
