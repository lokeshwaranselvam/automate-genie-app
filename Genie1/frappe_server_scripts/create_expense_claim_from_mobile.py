# Frappe Server Script settings:
#   Script Type: API
#   API Method: create_expense_claim_from_mobile
#   Allow Guest: Disabled
#   Enable Rate Limit: Enabled
#
# GET  /api/method/create_expense_claim_from_mobile
#      optional query parameter: employee=<Employee.name>
# POST /api/method/create_expense_claim_from_mobile (multipart form + file)

current_user = frappe.session.user
if not current_user or current_user == "Guest":
    frappe.throw("Please sign in before creating an Expense Claim.")


def user_can_claim_for_others():
    role_rows = frappe.get_all(
        "Has Role",
        filters={
            "parent": current_user,
            "parenttype": "User",
            "role": ["in", ["HR User", "HR Manager", "Expense Approver"]],
        },
        fields=["role"],
        limit_page_length=10,
    )
    return bool(role_rows)


def get_employee_options():
    employee_meta = frappe.get_meta("Employee")
    employee_fields = ["name", "employee_name", "company", "department", "user_id", "status"]
    if employee_meta.get_field("expense_approver"):
        employee_fields.append("expense_approver")

    filters = {"status": "Active"}
    can_claim_for_others = user_can_claim_for_others()
    if not can_claim_for_others:
        filters["user_id"] = current_user

    employees = frappe.get_all(
        "Employee",
        filters=filters,
        fields=employee_fields,
        order_by="employee_name asc",
        limit_page_length=1000,
    )
    if not employees:
        frappe.throw("No active Employee record is available for your account.")

    options = []
    for employee in employees:
        employee_name = employee.employee_name or employee.name
        options.append(
            {
                "value": employee.name,
                "label": employee_name + " (" + employee.name + ")",
            }
        )
    return {"employees": employees, "options": options}


def get_employee(employee_name=None, employees=None):
    if employees is None:
        employee_data = get_employee_options()
        employees = employee_data["employees"]
    if employee_name:
        for employee in employees:
            if employee.name == employee_name:
                return employee
        frappe.throw("Choose an active Employee you are allowed to create claims for.")

    for employee in employees:
        if employee.user_id == current_user:
            return employee
    return employees[0]


def get_employee_for_claim(employee_name):
    # A POST already names one employee. Fetch that row directly instead of
    # loading the full employee dropdown (up to 1,000 rows) to check access.
    employee_fields = [
        "name",
        "employee_name",
        "company",
        "department",
        "user_id",
        "status",
    ]
    if frappe.get_meta("Employee").get_field("expense_approver"):
        employee_fields.append("expense_approver")

    employee = frappe.db.get_value(
        "Employee", employee_name, employee_fields, as_dict=True
    )
    if not employee or employee.status != "Active":
        frappe.throw("Choose an active Employee you are allowed to create claims for.")

    if employee.user_id != current_user and not user_can_claim_for_others():
        frappe.throw("Choose an active Employee you are allowed to create claims for.")

    return employee


def get_expense_approver_options(employee):
    approver_names = []
    primary_approver = employee.get("expense_approver")
    if primary_approver:
        approver_names.append(primary_approver)

    if employee.get("department"):
        department_rows = frappe.get_all(
            "Department Approver",
            filters={
                "parent": employee.department,
                "parentfield": "expense_approvers",
            },
            fields=["approver"],
            order_by="idx asc",
            limit_page_length=500,
        )
        for row in department_rows:
            if row.approver and row.approver not in approver_names:
                approver_names.append(row.approver)

    # If HR has not assigned an approver to this employee or department, offer
    # enabled users with the Expense Approver role as searchable suggestions.
    if not approver_names:
        role_rows = frappe.get_all(
            "Has Role",
            filters={"role": "Expense Approver", "parenttype": "User"},
            fields=["parent"],
            limit_page_length=1000,
        )
        for row in role_rows:
            if row.parent and row.parent not in approver_names:
                approver_names.append(row.parent)

    if not approver_names:
        return {"options": [], "default_approver": ""}

    users = frappe.get_all(
        "User",
        filters={"name": ["in", approver_names], "enabled": 1},
        fields=["name", "full_name"],
        order_by="full_name asc",
        limit_page_length=1000,
    )
    user_by_name = {}
    for user in users:
        user_by_name[user.name] = user

    options = []
    for approver_name in approver_names:
        user = user_by_name.get(approver_name)
        if not user:
            continue
        full_name = user.full_name or user.name
        options.append(
            {
                "value": user.name,
                "label": full_name + " (" + user.name + ")",
            }
        )

    default_approver = ""
    if primary_approver:
        for option in options:
            if option["value"] == primary_approver:
                default_approver = primary_approver
                break
    if not default_approver and options:
        default_approver = options[0]["value"]
    return {"options": options, "default_approver": default_approver}


def is_allowed_expense_approver(employee, approver_name):
    if not frappe.db.exists("User", {"name": approver_name, "enabled": 1}):
        return False

    has_configured_approver = bool(employee.get("expense_approver"))
    if employee.get("expense_approver") == approver_name:
        return True

    if employee.get("department"):
        department_filters = {
            "parent": employee.department,
            "parentfield": "expense_approvers",
        }
        if frappe.db.exists(
            "Department Approver",
            dict(department_filters, approver=approver_name),
        ):
            return True

        if frappe.db.exists("Department Approver", department_filters):
            has_configured_approver = True

    if has_configured_approver:
        return False

    return bool(
        frappe.db.exists(
            "Has Role",
            {
                "parent": approver_name,
                "parenttype": "User",
                "role": "Expense Approver",
            },
        )
    )


def get_form_options(employee_name=None):
    employee_data = get_employee_options()
    employee_options = employee_data["options"]
    employee = get_employee(employee_name, employee_data["employees"])
    approver_data = get_expense_approver_options(employee)
    approver_options = approver_data["options"]
    default_approver = approver_data["default_approver"]
    if not approver_options:
        frappe.throw(
            "No enabled Expense Approver is configured for this employee, department, or Expense Approver role."
        )

    company = frappe.db.get_value(
        "Company",
        employee.company,
        ["default_currency", "cost_center", "default_expense_claim_payable_account"],
        as_dict=True,
    )
    if not company:
        frappe.throw("The Company linked to this Employee record was not found.")
    if not company.default_currency:
        frappe.throw("Set a default currency on the Company linked to this Employee record.")
    if not company.default_expense_claim_payable_account:
        frappe.throw(
            "Set the Default Expense Claim Payable Account on the Company linked to this Employee record."
        )

    expense_types = frappe.get_all(
        "Expense Claim Type",
        fields=["name", "expense_type"],
        order_by="expense_type asc",
        limit_page_length=500,
    )
    if not expense_types:
        frappe.throw("No Expense Claim Types are configured in ERPNext.")

    return {
        "current_user": current_user,
        "employee": employee.name,
        "employee_name": employee.employee_name or employee.name,
        "department": employee.department or "",
        "company": employee.company,
        "employee_options": employee_options,
        "expense_approver": default_approver,
        "expense_approver_options": approver_options,
        "currency": company.default_currency,
        "expense_types": [
            {"value": row.name, "label": row.expense_type or row.name}
            for row in expense_types
        ],
    }


def skip_expense_claim_after_insert():
    # HRMS normally creates a PWA Notification here and sends a synchronous
    # push request. That external request can stall the mobile API until its
    # client times out. The claim remains available to the approver in ERPNext.
    return


if frappe.request.method == "GET":
    selected_employee = (frappe.form_dict.get("employee") or "").strip() or None
    options = get_form_options(selected_employee)
    options["csrf_token"] = frappe.session.data.csrf_token
    frappe.response["message"] = options

elif frappe.request.method == "POST":
    employee_name = (frappe.form_dict.get("employee") or "").strip()
    expense_approver = (frappe.form_dict.get("expense_approver") or "").strip()
    expense_type = (frappe.form_dict.get("expense_type") or "").strip()
    description = (frappe.form_dict.get("description") or "").strip()
    expense_date_value = (frappe.form_dict.get("expense_date") or "").strip()
    amount = frappe.utils.flt(frappe.form_dict.get("amount"))

    if not employee_name:
        frappe.throw("Employee is required.")
    if not expense_approver:
        frappe.throw("Expense Approver is required.")
    if not expense_type:
        frappe.throw("Expense Type is required.")
    if not description:
        frappe.throw("Description is required.")
    if not expense_date_value:
        frappe.throw("Date is required.")
    if amount <= 0:
        frappe.throw("Amount must be greater than zero.")
    if not frappe.db.exists("Expense Claim Type", expense_type):
        frappe.throw("Choose an Expense Type from the configured options.")

    # Send the bill with the claim request. If the response is slow, the server
    # still saves the bill with the draft instead of relying on a later upload
    # request that needs the claim name from the response.
    uploaded_file = frappe.request.files.get("file")
    if not uploaded_file or not uploaded_file.filename:
        frappe.throw("Select a bill image to upload.")
    file_content = uploaded_file.stream.read()
    if not file_content:
        frappe.throw("The selected bill image is empty.")

    # Look up only the selected employee and verify the submitted approver.
    employee = get_employee_for_claim(employee_name)
    if not is_allowed_expense_approver(employee, expense_approver):
        frappe.throw("Choose an Expense Approver assigned to the selected Employee.")

    expense_date = frappe.utils.getdate(expense_date_value)
    company = frappe.db.get_value(
        "Company",
        employee.company,
        [
            "default_currency",
            "cost_center",
            "default_expense_claim_payable_account",
        ],
        as_dict=True,
    )
    if not company:
        frappe.throw("The Company linked to this Employee record was not found.")
    if not company.default_currency:
        frappe.throw(
            "Set a default currency on the Company linked to this Employee record."
        )
    if not company.default_expense_claim_payable_account:
        frappe.throw(
            "Set the Default Expense Claim Payable Account on the Company linked to this Employee record."
        )

    claim = frappe.new_doc("Expense Claim")
    claim.naming_series = "HR-EXP-.YYYY.-"
    claim.employee = employee.name
    claim.employee_name = employee.employee_name or employee.name
    claim.department = employee.department
    claim.company = employee.company
    claim.expense_approver = expense_approver
    claim.approval_status = "Draft"
    claim.posting_date = frappe.utils.today()
    claim.currency = company.default_currency
    claim.exchange_rate = 1
    claim.payable_account = company.default_expense_claim_payable_account
    if company.cost_center:
        claim.cost_center = company.cost_center

    # Match the ERPNext Expense Claim form, which copies Amount into
    # Sanctioned Amount when an expense row is entered.
    claim.append(
        "expenses",
        {
            "expense_date": expense_date,
            "expense_type": expense_type,
            "description": description,
            "amount": amount,
            "sanctioned_amount": amount,
            "cost_center": company.cost_center,
        },
    )

    # The API verifies the signed-in user's employee scope and validates both
    # selected links before bypassing document-role permissions to insert.
    # Skip only HRMS's synchronous approver notification; normal validation
    # and the remaining Expense Claim hooks still run.
    claim.after_insert = skip_expense_claim_after_insert
    claim.insert(ignore_permissions=True)

    bill = frappe.new_doc("File")
    bill.file_name = uploaded_file.filename
    bill.attached_to_doctype = "Expense Claim"
    bill.attached_to_name = claim.name
    bill.is_private = 1
    bill.content = file_content
    # The claim was created by this validated API call. Bypass only the
    # ordinary Expense Claim write-permission check for the linked File.
    bill.insert(ignore_permissions=True)

    expense_row = claim.expenses[0]

    frappe.response["message"] = {
        "status": "success",
        "name": claim.name,
        "employee": claim.employee,
        "expense_approver": claim.expense_approver,
        "expense_row": expense_row.name,
        "expense_type": expense_row.expense_type,
        "description": expense_row.description,
        "amount": expense_row.amount,
        "sanctioned_amount": expense_row.sanctioned_amount,
        "expense_date": expense_row.expense_date,
        "currency": claim.currency,
        "total_claimed_amount": claim.total_claimed_amount,
        "total_sanctioned_amount": claim.total_sanctioned_amount,
        "approval_status": claim.approval_status,
        "bill_file": bill.name,
        "bill_file_name": bill.file_name,
        "bill_file_url": bill.file_url,
    }

else:
    frappe.throw("Use GET to load the form or POST to create an Expense Claim.")
