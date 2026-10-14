# Frappe Server Script: API / mobile_employee_performance
# Allow Guest: Disabled. Enable rate limiting. GET ?month=YYYY-MM.
# Read-only; identity always comes from the authenticated session.
current_user = frappe.session.user
if not current_user or current_user == "Guest":
    frappe.throw("Please sign in to view your performance.")
month_value = str(frappe.form_dict.get("month") or frappe.utils.nowdate()[:7]).strip()
if len(month_value) != 7 or month_value[4] != "-" or not month_value[:4].isdigit() or not month_value[5:].isdigit():
    frappe.throw("Month must use YYYY-MM format.")
try:
    selected_start = frappe.utils.getdate(month_value + "-01")
except Exception:
    frappe.throw("Choose a valid performance month.")
if selected_start.strftime("%Y-%m") != month_value:
    frappe.throw("Choose a valid performance month.")
selected_end = frappe.utils.add_months(selected_start, 1)
range_start = frappe.utils.add_months(selected_start, -5)
previous_month = frappe.utils.add_months(selected_start, -1).strftime("%Y-%m")
metric_names = ["leads", "conversions", "site_visits", "quotations", "orders", "completed_visits", "ongoing_visits", "visit_days", "checkin_days", "checkins", "checkouts", "present_days"]
months = {}
trend = []
weekly = []
for offset in range(5, -1, -1):
    key = frappe.utils.add_months(selected_start, -offset).strftime("%Y-%m")
    bucket = {"month": key}
    for metric in metric_names:
        bucket[metric] = 0
    months[key] = bucket
    trend.append(bucket)
for index in range(4):
    bucket = {"label": "W" + str(index + 1)}
    for metric in metric_names:
        bucket[metric] = 0
    weekly.append(bucket)

# Leads Created uses lead_owner=the signed-in user, matching My Leads.
# Converted leads are a creation-date cohort CURRENTLY marked Converted.
# Submitted quotations/orders use transaction_date; cancelled rows are excluded.
# Standard owner/creation/docstatus fields need no custom Meta field lookup.
for doctype in ["Lead", "Quotation", "Sales Order"]:
    date_field = "creation" if doctype == "Lead" else "transaction_date"
    fields = [date_field, "status"] if doctype == "Lead" else [date_field]
    owner_field = "lead_owner" if doctype == "Lead" else "owner"
    filters = [[owner_field, "=", current_user], [date_field, ">=", str(range_start)], [date_field, "<", str(selected_end)], ["docstatus", "!=", 2] if doctype == "Lead" else ["docstatus", "=", 1]]
    rows = frappe.get_all(doctype, filters=filters, fields=fields, limit_page_length=0)
    metric = "leads" if doctype == "Lead" else ("quotations" if doctype == "Quotation" else "orders")
    for row in rows:
        day = frappe.utils.getdate(row.get(date_field))
        key = day.strftime("%Y-%m")
        if key in months:
            months[key][metric] = months[key][metric] + 1
            if metric == "leads" and row.get("status") == "Converted":
                months[key]["conversions"] = months[key]["conversions"] + 1
            if key == month_value:
                week = min((day.day - 1) // 7, 3)
                weekly[week][metric] = weekly[week][metric] + 1
                if metric == "leads" and row.get("status") == "Converted":
                    weekly[week]["conversions"] = weekly[week]["conversions"] + 1

employees = frappe.get_all("Employee", filters={"user_id": current_user, "status": "Active"}, fields=["name"], limit_page_length=2)
employee = employees[0].get("name") if len(employees) == 1 else None
visits_available = False
attendance_available = False
present_available = False
visit_days = {}
checkin_days = {}
present_days = {}
if employee and frappe.db.exists("DocType", "Visit"):
    meta = frappe.get_meta("Visit")
    visits_available = bool(meta.get_field("employee") and meta.get_field("event_id") and meta.get_field("custom_check_in_time") and meta.get_field("custom_check_out_time"))
    if visits_available:
        rows = frappe.get_all("Visit", filters=[["employee", "=", employee], ["event_id", "not in", ["", "Employee Checked In", "Employee Checked Out"]], ["custom_check_in_time", ">=", str(range_start)], ["custom_check_in_time", "<", str(selected_end)], ["docstatus", "!=", 2]], fields=["custom_check_in_time", "custom_check_out_time"], limit_page_length=0)
        for row in rows:
            day = frappe.utils.getdate(row.get("custom_check_in_time"))
            key = day.strftime("%Y-%m")
            if key in months:
                months[key]["site_visits"] = months[key]["site_visits"] + 1
                metric = "completed_visits" if row.get("custom_check_out_time") else "ongoing_visits"
                months[key][metric] = months[key][metric] + 1
                visit_days[str(day)] = True
                if key == month_value:
                    week = min((day.day - 1) // 7, 3)
                    weekly[week]["site_visits"] = weekly[week]["site_visits"] + 1
                    weekly[week][metric] = weekly[week][metric] + 1
if employee and frappe.db.exists("DocType", "Employee Checkin"):
    meta = frappe.get_meta("Employee Checkin")
    attendance_available = bool(meta.get_field("employee") and meta.get_field("time") and meta.get_field("log_type"))
    if attendance_available:
        rows = frappe.get_all("Employee Checkin", filters=[["employee", "=", employee], ["time", ">=", str(range_start)], ["time", "<", str(selected_end)], ["log_type", "in", ["IN", "OUT"]]], fields=["time", "log_type"], limit_page_length=0)
        for row in rows:
            day = frappe.utils.getdate(row.get("time"))
            key = day.strftime("%Y-%m")
            if key in months:
                metric = "checkins" if row.get("log_type") == "IN" else "checkouts"
                months[key][metric] = months[key][metric] + 1
                if row.get("log_type") == "IN":
                    checkin_days[str(day)] = True
                if key == month_value:
                    week = min((day.day - 1) // 7, 3)
                    weekly[week][metric] = weekly[week][metric] + 1
if employee and frappe.db.exists("DocType", "Attendance"):
    present_available = True
    rows = frappe.get_all("Attendance", filters=[["employee", "=", employee], ["attendance_date", ">=", str(range_start)], ["attendance_date", "<", str(selected_end)], ["docstatus", "=", 1], ["status", "in", ["Present", "Work From Home"]]], fields=["attendance_date"], limit_page_length=0)
    for row in rows:
        present_days[str(frappe.utils.getdate(row.get("attendance_date")))] = True
for day_set, metric in [[visit_days, "visit_days"], [checkin_days, "checkin_days"], [present_days, "present_days"]]:
    for day_text in day_set:
        key = day_text[:7]
        if key in months:
            months[key][metric] = months[key][metric] + 1
            if key == month_value:
                week = min((frappe.utils.getdate(day_text).day - 1) // 7, 3)
                weekly[week][metric] = weekly[week][metric] + 1
# Missing employee/schema is unavailable, never a fabricated zero.
for bucket in trend + weekly:
    if not visits_available:
        for metric in ["site_visits", "completed_visits", "ongoing_visits", "visit_days"]:
            bucket[metric] = None
    if not attendance_available:
        for metric in ["checkin_days", "checkins", "checkouts"]:
            bucket[metric] = None
    if not present_available:
        bucket["present_days"] = None
selected = months[month_value]
frappe.response["message"] = {
    "current_user": current_user, "employee": employee, "month": month_value,
    "previous_month": previous_month, "targets_configured": False,
    "sales": {"leads": selected["leads"], "site_visits": selected["site_visits"], "quotations": selected["quotations"], "orders": selected["orders"]},
    "activity": {"site_visits": selected["site_visits"], "completed_visits": selected["completed_visits"], "ongoing_visits": selected["ongoing_visits"], "visit_days": selected["visit_days"]},
    "attendance": {"available": attendance_available, "checkin_days": selected["checkin_days"], "checkins": selected["checkins"], "checkouts": selected["checkouts"], "present_days": selected["present_days"]},
    "previous": months[previous_month], "weekly": weekly, "trend": trend,
}
