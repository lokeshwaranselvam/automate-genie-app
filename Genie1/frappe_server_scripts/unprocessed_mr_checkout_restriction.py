# Replacement for Unprocessed MR-Checkout Restriction.
# Keep its existing Employee Checkin DocType Event setting.
# Only the pending-MR query is changed; all exemptions/messages are preserved.

if doc.log_type == "OUT":
    today = frappe.utils.today()
    checkin_exists_today = frappe.db.exists(
        "Employee Checkin",
        {"employee": doc.employee, "log_type": "IN",
         "time": ["between", [today + " 00:00:00", today + " 23:59:59"]]},
    )
    if checkin_exists_today:
        user_id = frappe.db.get_value("Employee", doc.employee, "user_id")
        if user_id:
            leave_exists = frappe.db.sql("""
                SELECT name FROM `tabLeave Application`
                WHERE employee = %s AND docstatus IN (0,1)
                    AND from_date <= CURDATE() AND to_date >= CURDATE()
                    AND half_day=1
            """, (doc.employee,), as_dict=True)
            permission_exists = frappe.db.sql("""
                SELECT name FROM `tabAttendance Request`
                WHERE employee = %s AND docstatus IN (0,1)
                    AND from_date = CURDATE()
                    AND TIME(custom_from_time) >= '12:00:00'
                    AND TIME(custom_to_time) >= '12:00:00'
            """, (doc.employee,), as_dict=True)
            if not leave_exists and not permission_exists:
                records = frappe.db.sql("""
                    SELECT mr.name, mr.schedule_date
                    FROM `tabMaterial Request` mr
                    INNER JOIN `tabToDo` ta
                        ON ta.reference_type = 'Material Request'
                        AND ta.reference_name = mr.name
                        AND ta.status = 'Open'
                    LEFT JOIN (
                        SELECT DISTINCT poi.material_request
                        FROM `tabPurchase Order Item` poi
                        INNER JOIN `tabPurchase Order` po ON po.name = poi.parent
                        WHERE po.docstatus = 1
                            AND poi.material_request IS NOT NULL
                    ) submitted_po ON submitted_po.material_request = mr.name
                    WHERE mr.docstatus = 1
                        AND mr.material_request_type = 'Purchase'
                        AND mr.status NOT IN ('Draft', 'Stopped', 'Cancelled')
                        AND mr.workflow_state != 'Cancelled'
                        AND mr.schedule_date <= CURDATE()
                        AND ta.allocated_to = %s
                        AND mr.name NOT IN ('BIO-MR-1176')
                        AND submitted_po.material_request IS NULL
                """, (user_id,), as_dict=True)
                if records:
                    count = len(records)
                    msg = f"""
                    <b>Checkout Not Allowed</b><br><br>

                    You have <b>{count}</b> pending Material Request(s) without a Submitted Purchase Order.<br><br>

                    Please complete your pending purchase activities before checkout.<br><br>

                    <a href="/app/query-report/Unprocessed%20MR%20Checking%20Report" target="_blank">
                        Click here to view Material Requests
                    </a>
                    """
                    frappe.throw(msg, title="Pending Material Requests")
