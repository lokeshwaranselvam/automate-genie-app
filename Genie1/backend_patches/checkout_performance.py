"""Patch only checkout() in the supplied ts_homegenie API module.

Run on the server: python3 checkout_performance.py /path/to/utils/api.py --apply
Without --apply, validate the patch without writing. Uses only Python stdlib.
"""
import argparse
import ast
from datetime import datetime, timezone
from pathlib import Path
import shutil
import textwrap


MARKER = "# Genie checkout performance v1"
HELPERS = '''
    # Genie checkout performance v1
    from time import perf_counter

    timing_enabled = frappe.form_dict.get("include_timings") in [True, 1, "1", "true"]
    checkout_started = perf_counter()
    route_responses = {}  # Request-local only; never shared between employees.

    def checkout_timed(stage, operation, *args, **kwargs):
        if not timing_enabled:
            return operation(*args, **kwargs)
        started = perf_counter()
        try:
            return operation(*args, **kwargs)
        finally:
            timings = frappe.local.response.setdefault("attendance_timings_ms", {})
            timings[stage] = round(timings.get(stage, 0) + (perf_counter() - started) * 1000, 3)

    def checkout_maps_response(url, headers, payload):
        # Both original branches can request exactly the same driving route.
        # Reuse that response, retaining their existing Google status checks.
        if url not in route_responses:
            try:
                route_responses[url] = checkout_timed(
                    "checkout_google_distance", requests.request,
                    "GET", url, headers=headers, data=payload, timeout=(3.05, 10),
                )
            except requests.exceptions.Timeout:
                # The outer handler rolls back both attendance and receipt use.
                raise RuntimeError("Google distance lookup timed out. Please retry checkout.") from None
        return route_responses[url]

'''
FINALLY = '''
    finally:
        if timing_enabled:
            timings = frappe.local.response.setdefault("attendance_timings_ms", {})
            timings["checkout_total"] = round((perf_counter() - checkout_started) * 1000, 3)
'''


def patch_source(source):
    tree = ast.parse(source)
    functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "checkout"]
    if len(functions) != 1:
        raise ValueError("Expected exactly one top-level checkout function; no changes made.")
    function = functions[0]
    lines = source.splitlines(keepends=True)
    # Only replace the checkout body; decorators/signature/other functions stay byte-identical.
    start = sum(len(line) for line in lines[:function.body[0].lineno - 1])
    end = sum(len(line) for line in lines[:function.end_lineno])
    body = source[start:end]
    if MARKER in "".join(lines[function.lineno - 1:function.end_lineno]):
        return source
    if len(function.body) != 1 or not isinstance(function.body[0], ast.Try) or function.body[0].finalbody:
        raise ValueError("Unexpected checkout structure; no changes made.")
    newline = "\r\n" if "\r\n" in source else "\n"

    def replace_once(old, new, count=1):
        nonlocal body
        if body.count(old) != count:
            raise ValueError("Checkout code differs from the reviewed version; no changes made.")
        body = body.replace(old, new)

    # The latest IN already supplies the office type; avoid loading it again.
    assignments = {
        node.targets[0].id: node for node in ast.walk(function)
        if isinstance(node, ast.Assign) and len(node.targets) == 1
        and isinstance(node.targets[0], ast.Name)
    }
    latest = assignments["latest_checkin"].value
    fields = next(keyword.value for keyword in latest.keywords if keyword.arg == "fields")
    if ast.literal_eval(fields) != ["name", "time"]:
        raise ValueError("Unexpected latest-checkin fields; no changes made.")
    latest_old = ast.get_source_segment(source, latest)
    latest_new = latest_old.replace(ast.get_source_segment(source, fields), '["name", "time", "custom_office_type"]')
    replace_once(latest_old, latest_new)
    office_lookup = assignments["custom_office_type"].value
    replace_once(ast.get_source_segment(source, office_lookup),
                 '(latest_checkin[0].get("custom_office_type") if latest_checkin else None)')

    # Retain only the fields used by the unchanged Visit-building branches.
    previous = assignments["previous_visit"].value
    previous_old = ast.get_source_segment(source, previous)
    previous_new = previous_old.replace("SELECT *", "SELECT event_id, creation, latitude, longitude, destination_lat, destination_lng, source, destination")
    if previous_new == previous_old:
        raise ValueError("Unexpected previous-visit query; no changes made.")
    replace_once(previous_old, previous_new)

    # Instrument exact existing calls, retaining args, order and transactions.
    timed_assignments = {
        "employeeid": "checkout_employee_lookup",
        "event_visit_in_progress": "checkout_active_visit",
        "latest_checkin": "checkout_latest_in",
        "latest_checkout": "checkout_latest_out",
        "previous_visit": "checkout_previous_visit",
    }
    for name, stage in timed_assignments.items():
        call = assignments[name].value
        old = ast.get_source_segment(source, call)
        if name == "latest_checkin":
            old = latest_new
        elif name == "previous_visit":
            old = previous_new
        func = ast.get_source_segment(source, call.func)
        replace_once(old, 'checkout_timed("' + stage + '", ' + func + ', ' + old[len(func) + 1:])
    for old, stage in [
        ('doc.save(ignore_permissions=True)', 'checkout_checkin_save'),
        ('visit.save(ignore_permissions=True)', 'checkout_visit_save'),
        ('frappe.db.commit()', 'checkout_commit'),
    ]:
        func, args = old.split('(', 1)
        replace_once(old, 'checkout_timed("' + stage + '", ' + func + (', ' if args != ')' else '') + args)
    replace_once('requests.request("GET", url, headers=headers, data=payload)',
                 'checkout_maps_response(url, headers, payload)', count=2)
    result = source[:start] + HELPERS.lstrip('\n').replace('\n', newline) + body.rstrip('\r\n') + newline + FINALLY.lstrip('\n').replace('\n', newline) + source[end:]
    ast.parse(result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("api_file", type=Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    path = args.api_file.resolve(strict=True)
    original = path.read_bytes()
    updated = patch_source(original.decode("utf-8")).encode("utf-8")
    if updated == original:
        print("Checkout patch already installed; no changes made.")
        return
    if not args.apply:
        print("Patch validated. Only checkout() will change. Run with --apply to install.")
        return
    backup = path.with_name(path.name + ".before-checkout-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
    shutil.copy2(path, backup)
    # Keep the original file's ownership/mode. Reject an intervening edit.
    if path.read_bytes() != original:
        raise RuntimeError("api.py changed during patch preparation; retry against the latest file.")
    try:
        path.write_bytes(updated)
    except Exception:
        path.write_bytes(original)
        raise
    print("Patched checkout(). Backup: " + str(backup))
    print("Restart the bench web processes to load the updated Python code.")


if __name__ == "__main__":
    main()
