"""Notification-only regression checks for the deployed registration contract."""
import importlib.util
from pathlib import Path
import sys
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.frappe = ModuleType("frappe")
        self.frappe.whitelist = lambda **kwargs: lambda function: function
        self.frappe.session = SimpleNamespace(user="test@example.test")
        self.frappe.PermissionError = PermissionError
        self.frappe.throw = Mock(side_effect=lambda message, kind=ValueError: self.raise_error(message, kind))
        self.existing = {"name": "EMP-TEST", "user": "test@example.test"}
        self.frappe.db = SimpleNamespace(
            get_value=Mock(side_effect=["EMP-TEST", self.existing]),
            set_value=Mock(), commit=Mock(),
        )
        self.doc = SimpleNamespace(name="EMP-TEST", insert=Mock())
        self.frappe.get_doc = Mock(return_value=self.doc)
        self.frappe.utils = SimpleNamespace(now=lambda: "2026-11-04 15:00:00")
        with patch.dict(sys.modules, {"frappe": self.frappe}):
            spec = importlib.util.spec_from_file_location("registration_patch",
                Path(__file__).resolve().parents[1] / "backend_patches/fcm_device_registration.py")
            self.module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.module)

    @staticmethod
    def raise_error(message, kind):
        raise kind(message)

    def test_pwa_updates_login_created_record_without_platform_filter(self):
        result = self.module.register_device("web-token", "browser-device", "ios", "1.2.3", "42")
        self.assertEqual(result, {"status": "success", "device": "EMP-TEST", "app_version": "1.2.3", "build_version": 42})
        self.frappe.db.get_value.assert_any_call("FCM Device", {"employee": "EMP-TEST"},
            ["name", "user"], as_dict=True, for_update=True)
        self.frappe.get_doc.assert_not_called()
        values = self.frappe.db.set_value.call_args.args[2]
        self.assertEqual(values["platform"], "ios")
        self.assertEqual(values["fcm_token"], "web-token")
        self.assertEqual(values["device_id"], "browser-device")
        self.assertEqual(values["is_active"], 1)

    def test_android_positional_parameters_and_response_are_preserved(self):
        result = self.module.register_device("android-token", "android-device", "android", "2.0", "7")
        values = self.frappe.db.set_value.call_args.args[2]
        self.assertEqual(values["device_id"], "android-device")
        self.assertEqual(values["platform"], "android")
        self.assertEqual(result["build_version"], 7)

    def test_android_default_platform_is_preserved(self):
        self.module.register_device("token")
        self.assertEqual(self.frappe.db.set_value.call_args.args[2]["platform"], "android")

    def test_employee_lock_serializes_first_insert_and_refresh(self):
        self.module.register_device("token")
        self.frappe.db.get_value.assert_any_call("Employee", {"user_id": "test@example.test"}, "name", for_update=True)
        self.frappe.db.commit.assert_called_once()

    def test_first_registration_inserts_linked_employee(self):
        self.frappe.db.get_value.side_effect = ["EMP-TEST", None]
        self.module.register_device("token", "device", "ios")
        values = self.frappe.get_doc.call_args.args[0]
        self.assertEqual(values["employee"], "EMP-TEST")
        self.assertEqual(values["user"], "test@example.test")
        self.doc.insert.assert_called_once_with(ignore_permissions=True)
        self.frappe.db.set_value.assert_not_called()

    def test_notification_update_does_not_write_login_binding_fields(self):
        self.module.register_device("token", "device", "ios")
        fields = self.frappe.db.set_value.call_args.args[2]
        self.assertEqual(set(fields), {"user", "employee", "fcm_token", "device_id", "platform", "is_active", "last_seen", "app_version", "build_version"})

    def test_record_owned_by_another_user_is_rejected(self):
        self.existing["user"] = "other@example.test"
        with self.assertRaises(PermissionError):
            self.module.register_device("token")
        self.frappe.db.set_value.assert_not_called()
        self.frappe.db.commit.assert_not_called()

    def test_missing_employee_is_rejected(self):
        self.frappe.db.get_value.side_effect = [None]
        with self.assertRaisesRegex(ValueError, "No Employee"):
            self.module.register_device("token")
        self.frappe.get_doc.assert_not_called()

    def test_guest_is_rejected(self):
        self.frappe.session.user = "Guest"
        with self.assertRaises(PermissionError):
            self.module.register_device("token")
        self.frappe.db.get_value.assert_not_called()

    def test_invalid_parameters_do_not_write(self):
        for args in [("",), ("token", None, "web"), ("token", None, "ios", None, "invalid")]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                self.module.register_device(*args)
        self.frappe.db.set_value.assert_not_called()
        self.frappe.db.commit.assert_not_called()

    def test_heartbeat_updates_only_matching_active_device_last_seen(self):
        self.frappe.db.get_value.side_effect = ["EMP-TEST"]
        self.assertEqual(self.module.heartbeat("browser-device"), {"status": "success"})
        self.frappe.db.get_value.assert_called_once_with(
            "FCM Device", {"user": "test@example.test", "is_active": 1,
                           "device_id": "browser-device"}, "name", for_update=True,
        )
        self.frappe.db.set_value.assert_called_once_with(
            "FCM Device", "EMP-TEST", "last_seen", "2026-11-04 15:00:00",
            update_modified=False,
        )
        self.frappe.db.commit.assert_not_called()

    def test_heartbeat_does_not_claim_missing_or_other_device(self):
        self.frappe.db.get_value.side_effect = [None]
        self.assertEqual(self.module.heartbeat("other-device"), {"status": "not_registered"})
        self.frappe.db.set_value.assert_not_called()
        self.frappe.get_doc.assert_not_called()

    def test_heartbeat_rejects_guest_and_missing_device(self):
        for value in (None, "", "  ", 123, "a" * 141):
            with self.assertRaises(ValueError):
                self.module.heartbeat(value)
        self.frappe.session.user = "Guest"
        with self.assertRaises(PermissionError):
            self.module.heartbeat("browser-device")
        self.frappe.db.get_value.assert_not_called()


if __name__ == "__main__":
    unittest.main()
