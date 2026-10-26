# Frappe Server Script settings:
#   Script Type: API
#   API Method: create_expense_claim_from_mobile
#   Allow Guest: Disabled
#   Enable Rate Limit: Enabled
#
# GET  /api/method/create_expense_claim_from_mobile
#      optional query parameter: employee=<Employee.name>
# POST /api/method/create_expense_claim_from_mobile (multipart form + files)
#      expenses=<JSON array of expense rows>, repeated file parts for bills
#      Legacy single-row fields and one file are still supported.

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

    # Only the selected Employee's expense_approver is eligible.
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
    if not approver_name or employee.get("expense_approver") != approver_name:
        return False

    if not frappe.db.exists("User", {"name": approver_name, "enabled": 1}):
        return False

    return True


def get_form_options(employee_name=None):
    employee_data = get_employee_options()
    employee_options = employee_data["options"]
    employee = get_employee(employee_name, employee_data["employees"])
    approver_data = get_expense_approver_options(employee)
    approver_options = approver_data["options"]
    default_approver = approver_data["default_approver"]
    if not approver_options:
        frappe.throw(
            "Set an enabled Expense Approver in the selected Employee's expense_approver field."
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
        "supports_multiple_expenses": True,
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
    options["csrf_token"] = frappe.session.get("csrf_token") or frappe.session.data.csrf_token
    options["business_policy"] = frappe.call("mobile_business_policy", feature="expense", action="get", event_id="")["policy"]
    frappe.response["message"] = options

elif frappe.request.method == "POST":
    business_policy = frappe.call("mobile_business_policy", feature="expense", action="get", event_id="")["policy"]
    employee_name = (frappe.form_dict.get("employee") or "").strip()
    expense_approver = (frappe.form_dict.get("expense_approver") or "").strip()
    if not employee_name:
        frappe.throw("Employee is required.")
    if not expense_approver:
        frappe.throw("Expense Approver is required.")

    # Prefer the complete row list. Only absent lists use the legacy fields;
    # an invalid or empty list must never silently become a single-row claim.
    raw_expenses = frappe.form_dict.get("expenses")
    if raw_expenses is None:
        raw_expenses = [
            {
                "expense_type": frappe.form_dict.get("expense_type"),
                "description": frappe.form_dict.get("description"),
                "expense_date": frappe.form_dict.get("expense_date"),
                "amount": frappe.form_dict.get("amount"),
            }
        ]
    elif isinstance(raw_expenses, str):
        try:
            raw_expenses = json.loads(raw_expenses)
        except Exception:
            frappe.throw("Expenses must be a valid JSON array of expense rows.")

    if not isinstance(raw_expenses, list) or not raw_expenses:
        frappe.throw("Add at least one expense row.")
    if business_policy["rules"]["max_expense_rows"] and len(raw_expenses) > business_policy["rules"]["max_expense_rows"]:
        frappe.throw("The permitted expense row count has been exceeded.")

    expenses = []
    row_number = 0
    for row in raw_expenses:
        row_number = row_number + 1
        prefix = "Expense " + str(row_number) + ": "
        if not isinstance(row, dict):
            frappe.throw(prefix + "Invalid expense row.")
        expense_type = str(row.get("expense_type") or "").strip()
        description = str(row.get("description") or "").strip()
        expense_date_value = str(row.get("expense_date") or "").strip()
        if not expense_type and business_policy["fields"]["expense_type"]["required"]:
            frappe.throw(prefix + "Expense Type is required.")
        if not description and business_policy["fields"]["description"]["required"]:
            frappe.throw(prefix + "Description is required.")
        if not expense_date_value:
            frappe.throw(prefix + "Date is required.")
        try:
            amount = float(str(row.get("amount") or "").replace(",", "").strip())
        except Exception:
            frappe.throw(prefix + "Amount must be a valid number greater than zero.")
        if amount != amount or amount == float("inf") or amount == -float("inf"):
            frappe.throw(prefix + "Amount must be a valid number greater than zero.")
        if expense_type and not frappe.db.exists("Expense Claim Type", expense_type):
            frappe.throw(prefix + "Choose an Expense Type from the configured options.")
        try:
            expense_date = frappe.utils.getdate(expense_date_value)
        except Exception:
            frappe.throw(prefix + "Enter a valid expense date.")
        if not expense_date:
            frappe.throw(prefix + "Enter a valid expense date.")
        frappe.call("mobile_business_policy", feature="expense", action="validate", original_values={}, error_prefix=prefix, values={
            "description": description, "expense_type": expense_type,
            "expense_date": expense_date_value, "amount": amount,
        })
        expenses.append(
            {
                "expense_date": expense_date,
                "expense_type": expense_type,
                "description": description,
                "amount": amount,
                "sanctioned_amount": amount,
            }
        )

    # Read every bill before inserting anything. All files are attached to the
    # same draft claim in this request, preserving the existing upload flow.
    uploaded_files = frappe.request.files.getlist("file")
    if len(uploaded_files) < business_policy["uploads"]["min_count"]:
        frappe.throw("Select a bill image to upload.")
    bills = []
    for uploaded_file in uploaded_files:
        if not uploaded_file or not uploaded_file.filename:
            frappe.throw("Select a bill image to upload.")
        file_content = uploaded_file.stream.read()
        if not file_content:
            frappe.throw("The selected bill image is empty.")
        frappe.call("mobile_business_policy", feature="expense", action="upload",
            file_name=uploaded_file.filename, file_size=len(file_content), file_count=len(uploaded_files))
        bills.append({"file_name": uploaded_file.filename, "content": file_content})

    # Look up only the selected employee and verify the submitted approver.
    employee = get_employee_for_claim(employee_name)
    if not is_allowed_expense_approver(employee, expense_approver):
        frappe.throw("Choose an Expense Approver assigned to the selected Employee.")

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

    # Match ERPNext by copying Amount into Sanctioned Amount for every row.
    for row in expenses:
        row["cost_center"] = company.cost_center
        claim.append("expenses", row)

    # The API verifies the signed-in user's employee scope and validates both
    # selected links before bypassing document-role permissions to insert.
    # Skip only HRMS's synchronous approver notification; normal validation
    # and the remaining Expense Claim hooks still run.
    claim.after_insert = skip_expense_claim_after_insert
    claim.insert(ignore_permissions=True)

    bill_files = []
    for uploaded_bill in bills:
        bill = frappe.new_doc("File")
        bill.file_name = uploaded_bill["file_name"]
        bill.attached_to_doctype = "Expense Claim"
        bill.attached_to_name = claim.name
        bill.is_private = 1
        bill.content = uploaded_bill["content"]
        # Bypass only the ordinary write-permission check for this API's claim.
        bill.insert(ignore_permissions=True)
        bill_files.append(
            {"name": bill.name, "file_name": bill.file_name, "file_url": bill.file_url}
        )

    expense_row = claim.expenses[0]
    first_bill = bill_files[0] if bill_files else {"name": "", "file_name": "", "file_url": ""}

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
        # Retain first-row and first-bill fields for existing mobile clients.
        "bill_file": first_bill["name"],
        "bill_file_name": first_bill["file_name"],
        "bill_file_url": first_bill["file_url"],
        "expenses": [
            {
                "name": row.name,
                "expense_date": row.expense_date,
                "expense_type": row.expense_type,
                "description": row.description,
                "amount": row.amount,
                "sanctioned_amount": row.sanctioned_amount,
            }
            for row in claim.expenses
        ],
        "bill_files": bill_files,
    }

else:
    frappe.throw("Use GET to load the form or POST to create an Expense Claim.")
