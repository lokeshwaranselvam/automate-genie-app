"""Behavior of the restricted notification-save guard alongside login binding."""
import ast
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock


SCRIPT = Path(__file__).resolve().parents[1] / 'frappe_server_scripts/fcm_device_validation.py'


class FcmDeviceValidationTests(unittest.TestCase):
    def run_guard(self, *, old=None, new=False, other_rows=None, shared=False, **values):
        data = {'user': 'staff@example.test', 'employee': 'EMP-1',
                'device_id': 'phone-1', 'is_active': 1, **values}
        doc = SimpleNamespace(get=data.get, name='EMP-1', is_new=lambda: new)
        def throw(message, **kwargs):
            raise ValueError(message)
        self.frappe = SimpleNamespace(
            throw=throw,
            db=SimpleNamespace(get_value=Mock(return_value=old), exists=Mock(return_value=shared)),
            get_all=Mock(return_value=other_rows or []),
        )
        exec(compile(SCRIPT.read_text(), str(SCRIPT), 'exec'), {'doc': doc, 'frappe': self.frappe})

    def test_initial_inactive_login_row_allows_missing_notification_id(self):
        self.run_guard(new=True, device_id=None, is_active=0)
        self.frappe.get_all.assert_not_called()
        self.frappe.db.exists.assert_not_called()

    def test_active_notification_registration_requires_device_id(self):
        with self.assertRaisesRegex(ValueError, 'Device ID is required'):
            self.run_guard(new=True, device_id=None)

    def test_first_registration_can_fill_blank_id_on_existing_login_row(self):
        self.run_guard(old={'user': 'staff@example.test', 'employee': 'EMP-1', 'device_id': None})

    def test_same_device_token_refresh_is_allowed(self):
        self.run_guard(old={'user': 'staff@example.test', 'employee': 'EMP-1', 'device_id': 'phone-1'})

    def test_user_employee_or_established_id_cannot_be_changed(self):
        old = {'user': 'staff@example.test', 'employee': 'EMP-1', 'device_id': 'phone-1'}
        for values in ({'user': 'other@example.test'}, {'employee': 'EMP-2'},
                       {'device_id': 'phone-2'}, {'device_id': None, 'is_active': 0}):
            with self.subTest(values=values), self.assertRaisesRegex(ValueError, 'Wrong User'):
                self.run_guard(old=old, **values)

    def test_different_device_on_another_row_for_same_user_is_blocked(self):
        with self.assertRaisesRegex(ValueError, 'Wrong User'):
            self.run_guard(new=True, other_rows=[{'device_id': 'phone-2'}])

    def test_device_shared_with_another_user_is_blocked(self):
        with self.assertRaisesRegex(ValueError, 'Wrong User'):
            self.run_guard(new=True, shared=True)

    def test_user_is_required_even_for_inactive_login_row(self):
        with self.assertRaisesRegex(ValueError, 'User is required'):
            self.run_guard(new=True, user='', is_active=0, device_id=None)

    def test_restricted_script_has_no_imports_or_custom_functions(self):
        tree = ast.parse(SCRIPT.read_text())
        self.assertFalse(any(isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef,
                                              ast.AsyncFunctionDef, ast.ClassDef))
                             for node in ast.walk(tree)))


if __name__ == '__main__':
    unittest.main()
