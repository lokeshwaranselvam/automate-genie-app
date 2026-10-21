# Frappe Server Script settings:
#   Script Type: API
#   API Method: mobile_site_visit
#   Allow Guest: Disabled
#   Enable Rate Limit: Enabled
#
# GET  /api/method/mobile_site_visit?action=can_create
# GET  /api/method/mobile_site_visit?action=get
# GET  /api/method/mobile_site_visit?action=search_by_mobile&mobile=98765
# POST /api/method/mobile_site_visit
#   action=save_location, opportunity, map_link, latitude, longitude,
#   location_type
#   action=create_event, opportunity, location_row, summary, starts_on, ends_on,
#   assigned_to, category, product_enquired (optional)

action = (frappe.form_dict.get("action") or "get").strip().lower()
current_user = frappe.session.user

if not current_user or current_user == "Guest":
    frappe.throw("Sign in to create a site visit.")

can_create_visit = bool(frappe.db.exists(
    "Has Role",
    {"parent": current_user, "parenttype": "User", "parentfield": "roles",
     "role": "Sales Manager"},
))
if action != "can_create" and not can_create_visit:
    frappe.throw("Only users with the Sales Manager role can create site visits.")


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


def get_opportunities(query_digits=None):
    """Fetch form fields only for the dropdown or matching phone results."""
    opportunity_meta = frappe.get_meta("Opportunity")
    available = field_names(opportunity_meta)
    title_field = "party_name"
    for candidate in [
        "title", opportunity_meta.title_field, "opportunity_name", "customer_name",
    ]:
        if candidate and candidate in available:
            title_field = candidate
            break
    opportunity_fields = ["name", "owner"]
    for candidate in [
        title_field, "party_name", "custom_product_enquired", "opportunity_owner",
    ]:
        if candidate in available and candidate not in opportunity_fields:
            opportunity_fields.append(candidate)
    filters = {}
    if query_digits:
        names = get_mobile_opportunity_names(opportunity_meta, query_digits)
        if not names:
            return []
        filters = {"name": ["in", names]}

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
            "title": row.get(title_field) or row.get("party_name") or row.name,
            "party_name": row.get("party_name") or "",
            "product_enquired": product,
            "assigned_to": (
                row.get("opportunity_owner") or row.get("owner") or current_user
            ).strip(),
        }
        results.append(entry)
    return results


if action == "can_create":
    frappe.response["message"] = {
        "status": "success",
        "current_user": current_user,
        "can_create": can_create_visit,
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

    frappe.response["message"] = {
        "status": "success",
        "action": "get",
        "current_user": current_user,
        "opportunities": opportunities,
        "product_enquired_options": get_product_options(),
        "event_categories": get_event_category_config()["options"],
        "location_types": location_types,
        "users": user_rows,
        # Server Script safe_exec blocks the token helper; read the active
        # session token directly, as used by the mobile task API.
        "csrf_token": frappe.session.data.csrf_token,
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
        "csrf_token": frappe.session.data.csrf_token,
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
        "csrf_token": frappe.session.data.csrf_token,
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

    required_values = [
        opportunity_name,
        location_row_name,
        summary,
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
        frappe.throw("Opportunity, location, start/end times, event category, assignee, and summary are required.")

    opportunity = get_opportunity(opportunity_name)
    if not opportunity:
        frappe.throw("Choose an existing opportunity.")
    location_table = get_opportunity_location_table()
    table_field = location_table["table_field"]
    saved_location = None
    for row in opportunity.get(table_field.fieldname) or []:
        if row.name == location_row_name:
            saved_location = row
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
        if value.minute % 15 or value.second or value.microsecond:
            frappe.throw("Start and end times must use 15-minute intervals.")
    if starts_on < frappe.utils.now_datetime():
        frappe.throw("The visit start time cannot be in the past.")
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
    if "location" not in event_fields and "custom_location_type" not in event_fields:
        frappe.throw("Event needs a location field to save the selected Home/Site/Others type.")
    if "custom_location" not in event_fields and "custom_validate" not in event_fields:
        frappe.throw("Event needs a map location field to save the selected customer coordinates.")

    category_config = get_event_category_config()
    if category not in category_config["options"]:
        frappe.throw("Choose a valid event category.")
    category_field = category_config["fieldname"]

    event_doc = frappe.new_doc("Event")
    event_doc.subject = summary
    event_doc.starts_on = starts_on
    event_doc.ends_on = ends_on
    event_doc.set(category_field, category)
    # Keep the human-readable type separate from the map URL. The app's
    # existing updateEventLocationType also uses Event.location for this type.
    if "location" in event_fields:
        event_doc.location = saved_location.location_type
    if "custom_location" in event_fields:
        event_doc.custom_location = saved_location.location
    if "custom_location_type" in event_fields:
        event_doc.custom_location_type = saved_location.location_type
    # Existing event-location reporting reads the map URL from this field.
    if "custom_validate" in event_fields:
        event_doc.custom_validate = saved_location.location
    if "assigned_to" in event_fields:
        event_doc.assigned_to = assigned_to
    if product_enquired:
        event_doc.custom_product_enquired = product_enquired

    for candidate in ["event_participants", "participants"]:
        field = event_meta.get_field(candidate)
        if field and field.fieldtype == "Table":
            participant_meta = frappe.get_meta(field.options)
            participant_fields = field_names(participant_meta)
            participant_row = {"doctype": field.options}
            participant_values = {
                "reference_doctype": "Opportunity",
                "reference_docname": opportunity.name,
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
            break

    event_doc.insert()

    # Keep the coordinate comment used by the existing Event location report.
    # The source of truth remains the latitude/longitude columns on the saved
    # Opportunity location child row.
    coordinate_comment = frappe.get_doc(
        {
            "doctype": "Comment",
            "comment_type": "Comment",
            "reference_doctype": "Event",
            "reference_name": event_doc.name,
            "subject": str(saved_location.latitude)
            + ","
            + str(saved_location.longitude),
            "content": saved_location.location,
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

    frappe.response["message"] = {
        "status": "success",
        "action": "create_event",
        "current_user": current_user,
        "event": event_doc.name,
        "opportunity": opportunity.name,
        "location_row": saved_location.name,
        "location_type": saved_location.location_type,
        "csrf_token": frappe.session.data.csrf_token,
    }

else:
    frappe.throw(
        "Invalid action. Use get, search_by_mobile, save_location, or create_event."
    )
