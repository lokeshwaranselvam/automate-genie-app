# RESTRICTED Frappe API Server Script. API Method: mobile_sales_summary.
# Allow Guest: OFF. No imports, functions, SQL or permission bypasses.
user = frappe.session.user
if not user or user == "Guest":
    frappe.throw("Please sign in to view your sales summary.", frappe.PermissionError)

if not frappe.db.get_value("User", user, "enabled"):
    frappe.throw("Your account is disabled.", frappe.PermissionError)


# Reject attempts to request someone else's summary. Counts always use session.
for parameter in ["user", "owner", "opportunity_owner", "custom_field_owner_1", "custom_field_owner_2", "for_user"]:
    requested = frappe.form_dict.get(parameter)
    if requested and requested != user:
        frappe.throw("You can only view your own sales summary.", frappe.PermissionError)

meta = frappe.get_meta("Opportunity")
for fieldname in ["opportunity_owner", "custom_field_owner_1", "custom_field_owner_2", "status"]:
    if not meta.has_field(fieldname):
        frappe.throw("Opportunity sales-summary fields are not configured.")
status_options = (meta.get_field("status").options or "").splitlines()
if "Prospect" not in status_options or "Pipeline" not in status_options:
    frappe.throw("Configure Prospect and Pipeline in Opportunity Status before using this summary.")

# get_list applies normal Frappe role, User Permission and permission-query
# conditions. Match any of the three owner fields on the same Opportunity row;
# one row matching multiple fields is counted only once.
rows = frappe.get_list(
    "Opportunity",
    filters={"status": ["in", ["Prospect", "Pipeline"]], "docstatus": ["!=", 2]},
    or_filters=[
        ["opportunity_owner", "=", user],
        ["custom_field_owner_1", "=", user],
        ["custom_field_owner_2", "=", user],
    ],
    fields=["status", "count(name) as total"],
    group_by="status", order_by="status asc", limit_page_length=2,
)
counts = {"Prospect": 0, "Pipeline": 0}
for row in rows:
    if row.get("status") in counts:
        counts[row.get("status")] = frappe.utils.cint(row.get("total"))

frappe.response["message"] = {
    "user": user,
    "scope": "own_opportunities",
    "prospect_count": counts["Prospect"],
    "pipeline_count": counts["Pipeline"],
    "total_count": counts["Prospect"] + counts["Pipeline"],
    "as_of": frappe.utils.now(),
}
