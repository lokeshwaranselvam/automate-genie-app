"""Build reviewed checkin/checkout replacements from the supplied api.py.

Usage: python prepare_attendance_api.py /path/to/api.py /path/to/replacements.py
The input is never modified. Copy both generated functions into utils/api.py.
"""
import argparse
import ast
from pathlib import Path

from checkout_performance import patch_source
from checkin_performance import patch_source as patch_checkin


def build_replacements(source):
    source = patch_source(source)
    tree = ast.parse(source)
    lines = source.splitlines(keepends=True)
    replacements = []
    for name in ("checkin", "checkout"):
        functions = [node for node in tree.body
                     if isinstance(node, ast.FunctionDef) and node.name == name]
        if len(functions) != 1:
            raise ValueError("Expected exactly one " + name + " function.")
        function = functions[0]
        first_line = min([function.lineno] + [node.lineno for node in function.decorator_list])
        text = "".join(lines[first_line - 1:function.end_lineno])
        # Frappe dispatch binds query arguments to the whitelisted signature.
        # The hooks still read and validate these fields from frappe.form_dict.
        existing = {arg.arg for arg in function.args.args + function.args.kwonlyargs}
        missing = [arg for arg in ("photo_url", "face_verification", "include_timings")
                   if arg not in existing]
        if missing:
            signature_end = sum(len(line) for line in lines[:function.body[0].lineno - 1])
            signature_start = sum(len(line) for line in lines[:function.lineno - 1])
            signature = source[signature_start:signature_end]
            closing = signature.rfind("):")
            if closing < 0:
                raise ValueError("Unsupported " + name + " signature.")
            updated = signature[:closing] + ", " + ", ".join(arg + "=None" for arg in missing) + signature[closing:]
            text = text.replace(signature, updated, 1)
        replacements.append(text.rstrip())
    replacements[0] = patch_checkin(replacements[0])
    result = (
        '# Replace checkin() and checkout() in ts_homegenie/ts_homegenie/utils/api.py.\n'
        '# Keep both Employee Checkin face guard/attachment Server Scripts enabled.\n'
        '# These are app-module functions, not a Frappe API Server Script.\n'
        'import json\nimport requests\nimport frappe\n'
        'from frappe.utils import getdate, nowdate, now_datetime\n\n\n'
        + "\n\n\n".join(replacements) + "\n"
    )
    ast.parse(result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("api_file", type=Path)
    parser.add_argument("output_file", type=Path)
    args = parser.parse_args()
    if args.api_file.resolve() == args.output_file.resolve():
        raise ValueError("Output must differ from the original API file.")
    args.output_file.write_text(build_replacements(args.api_file.read_text(encoding="utf-8")), encoding="utf-8")
    print("Created checkin/checkout replacements: " + str(args.output_file))


if __name__ == "__main__":
    main()
