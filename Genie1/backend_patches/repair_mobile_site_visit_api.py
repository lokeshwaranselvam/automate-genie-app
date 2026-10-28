"""Administrator Bench-console deployment repair; NOT a restricted Server Script.

Upload this file and frappe_server_scripts/mobile_site_visit_api.py to the bench
server. In `bench --site YOUR_SITE console`, run:

    exec(open('/tmp/repair_mobile_site_visit_api.py').read())
    repair_mobile_site_visit('/tmp/mobile_site_visit_api.py', apply=True)

Only the script body of the single enabled mobile_site_visit API is changed.
"""
import ast
import hashlib
from pathlib import Path
from uuid import uuid4

import frappe


def repair_mobile_site_visit(source_path, apply=False):
    frappe.only_for("Script Manager")
    source = Path(source_path).read_text(encoding="utf-8-sig")
    ast.parse(source)
    required = (
        '#   API Method: mobile_site_visit',
        'if action == "can_create":',
        '"can_create": can_create_visit',
        '"current_user": current_user',
        'has_sales_manager_role',
    )
    if not all(marker in source for marker in required):
        raise ValueError("Use the canonical mobile_site_visit_api.py source file.")
    if "event_id is required." in source:
        raise ValueError("The supplied source contains the wrong Event ID guard.")

    rows = frappe.get_all(
        "Server Script",
        filters={"script_type": "API", "api_method": "mobile_site_visit", "disabled": 0},
        fields=["name"],
        limit_page_length=2,
    )
    if len(rows) != 1:
        raise ValueError(
            "Expected exactly one enabled mobile_site_visit API script. "
            "Review missing or duplicate mappings before repair."
        )
    doc = frappe.get_doc("Server Script", rows[0].name)
    doc.check_permission("write")
    if doc.api_method != "mobile_site_visit" or doc.script_type != "API" or doc.disabled:
        raise ValueError("The target mapping changed. Reload and inspect it before repair.")
    old_source = doc.script or ""
    if old_source == source:
        doc.clear_cache()
        return {"status": "already_correct", "script": doc.name}
    # Do not overwrite a customized permission API or an unrelated failure.
    if 'if action == "can_create":' in old_source or "event_id is required." not in old_source:
        raise ValueError(
            "The deployed body is not the confirmed wrong report script. "
            "Inspect its content/API routing without overwriting it."
        )
    result = {
        "status": "ready", "site": frappe.local.site, "script": doc.name,
        "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
    }
    if not apply:
        return result

    backup_dir = Path(frappe.get_site_path("private", "backups"))
    backup_dir.mkdir(parents=True, exist_ok=True)
    backup = backup_dir / ("mobile-site-visit-before-repair-" + uuid4().hex + ".json")
    backup.write_text(frappe.as_json(doc.as_dict()), encoding="utf-8")
    try:
        doc.script = source
        doc.save()  # Preserve method, guest/rate-limit settings, and normal permissions.
        frappe.db.commit()
    except Exception:
        frappe.db.rollback()
        doc.clear_cache()
        raise
    doc.clear_cache()
    result.update(status="repaired", backup=str(backup))
    return result
