# Frappe Server Script settings:
#   Script Type: API
#   API Method: mobile_site_visit
#   Allow Guest: Disabled
#   Enable Rate Limit: Enabled
#
# GET  /api/method/mobile_site_visit?action=get
# POST /api/method/mobile_site_visit
#   action=save_location, opportunity, map_link, latitude, longitude,
#   location_type
#   action=create_event, opportunity, location_row, summary, starts_on,
#   assigned_to, category=Installation

action = (frappe.form_dict.get("action") or "get").strip().lower()
current_user = frappe.session.user

if not current_user or current_user == "Guest":
    frappe.throw("Sign in to create a site visit.")


def opportunity_owned_by_user(opportunity_name):
    if not opportunity_name:
        return None
    if not frappe.db.exists(
        "Opportunity", {"name": opportunity_name, "owner": current_user}
    ):
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

    if location_field.fieldtype not in ["Select", "Link", "Data", "Small Text", "Text"]:
        frappe.throw("Opportunity location_type must be a Select, Link, or text field.")

    # The mobile form uses these fixed choices regardless of field type. Any
    # Select/Link storage requirements are checked when a location is saved.
    return {"options": ["Site", "Home", "Others"], "free_text": False}


if action == "get":
    opportunity_meta = frappe.get_meta("Opportunity")
    opportunity_fields = ["name", "owner"]
    for candidate in ["opportunity_name", "party_name", "customer_name"]:
        if candidate in field_names(opportunity_meta):
            opportunity_fields.append(candidate)

    opportunities = frappe.get_all(
        "Opportunity",
        filters={"owner": current_user},
        fields=opportunity_fields,
        order_by="modified desc",
        limit_page_length=500,
    )
    user_rows = frappe.get_all(
        "User",
        filters={"enabled": 1, "user_type": "System User"},
        fields=["name", "full_name"],
        order_by="full_name asc",
        limit_page_length=500,
    )
    location_type_config = get_location_types()
    location_types = location_type_config["options"]
    location_type_free_text = location_type_config["free_text"]
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
        "location_types": location_types,
        "location_type_free_text": location_type_free_text,
        "users": user_rows,
        # Server Script safe_exec blocks the token helper; read the active
        # session token directly, as used by the mobile task API.
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

    opportunity = opportunity_owned_by_user(opportunity_name)
    if not opportunity:
        frappe.throw("Choose an opportunity created by your signed-in user.")

    location_type_config = get_location_types()
    allowed_types = location_type_config["options"]
    if location_type not in allowed_types:
        frappe.throw("Choose a valid location type: Site, Home, or Others.")

    location_table = get_opportunity_location_table()
    table_field = location_table["table_field"]
    child_meta = location_table["child_meta"]
    location_type_field = child_meta.get_field("location_type")
    if location_type_field.fieldtype == "Select":
        configured_options = [
            option.strip()
            for option in (location_type_field.options or "").splitlines()
            if option.strip()
        ]
        if location_type not in configured_options:
            frappe.throw(
                "Add Site, Home, and Others to the Opportunity location_type Select options."
            )
    elif location_type_field.fieldtype == "Link":
        if not frappe.db.exists(location_type_field.options, location_type):
            frappe.throw(
                "Create Site, Home, and Others records in "
                + location_type_field.options
                + " for the Opportunity location_type Link field."
            )
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
        "location": map_link,
        "latitude": latitude,
        "longitude": longitude,
        "location_type": location_type,
        "csrf_token": frappe.session.data.csrf_token,
    }

elif action == "create_event":
    opportunity_name = (frappe.form_dict.get("opportunity") or "").strip()
    location_row_name = (frappe.form_dict.get("location_row") or "").strip()
    summary = (frappe.form_dict.get("summary") or "").strip()
    starts_on_value = (frappe.form_dict.get("starts_on") or "").strip()
    assigned_to = (frappe.form_dict.get("assigned_to") or "").strip()
    category = (frappe.form_dict.get("category") or "").strip()

    required_values = [
        opportunity_name,
        location_row_name,
        summary,
        starts_on_value,
        assigned_to,
    ]
    missing_required_value = False
    for value in required_values:
        if not value:
            missing_required_value = True
            break
    if missing_required_value:
        frappe.throw("Opportunity, location, date, assignee, and summary are required.")
    if category != "Installation":
        frappe.throw("The only supported site visit category is Installation.")

    opportunity = opportunity_owned_by_user(opportunity_name)
    if not opportunity:
        frappe.throw("Choose an opportunity created by your signed-in user.")
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
    ends_on = frappe.utils.add_to_date(starts_on, hours=1)
    event_meta = frappe.get_meta("Event")
    event_fields = field_names(event_meta)

    category_field = None
    for candidate in ["event_category", "custom_event_category", "event_type"]:
        field = event_meta.get_field(candidate)
        if not field:
            continue
        options = [option.strip() for option in (field.options or "").splitlines()]
        valid_link = (
            field.fieldtype == "Link"
            and field.options
            and frappe.db.exists(field.options, category)
        )
        if not options or category in options or valid_link:
            category_field = candidate
            break
    if not category_field:
        frappe.throw("Event does not have a category field with the Installation option.")

    event_doc = frappe.new_doc("Event")
    event_doc.subject = summary
    event_doc.starts_on = starts_on
    if "ends_on" in event_fields:
        event_doc.ends_on = ends_on
    event_doc.set(category_field, category)
    if "location" in event_fields:
        event_doc.location = saved_location.location
    if "custom_location" in event_fields:
        event_doc.custom_location = saved_location.location
    if "custom_location_type" in event_fields:
        event_doc.custom_location_type = saved_location.location_type
    # Existing event-location reporting reads the map URL from this field.
    if "custom_validate" in event_fields:
        event_doc.custom_validate = saved_location.location
    if "assigned_to" in event_fields:
        event_doc.assigned_to = assigned_to

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
        "category": category,
        "assigned_to": assigned_to,
        "csrf_token": frappe.session.data.csrf_token,
    }

else:
    frappe.throw("Invalid action. Use get, save_location, or create_event.")
