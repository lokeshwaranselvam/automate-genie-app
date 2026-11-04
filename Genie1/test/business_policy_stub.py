"""Execute the real shared policy while preserving endpoint-specific test mocks."""
import json
from datetime import date
from pathlib import Path
from types import SimpleNamespace

SOURCE = (Path(__file__).resolve().parents[1] / 'frappe_server_scripts/mobile_business_policy.py').read_text()

class Row(dict):
    __getattr__ = dict.get
    __setattr__ = dict.__setitem__

class PolicyCall:
    def __init__(self, frappe, original=None):
        object.__setattr__(self, 'frappe', frappe)
        object.__setattr__(self, 'original', original)
        object.__setattr__(self, 'overrides', {})
    def __getattr__(self, key):
        return getattr(self.original, key)
    def __setattr__(self, key, value):
        if key in ['side_effect', 'return_value']:
            setattr(self.original, key, value)
        else:
            object.__setattr__(self, key, value)
    def __call__(self, method, **kwargs):
        if method != 'mobile_business_policy':
            return self.original(method, **kwargs)
        frappe = self.frappe
        old_form = getattr(frappe, 'form_dict', None)
        old_flags = getattr(frappe, 'flags', None)
        old_utils = getattr(frappe, 'utils', None)
        utils = dict(vars(old_utils)) if old_utils else {}
        utils.setdefault('today', lambda: '2026-10-26')
        utils.setdefault('getdate', date.fromisoformat)
        frappe.utils = SimpleNamespace(**utils)
        frappe.form_dict = dict(old_form or {}, **kwargs)
        frappe.flags = Row()
        source = SOURCE
        for old, new in self.overrides.items(): source = source.replace(old, new)
        try:
            exec(compile(source, 'mobile_business_policy.py', 'exec'), {'frappe': frappe, 'json': json})
            return dict(frappe.flags)
        finally:
            frappe.form_dict = old_form
            frappe.flags = old_flags
            frappe.utils = old_utils

def install(frappe):
    if not isinstance(getattr(frappe, 'call', None), PolicyCall):
        frappe.call = PolicyCall(frappe, getattr(frappe, 'call', None))
    return frappe.call
