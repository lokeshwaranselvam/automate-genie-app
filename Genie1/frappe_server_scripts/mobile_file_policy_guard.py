# Restricted Document Event Server Script: File / Before Save.
# Scope only mobile feature document types; other ERP uploads retain their rules.
feature = {"Event": "visit", "Expense Claim": "expense"}.get(doc.attached_to_doctype, "general_upload")
if frappe.session.user != "Guest" and not doc.is_folder and doc.file_name:
    policy = frappe.call("mobile_business_policy", feature=feature, action="get", event_id="")["policy"]
    count = 1
    if policy["uploads"]["max_count"] and doc.attached_to_doctype and doc.attached_to_name:
        count = frappe.db.count("File", {
            "attached_to_doctype": doc.attached_to_doctype,
            "attached_to_name": doc.attached_to_name, "is_folder": 0,
            "name": ["!=", doc.name],
        }) + 1
    size = doc.get("file_size") or 0
    if policy["uploads"]["max_bytes"] and not (doc.file_url or "").startswith(("https://", "http://")):
        # Use actual server content, not caller-supplied file_size metadata.
        size = len(doc.get_content())
    frappe.call("mobile_business_policy", feature=feature, action="upload", event_id="",
        file_name=doc.file_name, file_size=size, file_count=count)
