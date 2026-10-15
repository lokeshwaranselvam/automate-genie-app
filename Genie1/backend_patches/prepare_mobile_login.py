"""Prepare a copy of the LIVE API module; replace only login/mobile_logout."""
import ast
from pathlib import Path
import sys


def prepare(source):
    tree = ast.parse(source)
    lines = source.splitlines(keepends=True)
    replacements = {
        'login': '''@frappe.whitelist(allow_guest=True, methods=["POST"])
def login(usr, pwd, device_key=None):
    from .mobile_auth import login as mobile_login
    return mobile_login(usr, pwd, device_key)
''',
        'mobile_logout': '''@frappe.whitelist(allow_guest=True, methods=["POST"])
def mobile_logout(user, device_key):
    from .mobile_auth import logout as release_mobile_login
    return release_mobile_login(user, device_key)
''',
    }
    edits = []
    found = set()
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name in replacements:
            if node.name in found:
                raise ValueError('Duplicate function: ' + node.name)
            found.add(node.name)
            start = min([node.lineno] + [d.lineno for d in node.decorator_list]) - 1
            edits.append((start, node.end_lineno, replacements[node.name]))
    if 'login' not in found:
        raise ValueError('Expected a top-level login function; input left unchanged.')
    for start, end, replacement in sorted(edits, reverse=True):
        lines[start:end] = [replacement]
    result = ''.join(lines)
    if 'mobile_logout' not in found:
        result += '\n\n' + replacements['mobile_logout']
    ast.parse(result)
    return result


if __name__ == '__main__':
    source, output = map(Path, sys.argv[1:])
    if source.resolve() == output.resolve():
        raise ValueError('Choose a separate output file; never overwrite the live input.')
    output.write_text(prepare(source.read_text(encoding='utf-8')), encoding='utf-8')
