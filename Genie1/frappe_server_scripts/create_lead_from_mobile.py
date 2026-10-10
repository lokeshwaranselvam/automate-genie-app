# Frappe Server Script settings:
#   Script Type: API
#   API Method: create_lead_from_mobile
#   Allow Guest: Disabled
#   Enable Rate Limit: Enabled

current_user = frappe.session.user
if not current_user or current_user == "Guest":
    frappe.throw("Please sign in before creating a Lead.")


def get_lead_field_options(lead_meta, fieldname, label):
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
        rows = frappe.get_all(
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
    return options


if frappe.request.method == "GET":
    # The mobile form reads these two arrays to populate its dropdowns.
    lead_meta = frappe.get_meta("Lead")
    source_options = get_lead_field_options(
        lead_meta, "custom_source", "Lead Source"
    )
    product_category_options = get_lead_field_options(
        lead_meta, "custom_product_category", "Product Category"
    )
    frappe.response["message"] = {
        "lead_owner": current_user,
        "lead_owner_name": frappe.db.get_value("User", current_user, "full_name")
        or current_user,
        "source_options": source_options,
        "product_category_options": product_category_options,
        "csrf_token": frappe.session.data.csrf_token,
    }

elif frappe.request.method == "POST":
    first_name = (frappe.form_dict.get("first_name") or "").strip()
    mobile_no = (frappe.form_dict.get("mobile_no") or "").strip()
    requirement = (frappe.form_dict.get("custom_requirement") or "").strip()
    source = (frappe.form_dict.get("custom_source") or "").strip()
    product_category = (
        frappe.form_dict.get("custom_product_category") or ""
    ).strip()
    address = (frappe.form_dict.get("custom_address") or "").strip()

    if not first_name:
        frappe.throw("Customer Name is required.")
    if not mobile_no:
        frappe.throw("Phone Number is required.")
    if not requirement:
        frappe.throw("Requirement is required.")
    if not source:
        frappe.throw("Lead Source is required.")
    if not product_category:
        frappe.throw("Product Category is required.")
    if not address:
        frappe.throw("Location is required.")

    lead_meta = frappe.get_meta("Lead")
    source_options = get_lead_field_options(
        lead_meta, "custom_source", "Lead Source"
    )
    product_category_options = get_lead_field_options(
        lead_meta, "custom_product_category", "Product Category"
    )
    if source not in source_options:
        frappe.throw("Choose a Lead Source from the configured options.")
    if product_category not in product_category_options:
        frappe.throw("Choose a Product Category from the configured options.")

    lead = frappe.new_doc("Lead")
    lead.first_name = first_name
    lead.lead_owner = current_user
    lead.mobile_no = mobile_no
    lead.custom_requirement = requirement
    lead.custom_source = source
    lead.custom_product_category = product_category
    lead.custom_address = address
    lead.flags.ignore_mandatory = True
    lead.insert(ignore_permissions=True)

    frappe.response["message"] = {
        "status": "success",
        "name": lead.name,
        "first_name": lead.first_name,
        "lead_owner": lead.lead_owner,
        "mobile_no": lead.mobile_no,
        "custom_requirement": lead.custom_requirement,
        "custom_source": lead.custom_source,
        "custom_product_category": lead.custom_product_category,
        "custom_address": lead.custom_address,
    }

else:
    frappe.throw("Use GET to load the form or POST to create a Lead.")
