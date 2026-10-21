"""Focused checks for the employee-keyed FCM registration patch."""
import importlib.util
from pathlib import Path
import sys
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch


class Doc:
    def __init__(self, values):
        self.values = dict(values)
        self.save = Mock()
        self.insert = Mock()

    def set(self, key, value):
        self.values[key] = value


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.frappe = ModuleType('frappe')
        self.frappe.whitelist = lambda **kwargs: lambda function: function
        self.frappe.session = SimpleNamespace(user='staff@example.test')
        self.frappe.PermissionError = PermissionError
        self.frappe.throw = Mock(side_effect=lambda message, kind=ValueError: (_ for _ in ()).throw(kind(message)))
        self.frappe.db = SimpleNamespace(get_value=Mock(side_effect=['EMP-1', 'EMP-1']))
        self.doc = Doc({'employee': 'EMP-1', 'fcm_token': 'old-token', 'device_id': 'old-device'})
        self.frappe.get_doc = Mock(return_value=self.doc)
        self.utils = ModuleType('frappe.utils')
        self.utils.now_datetime = Mock(return_value='2026-10-15 13:00:00')
        with patch.dict(sys.modules, {'frappe': self.frappe, 'frappe.utils': self.utils}):
            spec = importlib.util.spec_from_file_location('registration_patch', Path(__file__).resolve().parents[1] / 'backend_patches/fcm_device_registration.py')
            self.module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.module)

    def test_rotated_token_updates_same_employee_and_all_fields(self):
        result = self.module.register_device('new-token', 'ANDROID', 'device', '1.2.3', '42')
        self.assertEqual(result, {'status': 'success', 'user': 'staff@example.test'})
        self.assertEqual(self.doc.values, {
            'employee': 'EMP-1', 'user': 'staff@example.test', 'fcm_token': 'new-token',
            'platform': 'android', 'is_active': 1, 'last_seen': '2026-10-15 13:00:00',
            'device_id': 'device', 'app_version': '1.2.3', 'build_version': '42',
        })
        self.doc.save.assert_called_once_with(ignore_permissions=True)
        self.doc.insert.assert_not_called()
        self.frappe.db.get_value.assert_any_call('FCM Device', {'employee': 'EMP-1'}, 'name', for_update=True)
        self.frappe.db.get_value.assert_any_call('Employee', {'user_id': 'staff@example.test'}, 'name', for_update=True)
        self.frappe.get_doc.assert_called_once_with('FCM Device', 'EMP-1', for_update=True)

    def test_notification_refresh_preserves_mobile_login_binding(self):
        self.doc.values.update({
            'custom_mobile_device_hash': 'hash',
            'custom_mobile_session_id': 'sid',
        })
        self.module.register_device('new-token', 'android')
        self.assertEqual(self.doc.values['custom_mobile_device_hash'], 'hash')
        self.assertEqual(self.doc.values['custom_mobile_session_id'], 'sid')
        self.assertEqual(self.doc.values['is_active'], 1)

    def test_first_registration_inserts_employee_keyed_document(self):
        self.frappe.db.get_value.side_effect = ['EMP-1', None]
        self.module.register_device('new-token', 'android', 'device', '1.0', '1')
        values = self.frappe.get_doc.call_args.args[0]
        self.assertEqual(values['doctype'], 'FCM Device')
        self.assertEqual(values['employee'], 'EMP-1')
        self.doc.insert.assert_called_once_with(ignore_permissions=True)
        self.doc.save.assert_not_called()

    def test_legacy_clients_do_not_erase_device_metadata(self):
        self.module.register_device('token', 'android')
        self.assertEqual(self.doc.values['device_id'], 'old-device')
        self.assertEqual(self.doc.values['last_seen'], '2026-10-15 13:00:00')

    def test_guest_cannot_register(self):
        self.frappe.session.user = 'Guest'
        with self.assertRaises(PermissionError):
            self.module.register_device('token', 'android')
        self.frappe.db.get_value.assert_not_called()

    def test_employee_is_resolved_from_session_not_request(self):
        self.frappe.db.get_value.side_effect = [None]
        with self.assertRaisesRegex(ValueError, 'No Employee'):
            self.module.register_device('token', 'android')
        self.frappe.get_doc.assert_not_called()

    def test_missing_token_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Missing FCM'):
            self.module.register_device('', 'android')
        self.frappe.get_doc.assert_not_called()

    def test_invalid_platform_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Platform'):
            self.module.register_device('token', 'unknown')
        self.frappe.get_doc.assert_not_called()


if __name__ == '__main__':
    unittest.main()
