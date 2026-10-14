"""Add opt-in stage timings without changing check-in attendance rules."""
import ast


def patch_source(source):
    tree = ast.parse(source)
    functions = [node for node in tree.body
                 if isinstance(node, ast.FunctionDef) and node.name == "checkin"]
    if len(functions) != 1:
        raise ValueError("Expected exactly one checkin function.")
    function = functions[0]
    lines = source.splitlines(keepends=True)
    start = sum(map(len, lines[:function.body[0].lineno - 1]))
    end = sum(map(len, lines[:function.end_lineno]))
    body = source[start:end]
    if "# Genie checkin timings v1" in "".join(lines[function.lineno - 1:function.end_lineno]):
        return source
    if len(function.body) != 1 or not isinstance(function.body[0], ast.Try) or function.body[0].finalbody:
        raise ValueError("Unexpected checkin structure.")
    for old, new in (
        ('frappe.db.get_value("Employee",', 'checkin_timed("checkin_employee_lookup", frappe.db.get_value, "Employee",'),
        ('frappe.db.exists("Employee Checkin",', 'checkin_timed("checkin_existing_in", frappe.db.exists, "Employee Checkin",'),
        ('doc.save(ignore_permissions=True)', 'checkin_timed("checkin_checkin_save", doc.save, ignore_permissions=True)'),
        ('visit.save(ignore_permissions=True)', 'checkin_timed("checkin_visit_save", visit.save, ignore_permissions=True)'),
        ('frappe.db.commit()', 'checkin_timed("checkin_commit", frappe.db.commit)'),
    ):
        if body.count(old) != 1:
            raise ValueError("Checkin differs from the reviewed version.")
        body = body.replace(old, new)
    prefix = '''    # Genie checkin timings v1
    from time import perf_counter

    timing_enabled = include_timings in (True, 1, "1", "true") or frappe.form_dict.get("include_timings") in (True, 1, "1", "true")
    checkin_started = perf_counter()

    def checkin_timed(stage, operation, *args, **kwargs):
        if not timing_enabled:
            return operation(*args, **kwargs)
        started = perf_counter()
        try:
            return operation(*args, **kwargs)
        finally:
            timings = frappe.local.response.setdefault("attendance_timings_ms", {})
            timings[stage] = round((perf_counter() - started) * 1000, 3)

'''
    suffix = '''    finally:
        if timing_enabled:
            timings = frappe.local.response.setdefault("attendance_timings_ms", {})
            timings["checkin_total"] = round((perf_counter() - checkin_started) * 1000, 3)
'''
    newline = "\r\n" if "\r\n" in source else "\n"
    result = source[:start] + prefix.replace("\n", newline) + body.rstrip() + newline + suffix.replace("\n", newline) + source[end:]
    ast.parse(result)
    return result
