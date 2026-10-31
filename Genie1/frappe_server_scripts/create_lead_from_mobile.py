# Frappe Server Script settings:
#   Script Type: API
#   API Method: create_lead_from_mobile
#   Allow Guest: Disabled
#   Enable Rate Limit: Enabled

current_user = frappe.session.user
if not current_user or current_user == "Guest":
    frappe.throw("Please sign in before creating a Lead.")


lead_view = (frappe.form_dict.get("view") or "").strip()
request_method = (frappe.request.method or "").upper()
if request_method == "POST" and not frappe.db.exists(
    "Has Role",
    {"parent": current_user, "parenttype": "User", "parentfield": "roles",
     "role": ["in", ["Sales User", "Sales Manager"]]},
):
    frappe.throw("Only users with the Sales User or Sales Manager role can create Leads.")

lead_meta = frappe.get_meta("Lead")
lead_fields = ["name"]
lead_fields.extend(["owner", "creation", "modified", "modified_by", "docstatus"])
for fieldname in [
    "lead_name", "first_name", "mobile_no", "phone", "email_id", "status",
    "lead_owner", "company_name", "territory", "source",
    "custom_requirement", "custom_product_enquired", "custom_address",
    "custom_pincode", "custom_sales_person", "custom_customer_category",
    "whatsapp_no",
    "naming_series",
]:
    if lead_meta.get_field(fieldname):
        lead_fields.append(fieldname)

if request_method == "GET" and lead_view == "location_options":
    fieldname = frappe.form_dict.get("fieldname") or ""
    txt = frappe.form_dict.get("txt") or ""
    if fieldname not in ["custom_citytown", "custom_district"]:
        frappe.throw("Invalid Lead location field.")
    if not isinstance(txt, str) or len(txt) > 140:
        frappe.throw("Search text must be at most 140 characters.")
    field = lead_meta.get_field(fieldname)
    if not field or field.fieldtype not in ["Select", "Link"] or not field.options:
        frappe.throw("Configure Lead." + fieldname + " as a Select or Link field with options.")
    if field.fieldtype == "Select":
        matches = [{"value": option.strip()} for option in field.options.splitlines()
                   if option.strip() and txt.strip().lower() in option.lower()]
    else:
        matches = frappe.call("frappe.desk.search.search_link", doctype=field.options,
            txt=txt.strip(), page_length=20, reference_doctype="Lead", ignore_user_permissions=False)
    frappe.response["message"] = {"options": matches}

elif request_method == "GET" and lead_view == "list":
    leads = frappe.get_all(
        "Lead",
        filters={"lead_owner": current_user},
        fields=lead_fields,
        order_by="creation desc",
        limit_page_length=500,
    )
    frappe.response["message"] = {"leads": leads}

elif request_method == "GET" and lead_view == "detail":
    lead_name = (frappe.form_dict.get("lead") or "").strip()
    lead = frappe.db.get_value(
        "Lead",
        {"name": lead_name, "lead_owner": current_user},
        lead_fields,
        as_dict=True,
    ) if lead_name else None
    if not lead:
        frappe.throw("Lead not found or you are not allowed to view it.")
    frappe.response["message"] = {"lead": lead}

elif request_method == "GET":
    business_policy = frappe.call("mobile_business_policy", feature="lead", action="get", event_id="")["policy"]
    # Read dropdown choices from the actual Lead field metadata.
    lead_meta = frappe.get_meta("Lead")
    lead_options = {}
    for fieldname, label in [("source", "Lead Source"), ("custom_product_enquired", "Product Enquired"), ("custom_customer_category", "Customer Category")]:
        field = lead_meta.get_field(fieldname)
        if not field:
            frappe.throw("Lead is missing the " + fieldname + " field.")

        if field.fieldtype == "Select":
            options = [
                option.strip()
                for option in (field.options or "").splitlines()
                if option.strip()
            ]
        elif field.fieldtype == "Link" and field.options:
            rows = (frappe.get_list if fieldname == "custom_customer_category" else frappe.get_all)(
                field.options,
                fields=["name"],
                order_by="name asc",
                limit_page_length=1000,
            )
            options = [row.name for row in rows]
        else:
            frappe.throw(
                label
                + " (Lead."
                + fieldname
                + ") must be a Select or Link field; found field type '"
                + (field.fieldtype or "unknown")
                + "'."
            )

        if not options:
            if field.fieldtype == "Select":
                frappe.throw(
                    "Lead."
                    + fieldname
                    + " is a Select field with no values in its Options setting. "
                    + "Add the allowed "
                    + label
                    + " values in Customize Form > Lead."
                )
            frappe.throw(
                "Lead."
                + fieldname
                + " links to '"
                + field.options
                + "', but that DocType has no records to use as "
                + label
                + " options. Add records to '"
                + field.options
                + "'."
            )
        lead_options[fieldname] = options
    source_options = lead_options["source"]
    product_category_options = lead_options["custom_product_enquired"]
    customer_category_options = lead_options["custom_customer_category"]
    customer_category_field = lead_meta.get_field("custom_customer_category")
    if "custom_customer_category" not in business_policy["fields"]:
        business_policy["fields"]["custom_customer_category"] = {
            "required": bool(customer_category_field.get("reqd")),
            "visible": not bool(customer_category_field.get("hidden")),
            "read_only": bool(customer_category_field.get("read_only")),
            "default": customer_category_field.get("default") or "",
            "options": customer_category_options,
        }
    location_fields = {}
    for fieldname in ["custom_citytown", "custom_district"]:
        field = lead_meta.get_field(fieldname)
        if not field or field.fieldtype not in ["Select", "Link"] or not field.options:
            frappe.throw("Configure Lead." + fieldname + " as a Select or Link field with options.")
        location_fields[fieldname] = {
            "fieldtype": field.fieldtype,
            "options": [option.strip() for option in field.options.splitlines() if option.strip()]
                       if field.fieldtype == "Select" else [],
        }
    csrf_token = (
        frappe.session.get("csrf_token")
        or frappe.session.data.csrf_token
    )
    frappe.response["message"] = {
        "lead_owner": current_user,
        "lead_owner_name": frappe.db.get_value("User", current_user, "full_name")
        or current_user,
        "source_options": source_options,
        "product_category_options": product_category_options,
        "customer_category_options": customer_category_options,
        "csrf_token": csrf_token,
        "business_policy": business_policy,
        "location_fields": location_fields,
    }

elif request_method == "POST":
    business_policy = frappe.call("mobile_business_policy", feature="lead", action="get", event_id="")["policy"]
    first_name = (frappe.form_dict.get("first_name") or "").strip()
    mobile_no = (frappe.form_dict.get("mobile_no") or "").strip()
    whatsapp_no = frappe.form_dict.get("whatsapp_no") or ""
    if not isinstance(whatsapp_no, str):
        frappe.throw("Enter a valid WhatsApp number (7-15 digits).")
    whatsapp_no = whatsapp_no.strip()
    if not whatsapp_no and business_policy["fields"]["whatsapp_no"]["required"]:
        frappe.throw("WhatsApp Number is required.")
    if whatsapp_no:
        if len(whatsapp_no) > 64:
            frappe.throw("Enter a valid WhatsApp number (7-15 digits).")
        for character in whatsapp_no:
            if character not in "+0123456789 ().-":
                frappe.throw("Enter a valid WhatsApp number (7-15 digits).")
        for separator in [" ", "(", ")", ".", "-"]:
            whatsapp_no = whatsapp_no.replace(separator, "")
        whatsapp_digits = whatsapp_no[1:] if whatsapp_no.startswith("+") else whatsapp_no
        if len(whatsapp_digits) < 7 or len(whatsapp_digits) > 15 or whatsapp_no.startswith("+0"):
            frappe.throw("Enter a valid WhatsApp number (7-15 digits).")
        for digit in whatsapp_digits:
            if digit not in "0123456789":
                frappe.throw("Enter a valid WhatsApp number (7-15 digits).")
        if not lead_meta.get_field("whatsapp_no"):
            frappe.throw("Lead is missing the whatsapp_no field. Contact your administrator.")
    requirement = (frappe.form_dict.get("custom_requirement") or "").strip()
    source = (frappe.form_dict.get("source") or "").strip()
    product_category = (
        frappe.form_dict.get("custom_product_enquired") or ""
    ).strip()
    customer_category = frappe.form_dict.get("custom_customer_category") or ""
    if not isinstance(customer_category, str):
        frappe.throw("Choose a Customer Category from the configured options.")
    customer_category = customer_category.strip()
    customer_category_field = lead_meta.get_field("custom_customer_category")
    if not customer_category_field:
        frappe.throw("Lead is missing the custom_customer_category field.")
    if not customer_category and customer_category_field.get("reqd"):
        frappe.throw("Customer Category is required.")
    if customer_category_field.get("read_only") and customer_category != (customer_category_field.get("default") or ""):
        frappe.throw("Customer Category is read-only.")
    location_values = {}
    for fieldname, label in [("custom_citytown", "City/Town"), ("custom_district", "District")]:
        value = frappe.form_dict.get(fieldname) or ""
        if not isinstance(value, str) or not value.strip():
            frappe.throw(label + " is required.")
        value = value.strip()
        if len(value) > 140:
            frappe.throw("Choose a valid " + label + ".")
        field = lead_meta.get_field(fieldname)
        if not field or field.fieldtype not in ["Select", "Link"] or not field.options:
            frappe.throw("Configure Lead." + fieldname + " as a Select or Link field with options.")
        if field.fieldtype == "Select":
            if value not in [option.strip() for option in field.options.splitlines() if option.strip()]:
                frappe.throw("Choose " + label + " from the configured options.")
        else:
            allowed = frappe.get_list(field.options, filters={"name": value}, fields=["name"],
                limit_page_length=1, reference_doctype="Lead")
            if not allowed:
                frappe.throw("Choose an accessible " + label + " from the configured options.")
        location_values[fieldname] = value
    address = (frappe.form_dict.get("custom_address") or "").strip()

    if not first_name and business_policy["fields"]["first_name"]["required"]:
        frappe.throw("Customer Name is required.")
    if not mobile_no and business_policy["fields"]["mobile_no"]["required"]:
        frappe.throw("Phone Number is required.")
    if not requirement and business_policy["fields"]["custom_requirement"]["required"]:
        frappe.throw("Requirement is required.")
    if not source and business_policy["fields"]["source"]["required"]:
        frappe.throw("Lead Source is required.")
    if not product_category and business_policy["fields"]["custom_product_enquired"]["required"]:
        frappe.throw("Product Enquired is required.")
    if not address and business_policy["fields"]["custom_address"]["required"]:
        frappe.throw("Location is required.")
    frappe.call("mobile_business_policy", feature="lead", action="validate", original_values={}, values={
        "first_name": first_name, "mobile_no": mobile_no, "whatsapp_no": whatsapp_no,
        "custom_requirement": requirement, "source": source,
        "custom_product_enquired": product_category, "custom_address": address,
        "custom_customer_category": customer_category,
        "custom_citytown": location_values["custom_citytown"],
        "custom_district": location_values["custom_district"],
    })

    lead_meta = frappe.get_meta("Lead")
    lead_options = {}
    for fieldname, label in [("source", "Lead Source"), ("custom_product_enquired", "Product Enquired"), ("custom_customer_category", "Customer Category")]:
        field = lead_meta.get_field(fieldname)
        if not field:
            frappe.throw("Lead is missing the " + fieldname + " field.")

        if field.fieldtype == "Select":
            options = [
                option.strip()
                for option in (field.options or "").splitlines()
                if option.strip()
            ]
        elif field.fieldtype == "Link" and field.options:
            rows = (frappe.get_list if fieldname == "custom_customer_category" else frappe.get_all)(
                field.options,
                fields=["name"],
                order_by="name asc",
                limit_page_length=1000,
            )
            options = [row.name for row in rows]
        else:
            frappe.throw(
                label
                + " (Lead."
                + fieldname
                + ") must be a Select or Link field; found field type '"
                + (field.fieldtype or "unknown")
                + "'."
            )

        if not options:
            if field.fieldtype == "Select":
                frappe.throw(
                    "Lead."
                    + fieldname
                    + " is a Select field with no values in its Options setting. "
                    + "Add the allowed "
                    + label
                    + " values in Customize Form > Lead."
                )
            frappe.throw(
                "Lead."
                + fieldname
                + " links to '"
                + field.options
                + "', but that DocType has no records to use as "
                + label
                + " options. Add records to '"
                + field.options
                + "'."
            )
        lead_options[fieldname] = options
    source_options = lead_options["source"]
    product_category_options = lead_options["custom_product_enquired"]
    if source and source not in source_options:
        frappe.throw("Choose a Lead Source from the configured options.")
    if product_category and product_category not in product_category_options:
        frappe.throw("Choose a Product Enquired from the configured options.")

    if customer_category and customer_category not in lead_options["custom_customer_category"]:
        frappe.throw("Choose a Customer Category from the configured options.")

    # Retry guard: the client sends no idempotency key, so the same user
    # resubmitting the same customer within two minutes gets the earlier Lead.
    lead = None
    for recent_lead in frappe.get_all("Lead", filters={
        "owner": current_user, "first_name": first_name, "mobile_no": mobile_no,
    }, fields=["name", "creation"], order_by="creation desc", limit_page_length=1):
        if frappe.utils.time_diff_in_seconds(frappe.utils.now_datetime(), recent_lead.creation) <= 120:
            lead = frappe.get_doc("Lead", recent_lead.name)
    if not lead:
        lead = frappe.new_doc("Lead")
        lead.first_name = first_name
        lead.lead_owner = current_user
        lead.mobile_no = mobile_no
        if lead_meta.get_field("whatsapp_no"):
            lead.whatsapp_no = whatsapp_no
        lead.custom_requirement = requirement
        lead.source = source
        lead.custom_product_enquired = product_category
        lead.custom_citytown = location_values["custom_citytown"]
        lead.custom_district = location_values["custom_district"]
        lead.custom_address = address
        lead.custom_customer_category = customer_category
        lead.flags.ignore_mandatory = True
        lead.insert(ignore_permissions=True)

    frappe.response["message"] = {
        "status": "success",
        "name": lead.name,
        "first_name": lead.first_name,
        "lead_owner": lead.lead_owner,
        "mobile_no": lead.mobile_no,
        "whatsapp_no": whatsapp_no,
        "custom_requirement": lead.custom_requirement,
        "source": lead.source,
        "custom_product_enquired": lead.custom_product_enquired,
        "custom_address": lead.custom_address,
        "custom_citytown": lead.get("custom_citytown") or "",
        "custom_district": lead.get("custom_district") or "",
        "custom_customer_category": lead.get("custom_customer_category") or "",
    }

else:
    frappe.throw("Use GET to load the form or POST to create a Lead.")
