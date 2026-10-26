# Frappe Server Script settings:
#   Script Type: API
#   API Method: create_leave_application_from_mobile
#   Allow Guest: Disabled
#   Enable Rate Limit: Enabled
#
# GET loads the signed-in employee and ERP-eligible Leave Types; POST creates the application.
user = frappe.session.user
if not user or user == "Guest": frappe.throw("Please sign in to apply for leave.")
business_policy = frappe.call("mobile_business_policy", feature="leave", action="get", event_id="")["policy"]

employee_fields = ["name", "employee_name", "company", "department"]
if frappe.get_meta("Employee").get_field("leave_approver"): employee_fields.append("leave_approver")

def skip_leave_application_push(): return

if frappe.request.method == "GET":
    employees = frappe.get_all("Employee", filters={"user_id": user, "status": "Active"}, fields=employee_fields, limit_page_length=1)
    if not employees: frappe.throw("No active Employee record is linked to your account.")
    # Use the same eligibility source as ERPNext's Leave Application form.
    # LWP types are eligible without a Leave Allocation.
    leave_details = frappe.call(
        "hrms.hr.doctype.leave_application.leave_application.get_leave_details",
        employee=employees[0].name,
        date=frappe.utils.today(),
    )
    leave_types = list((leave_details.get("leave_allocation") or {}).keys())
    for lwp in leave_details.get("lwps") or []:
        if lwp not in leave_types:
            leave_types.append(lwp)
    leave_types = sorted(leave_types)
    if not leave_types: frappe.throw("No eligible Leave Types are available for your Employee record in ERPNext.")
    frappe.response["message"] = {"employee": employees[0].name, "employee_name": employees[0].employee_name or employees[0].name, "leave_types": [{"value": name, "label": name} for name in leave_types], "csrf_token": frappe.session.get("csrf_token") or frappe.session.data.csrf_token, "business_policy": business_policy}

elif frappe.request.method == "POST":
    form = frappe.form_dict
    leave_type = (form.get("leave_type") or "").strip()
    from_date = (form.get("from_date") or "").strip()
    to_date = (form.get("to_date") or "").strip()
    description = (form.get("description") or "").strip()
    half_day = form.get("half_day") in ["1", 1, True, "true", "True", "on"]
    if not leave_type: frappe.throw("Leave Type is required.")
    if not from_date or not to_date: frappe.throw("From Date and To Date are required.")
    if not description and business_policy["fields"]["description"]["required"]: frappe.throw("Reason is required.")
    if not frappe.db.exists("Leave Type", leave_type): frappe.throw("Choose a configured Leave Type.")
    from_date = frappe.utils.getdate(from_date)
    to_date = frappe.utils.getdate(to_date)
    if to_date < from_date: frappe.throw("To Date must be on or after From Date.")
    frappe.call("mobile_business_policy", feature="leave", action="validate", original_values={}, values={
        "description": description, "leave_type": leave_type, "from_date": str(from_date),
        "to_date": str(to_date), "half_day": half_day,
    })
    employees = frappe.get_all("Employee", filters={"user_id": user, "status": "Active"}, fields=employee_fields, limit_page_length=1)
    if not employees: frappe.throw("No active Employee record is linked to your account.")
    employee = employees[0]
    leave_details = frappe.call(
        "hrms.hr.doctype.leave_application.leave_application.get_leave_details",
        employee=employee.name,
        date=from_date,
    )
    if leave_type not in (leave_details.get("leave_allocation") or {}) and leave_type not in (leave_details.get("lwps") or []):
        frappe.throw("Choose a Leave Type available for your Employee record in ERPNext for the From Date.")
    approver = employee.get("leave_approver")
    if not approver and employee.department:
        rows = frappe.get_all("Department Approver", filters={"parent": employee.department, "parentfield": "leave_approvers"}, fields=["approver"], order_by="idx asc", limit_page_length=1)
        if rows: approver = rows[0].approver
    if not approver: frappe.throw("Set a Leave Approver on the Employee or Department before applying.")

    leave = frappe.new_doc("Leave Application")
    leave.naming_series = "HR-LAP-.YYYY.-"
    leave.employee = employee.name
    leave.leave_type = leave_type
    leave.from_date = from_date
    leave.to_date = to_date
    leave.description = description
    leave.company = employee.company
    leave.department = employee.department
    leave.leave_approver = approver
    leave.half_day = 1 if half_day else 0
    leave.half_day_date = from_date if half_day else None
    # Prevent a broken Push Notification Settings key from delaying this API call.
    leave.after_insert = skip_leave_application_push
    leave.flags.ignore_mandatory = True
    leave.insert(ignore_permissions=True, ignore_mandatory=True)
    frappe.response["message"] = {"status": "success", "name": leave.name, "employee": leave.employee, "leave_type": leave.leave_type, "from_date": leave.from_date, "to_date": leave.to_date, "total_leave_days": leave.total_leave_days, "description": leave.description, "half_day": leave.half_day, "status_text": leave.status}
else:
    frappe.throw("Use GET to load the form or POST to apply for leave.")
