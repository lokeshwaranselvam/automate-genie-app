# Frappe Server Script (API) - Combined Sales + Production
# API Method: get_pending_work
# Allow Guest: Disabled
# No imports, function definitions, or return statements.
# Existing sales results and response keys are preserved.
# Company restrictions apply to PRODUCTION data only.

user = frappe.session.user
action = (frappe.form_dict.get("action") or "dashboard").strip().lower()
COMPANY = "Doortisan Creations Private Limited"

if not user or user == "Guest":
    frappe.throw("Please sign in.", frappe.PermissionError)

roles = frappe.get_all(
    "Has Role",
    filters={"parent": user, "parenttype": "User"},
    pluck="role",
    limit_page_length=100,
)

can_view_sales = "Sales User" in roles or "Sales Manager" in roles
can_view_production = (
    "Manufacturing User" in roles or "Manufacturing Manager" in roles
    or "Production Manager" in roles
)

if not can_view_sales and not can_view_production:
    frappe.throw(
        "Sales or Production team access required.",
        frappe.PermissionError
    )

production_actions = [
    "stock", "tasks", "work_orders",
    "job_cards", "manufacturing", "projects"
]

sales_actions = [
    "opportunities", "overdue_followups",
    "overdue_closing", "draft_delivery_plans"
]

valid_actions = ["dashboard"] + production_actions + sales_actions

if action not in valid_actions:
    frappe.throw(
        "Invalid action. Use: " + ", ".join(valid_actions)
    )

if action in production_actions and not can_view_production:
    frappe.throw(
        "Not permitted to view production pending work.",
        frappe.PermissionError
    )

if action in sales_actions and not can_view_sales:
    frappe.throw(
        "Not permitted to view sales pending work.",
        frappe.PermissionError
    )

available_sections = []

if can_view_production:
    available_sections.extend([
        "stock", "manufacturing", "projects"
    ])

if can_view_sales:
    available_sections.extend([
        "opportunities", "overdue_followups",
        "overdue_closing", "draft_delivery_plans"
    ])

is_dashboard = action == "dashboard"
page_limit = 5 if is_dashboard else 0

# =====================================================
# STOCK ENTRY FILTER - UPDATED
# =====================================================
# Only Stock Entries created by the session user.
# The owner field stores the creator's User ID.
# The displayed owner name is converted to Full Name.
# Existing company, workflow, and entry type preserved.
# =====================================================

stock_filters = {
    "company": COMPANY,
    "workflow_state": "Transfered",
    "stock_entry_type": "Material Transfer For Manufacture",
    "owner": user,
}

# =====================================================
# OTHER PRODUCTION FILTERS - UNCHANGED
# =====================================================

work_order_filters = {
    "company": COMPANY,
    "owner": user,
    "status": ["in", ["Not Started", "In Process"]],
}

job_card_filters = {
    "company": COMPANY,
    "owner": user,
    "status": ["not in", ["Completed", "Cancelled"]],
}

project_filters = {
    "company": COMPANY,
    "owner": user,
    "status": ["not in", ["Completed", "Cancelled", "Closed"]],
}

# =====================================================
# PRODUCTION DATA
# =====================================================

stock_rows = []
task_rows = []
work_order_rows = []
job_card_rows = []
project_rows = []

stock_count = 0
task_count = 0
work_order_count = 0
job_card_count = 0
project_count = 0

# -----------------------------------------------------
# STOCK ENTRIES - SESSION USER FILTERED
# -----------------------------------------------------

if can_view_production and action in ["dashboard", "stock"]:

    stock_rows = frappe.get_all(
        "Stock Entry",
        filters=stock_filters,
        fields=[
            "name",
            "posting_date",
            "stock_entry_type",
            "workflow_state",
            "owner"
        ],
        order_by="posting_date desc",
        limit_page_length=page_limit,
    )

    # Fetch creator Full Names in one query
    owner_ids = list(set(
        row.get("owner")
        for row in stock_rows
        if row.get("owner")
    ))

    owner_names = {}

    if owner_ids:

        users = frappe.get_all(
            "User",
            filters={"name": ["in", owner_ids]},
            fields=["name", "full_name"],
            limit_page_length=0,
        )

        for account in users:
            owner_names[account["name"]] = account.get("full_name")

    for row in stock_rows:

        row["stock_entry"] = row["name"]

        row["owner_full_name"] = (
            owner_names.get(row.get("owner"))
            or row.get("owner")
        )

    stock_count = (
        frappe.db.count(
            "Stock Entry",
            filters=stock_filters
        )
        if is_dashboard
        else len(stock_rows)
    )

# -----------------------------------------------------
# TASKS - UNCHANGED
# -----------------------------------------------------
# Tasks linked to Projects from COMPANY only.
# Tasks without a Project are excluded.

if can_view_production and action in ["dashboard", "tasks"]:

    company_projects = frappe.get_all(
        "Project",
        filters={"company": COMPANY},
        pluck="name",
        limit_page_length=0,
    )

    if company_projects:

        task_filters = {
            "owner": user,
            "project": ["in", company_projects],
            "status": ["not in", ["Completed", "Cancelled"]],
        }

        task_rows = frappe.get_all(
            "Task",
            filters=task_filters,
            fields=[
                "name",
                "subject",
                "project",
                "custom_project_name",
                "status",
                "priority",
                "custom_customer_name",
                "custom_customer_no",
                "exp_start_date",
                "exp_end_date",
                "progress",
                "is_milestone",
            ],
            order_by="exp_end_date asc, modified desc",
            limit_page_length=page_limit,
        )

        task_count = (
            frappe.db.count(
                "Task",
                filters=task_filters
            )
            if is_dashboard
            else len(task_rows)
        )

# -----------------------------------------------------
# WORK ORDERS - UNCHANGED
# -----------------------------------------------------

if can_view_production and action in [
    "dashboard", "work_orders", "manufacturing"
]:

    work_order_rows = frappe.get_all(
        "Work Order",
        filters=work_order_filters,
        fields=[
            "name",
            "status",
            "production_item",
            "item_name",
            "project",
            "qty",
            "produced_qty",
        ],
        order_by="modified desc",
        limit_page_length=page_limit,
    )

    work_order_count = (
        frappe.db.count(
            "Work Order",
            filters=work_order_filters
        )
        if is_dashboard
        else len(work_order_rows)
    )

# -----------------------------------------------------
# JOB CARDS - UNCHANGED
# -----------------------------------------------------

if can_view_production and action in [
    "dashboard", "job_cards", "manufacturing"
]:

    job_card_rows = frappe.get_all(
        "Job Card",
        filters=job_card_filters,
        fields=[
            "name",
            "status",
            "work_order",
            "production_item",
            "project"
        ],
        order_by="modified desc",
        limit_page_length=page_limit,
    )

    job_card_count = (
        frappe.db.count(
            "Job Card",
            filters=job_card_filters
        )
        if is_dashboard
        else len(job_card_rows)
    )

# -----------------------------------------------------
# PROJECTS - UNCHANGED
# -----------------------------------------------------

if can_view_production and action in ["dashboard", "projects"]:

    project_rows = frappe.get_all(
        "Project",
        filters=project_filters,
        fields=[
            "name",
            "project_name",
            "workflow_state",
            "status",
            "project_type",
            "custom_order_type",
            "percent_complete",
            "priority",
            "custom_team",
            "custom_customer_name",
            "custom_customer_no",
            "expected_start_date",
            "custom_exp_end_date",
            "expected_end_date",
            "custom_total_square_feet",
            "custom_payment_received",
            "custom_remark",
        ],
        order_by="modified desc",
        limit_page_length=page_limit,
    )

    project_count = (
        frappe.db.count(
            "Project",
            filters=project_filters
        )
        if is_dashboard
        else len(project_rows)
    )

# =====================================================
# SALES DATA - ORIGINAL LOGIC UNCHANGED
# =====================================================

# -----------------------------------------------------
# OPPORTUNITIES
# -----------------------------------------------------

opportunity_rows = []

if action in ["dashboard", "opportunities"] and can_view_sales:

    # Highest priority first: only the first non-empty owner controls visibility.
    visibility_owner_fields = [
        "custom_field_owner_2",
        "custom_field_owner_1",
        "opportunity_owner",
    ]
    opportunity_meta = frappe.get_meta("Opportunity")
    priority_columns = []
    for fieldname in visibility_owner_fields:
        owner_field = opportunity_meta.get_field(fieldname)
        if not owner_field or owner_field.fieldtype not in ["Link", "Data"]:
            frappe.throw("Invalid Opportunity visibility owner field configuration.")
        if owner_field.fieldtype == "Link" and owner_field.options != "User":
            frappe.throw("Opportunity visibility Link fields must link to User.")
        priority_columns.append("NULLIF(opp.`" + fieldname.replace("`", "``") + "`, '')")

    # Build the normal ERP read/field permission query without loading all records.
    permitted_opportunities_sql = frappe.get_list(
        "Opportunity",
        filters={
            "status": "Open",
        },
        fields=[
            "name",
            "creation",
            "owner",
            "title",
            "custom_citytown",
            "custom_customer_category",
            "custom_product_enquired",
            "custom_description",
            "contact_mobile",
            "opportunity_owner",
            "party_name",
            "custom_field_owner_1",
            "custom_field_owner_2",
        ],
        order_by="creation desc",
        limit_page_length=0,
        run=False,
    )
    # Apply the same first-populated-owner rule as mobile_opportunity_policy.
    opportunities = frappe.db.sql(
        "SELECT visible_opportunities.* FROM ("
        + permitted_opportunities_sql.replace("%", "%%")
        + ") visible_opportunities INNER JOIN `tabOpportunity` opp"
        + " ON opp.name = visible_opportunities.name WHERE COALESCE("
        + ", ".join(priority_columns) + ", '') = %(visibility_user)s"
        + " ORDER BY opp.creation DESC",
        {"visibility_user": user},
        as_dict=True,
    )

    for opp in opportunities:

        assigned_owner = opp.get("opportunity_owner")
        assigned_owner_name = ""

        if assigned_owner:
            assigned_owner_name = (
                frappe.db.get_value(
                    "User",
                    assigned_owner,
                    "full_name"
                )
                or assigned_owner
            )

        owner1_name = ""

        if opp.get("custom_field_owner_1"):

            owner1_info = frappe.db.get_value(
                "User",
                opp.get("custom_field_owner_1"),
                ["full_name", "enabled"],
                as_dict=True,
            )

            if owner1_info and owner1_info.get("enabled"):
                owner1_name = (
                    owner1_info.get("full_name")
                    or opp.get("custom_field_owner_1")
                )

        owner2_name = ""

        if opp.get("custom_field_owner_2"):

            owner2_info = frappe.db.get_value(
                "User",
                opp.get("custom_field_owner_2"),
                ["full_name", "enabled"],
                as_dict=True,
            )

            if owner2_info and owner2_info.get("enabled"):
                owner2_name = (
                    owner2_info.get("full_name")
                    or opp.get("custom_field_owner_2")
                )

        lead_owner_name = assigned_owner_name

        if opp.get("party_name"):

            lead_owner_email = frappe.db.get_value(
                "Lead",
                opp.get("party_name"),
                "lead_owner",
            )

            if lead_owner_email:
                lead_owner_name = (
                    frappe.db.get_value(
                        "User",
                        lead_owner_email,
                        "full_name"
                    )
                    or lead_owner_email
                )

        latest_note = frappe.get_all(
            "CRM Note",
            filters={
                "parenttype": "Opportunity",
                "parent": opp.get("name"),
            },
            fields=["note"],
            order_by="modified desc",
            limit_page_length=1,
        )

        opportunity_rows.append({
            "name": opp.get("name"),
            "opportunity_id": opp.get("name"),
            "created_by": opp.get("owner"),
            "creation": opp.get("creation"),
            "customer_name": opp.get("title"),
            "city": opp.get("custom_citytown"),
            "category": opp.get("custom_customer_category"),
            "product": opp.get("custom_product_enquired"),
            "lead_owner": lead_owner_name,
            "owner": assigned_owner_name,
            "owner_1": owner1_name,
            "owner_2": owner2_name,
            "comments": (
                latest_note[0].get("note")
                if latest_note else ""
            ),
            "description": opp.get("custom_description"),
            "mobile": opp.get("contact_mobile"),
        })

# -----------------------------------------------------
# OVERDUE FOLLOW-UPS - UNCHANGED
# -----------------------------------------------------

overdue_followup_rows = []

if action in ["dashboard", "overdue_followups"] and can_view_sales:

    today = frappe.utils.today()

    followup_query = """
        SELECT
            opp.name AS opportunity,
            opp.owner AS created_by,
            opp.customer_name AS customer,
            u.full_name AS opportunity_owner,
            u1.full_name AS field_owner,
            u2.full_name AS field_owner_1,
            opp.status AS status,
            opp.custom_next_followup_date AS next_followup_date

        FROM `tabOpportunity` opp

        LEFT JOIN `tabUser` u
            ON opp.opportunity_owner = u.name

        LEFT JOIN `tabUser` u1
            ON opp.custom_field_owner_1 = u1.name

        LEFT JOIN `tabUser` u2
            ON opp.custom_field_owner_2 = u2.name

        WHERE
            opp.owner = %(user)s

            AND opp.custom_next_followup_date < %(today)s

            AND opp.status IN (
                'Quotation',
                'Pipeline',
                'Prospect',
                'Follow-up',
                'Demo',
                'Hot Followup'
            )

        ORDER BY
            opp.custom_next_followup_date ASC,
            opp.expected_closing ASC
    """

    overdue_followup_rows = frappe.db.sql(
        followup_query,
        {
            "user": user,
            "today": today,
        },
        as_dict=True,
    )

    today_date = frappe.utils.getdate(today)

    for row in overdue_followup_rows:

        followup_date = row.get("next_followup_date")

        if followup_date:

            followup_date = frappe.utils.getdate(followup_date)

            row["overdue_days"] = (
                today_date - followup_date
            ).days

        else:
            row["overdue_days"] = 0

# -----------------------------------------------------
# OVERDUE CLOSING - UNCHANGED
# -----------------------------------------------------

overdue_closing_rows = []

if action in ["dashboard", "overdue_closing"] and can_view_sales:

    today = frappe.utils.today()

    closing_query = """
        SELECT
            opp.name AS opportunity,
            opp.owner AS created_by,
            opp.customer_name AS customer,
            u.full_name AS opportunity_owner,
            u1.full_name AS field_owner,
            opp.status AS status,
            opp.expected_closing AS expected_closing_date

        FROM `tabOpportunity` opp

        LEFT JOIN `tabUser` u
            ON opp.opportunity_owner = u.name

        LEFT JOIN `tabUser` u1
            ON opp.custom_field_owner_1 = u1.name

        WHERE
            opp.owner = %(user)s

            AND opp.expected_closing < %(today)s

            AND opp.status IN ('Pipeline', 'Prospect')

        ORDER BY
            opp.expected_closing ASC
    """

    overdue_closing_rows = frappe.db.sql(
        closing_query,
        {
            "user": user,
            "today": today,
        },
        as_dict=True,
    )

    today_date = frappe.utils.getdate(today)

    for row in overdue_closing_rows:

        closing_date = row.get("expected_closing_date")

        if closing_date:

            closing_date = frappe.utils.getdate(closing_date)

            row["overdue_days"] = (
                today_date - closing_date
            ).days

        else:
            row["overdue_days"] = 0

# -----------------------------------------------------
# DRAFT DELIVERY PLANS - UNCHANGED
# -----------------------------------------------------

draft_delivery_rows = []

if action in ["dashboard", "draft_delivery_plans"] and can_view_sales:

    delivery_query = """
        SELECT
            dn.name AS name,
            dn.name AS delivery_note,
            dn.owner AS created_by,
            dn.posting_date AS created_on,
            dn.customer_name AS customer_name,
            dn.company AS company,
            dn.workflow_state AS status,
            u.full_name AS owner

        FROM `tabDelivery Note` dn

        LEFT JOIN `tabUser` u
            ON u.name = dn.owner

        WHERE
            dn.workflow_state = 'Draft'
            AND dn.owner = %(user)s

        ORDER BY
            dn.posting_date DESC
    """

    draft_delivery_rows = frappe.db.sql(
        delivery_query,
        {"user": user},
        as_dict=True,
    )

# =====================================================
# RESPONSE - ORIGINAL FLUTTER KEYS PRESERVED
# =====================================================

if is_dashboard:

    message = {
        "user": user,
        "role": roles,
        "available_sections": available_sections,
    }

    if can_view_production:

        message["company"] = COMPANY

        message["pending_tasks"] = {
            "count": task_count,
            "items": task_rows,
        }

        message["stock"] = {
            "count": stock_count,
            "items": stock_rows,
        }

        message["manufacturing"] = {
            "count": work_order_count + job_card_count,
            "items": work_order_rows + job_card_rows,
        }

        message["projects"] = {
            "count": project_count,
            "items": project_rows,
        }

    if can_view_sales:

        message["opportunities"] = {
            "count": len(opportunity_rows),
            "items": opportunity_rows[:5],
        }

        message["overdue_followups"] = {
            "count": len(overdue_followup_rows),
            "items": overdue_followup_rows[:5],
        }

        message["overdue_closing"] = {
            "count": len(overdue_closing_rows),
            "items": overdue_closing_rows[:5],
        }

        message["draft_delivery_plans"] = {
            "count": len(draft_delivery_rows),
            "items": draft_delivery_rows[:5],
        }

    frappe.response["message"] = message

else:

    rows = []

    if action == "stock":
        rows = stock_rows

    elif action == "tasks":
        rows = task_rows

    elif action == "work_orders":
        rows = work_order_rows

    elif action == "job_cards":
        rows = job_card_rows

    elif action == "manufacturing":
        rows = work_order_rows + job_card_rows

    elif action == "projects":
        rows = project_rows

    elif action == "opportunities":
        rows = opportunity_rows

    elif action == "overdue_followups":
        rows = overdue_followup_rows

    elif action == "overdue_closing":
        rows = overdue_closing_rows

    elif action == "draft_delivery_plans":
        rows = draft_delivery_rows

    frappe.response["message"] = {
        "count": len(rows),
        "items": rows,
    }