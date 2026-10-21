"""Contract checks for the restricted lead API script, with a mocked ERP."""
import ast
from pathlib import Path
from types import SimpleNamespace
import unittest


class LeadCreationApiTest(unittest.TestCase):
    script = (Path(__file__).resolve().parents[1] /
              'frappe_server_scripts/create_lead_from_mobile.py').read_text(encoding='utf-8')

    def run_api(self, whatsapp=None, method='POST', view='', user='sales@example.test', has_field=True, has_source=True):
        self.saved = []
        self.queries = []
        values = {
            'first_name': 'Customer', 'mobile_no': '9876543210',
            'custom_requirement': 'Doors', 'source': 'Website',
            'custom_product_enquired': 'Doors', 'custom_address': 'Chennai',
            'view': view, 'lead': 'LEAD-1',
        }
        if whatsapp is not None:
            values['whatsapp_no'] = whatsapp

        def field(name):
            if name == 'source' and not has_source:
                return None
            if name == 'whatsapp_no' and not has_field:
                return None
            if name in ['source', 'custom_product_enquired']:
                return SimpleNamespace(fieldtype='Select', options=(
                    'Website\nReferral' if name == 'source' else 'Doors\nWindows'))
            return SimpleNamespace(fieldtype='Data', options=None)

        def get_all(doctype, **kwargs):
            self.queries.append((doctype, kwargs))
            return [{'name': 'LEAD-1', 'whatsapp_no': '+919876543210'}]

        def get_value(doctype, filters, fields, **kwargs):
            if doctype == 'User':
                return 'Sales'
            self.assertEqual(filters, {'name': 'LEAD-1', 'lead_owner': user})
            self.assertIn('whatsapp_no', fields)
            return {'name': 'LEAD-1', 'whatsapp_no': '+919876543210'}

        def new_doc(doctype):
            doc = SimpleNamespace(name='LEAD-1', flags=SimpleNamespace())
            if has_source:
                doc.source = 'Existing standard source default'
            def insert(**kwargs):
                # Capture the source value visible to Lead insert hooks.
                self.legacy_source = doc.source
                self.saved.append(doc)
            doc.insert = insert
            return doc

        class Session(dict):
            pass
        session = Session(csrf_token='csrf-test')
        session.user = user
        session.data = SimpleNamespace(csrf_token='csrf-test')
        response = {}
        frappe = SimpleNamespace(
            session=session, form_dict=values, request=SimpleNamespace(method=method),
            response=response, get_meta=lambda dt: SimpleNamespace(get_field=field),
            get_all=get_all, db=SimpleNamespace(get_value=get_value), new_doc=new_doc,
            throw=lambda message: (_ for _ in ()).throw(ValueError(message)),
        )
        exec(self.script, {'frappe': frappe})
        return response['message']

    def test_saves_whatsapp_and_preserves_existing_product_mapping(self):
        response = self.run_api('+91 (98765) 43210')
        self.assertEqual(self.saved[0].whatsapp_no, '+919876543210')
        self.assertEqual(response['whatsapp_no'], '+919876543210')
        self.assertEqual(self.saved[0].custom_product_enquired, 'Doors')
        self.assertEqual(self.saved[0].lead_owner, 'sales@example.test')

    def test_missing_source_field_is_rejected_before_insert(self):
        with self.assertRaisesRegex(ValueError, 'Lead is missing the source field'):
            self.run_api('9876543210', has_source=False)
        self.assertEqual(self.saved, [])

    def test_selected_source_is_saved_to_standard_source_field(self):
        response = self.run_api('9876543210', has_source=True)
        self.assertEqual(self.saved[0].source, 'Website')
        self.assertEqual(response['source'], 'Website')
        self.assertFalse(hasattr(self.saved[0], 'custom_source'))

    def test_whatsapp_is_required(self):
        for number in [None, '', '   ']:
            with self.subTest(number=number), self.assertRaisesRegex(ValueError, 'WhatsApp Number is required'):
                self.run_api(number)
            self.assertEqual(self.saved, [])

    def test_bad_whatsapp_never_creates_a_lead(self):
        for number in ['123', '+1234567890123456', '987abc6543210', '++919876543210', '+0123456789', 1234567890]:
            with self.subTest(number=number), self.assertRaises(ValueError):
                self.run_api(number)
            self.assertEqual(self.saved, [])

    def test_missing_field_cannot_silently_discard_whatsapp(self):
        with self.assertRaisesRegex(ValueError, 'missing the whatsapp_no'):
            self.run_api('9876543210', has_field=False)
        self.assertEqual(self.saved, [])

    def test_list_and_detail_include_whatsapp_with_existing_owner_filters(self):
        self.assertEqual(self.run_api(method='GET', view='list')['leads'][0]['whatsapp_no'], '+919876543210')
        self.assertEqual(self.queries[0][1]['filters'], {'lead_owner': 'sales@example.test'})
        self.assertIn('whatsapp_no', self.queries[0][1]['fields'])
        self.assertTrue({'owner', 'creation', 'modified', 'modified_by', 'docstatus', 'naming_series'}.issubset(self.queries[0][1]['fields']))
        self.assertEqual(self.run_api(method='GET', view='detail')['lead']['whatsapp_no'], '+919876543210')

    def test_dropdown_response_keys_are_backwards_compatible(self):
        response = self.run_api(method='GET')
        self.assertEqual(response['product_category_options'], ['Doors', 'Windows'])
        self.assertEqual(response['source_options'], ['Website', 'Referral'])
        self.assertEqual(response['csrf_token'], 'csrf-test')

    def test_guest_is_still_rejected(self):
        with self.assertRaisesRegex(ValueError, 'sign in'):
            self.run_api(user='Guest')

    def test_script_uses_no_imports_or_custom_functions(self):
        tree = ast.parse(self.script)
        self.assertFalse(any(isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef))
                             for node in ast.walk(tree)))


if __name__ == '__main__':
    unittest.main()
