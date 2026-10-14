# Replacement for Bioman– Confirmed Quotation Pending SO Checkout.
# Keep its existing Employee Checkin DocType Event setting.
# Only the project query is changed; restrictions and messages are preserved.

if doc.log_type != "OUT":
    pass
else:
    today = frappe.utils.today()
    checkin_exists_today = frappe.db.exists(
        "Employee Checkin",
        {"employee": doc.employee, "log_type": "IN",
         "time": ["between", [today + " 00:00:00", today + " 23:59:59"]]},
    )
    if not checkin_exists_today:
        pass
    else:
        emp_user = frappe.db.get_value("Employee", doc.employee, "user_id")
        if not emp_user:
            pass
        else:
            project_rows = frappe.db.sql("""
                SELECT p.name AS project_id, p.project_name, q.name AS quotation
                FROM `tabProject` p
                INNER JOIN `tabQuotation` q
                    ON q.custom_project = p.name AND q.workflow_state = 'Confirmed'
                LEFT JOIN (
                    SELECT DISTINCT project FROM `tabSales Order`
                    WHERE docstatus = 1 AND project IS NOT NULL
                ) submitted_so ON submitted_so.project = p.name
                WHERE p.project_type = 'Bioman Production'
                    AND p.status NOT IN ('Completed', 'Cancelled')
                    AND p.owner = %s
                    AND submitted_so.project IS NULL
                GROUP BY p.name, p.project_name, q.name
                ORDER BY p.modified DESC
            """, (emp_user,), as_dict=True)
            if project_rows:
                project_list = ", ".join([
                    f"<a href='/app/project/{r.project_id}' target='_blank'>{r.project_id}</a>"
                    for r in project_rows
                ])
                quotation_list = ", ".join([
                    f"<a href='/app/quotation/{r.quotation}' target='_blank'>{r.quotation}</a>"
                    for r in project_rows
                ])
                msg = (
                    "Check-out Not Allowed<br><br>"
                    "You have Bioman Production Project(s) "
                    "with a <b>Confirmed Quotation</b> but "
                    "no Sales Order has been created.<br><br>"
                    "Project(s): <b>" + project_list + "</b><br>"
                    "Quotation(s): <b>" + quotation_list + "</b><br><br>"
                    "Please create the Sales Order before checking out."
                )
                frappe.throw(msg, frappe.ValidationError)
