"""Local mocks only: python -m unittest discover -s test -p automategenie_fcm_sender_test.py"""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


class Row(dict):
    __getattr__ = dict.get


class AutomateGenieFcmSenderTest(unittest.TestCase):
    def setUp(self):
        self.user = "creator@example.test"
        self.recipient = "assignee@example.test"
        self.event = Row(name="EV-1", owner=self.user, subject="Actual event", docstatus=0, status="Open")
        self.event.check_permission = Mock()
        self.assignment = SimpleNamespace(reference_type="Event", reference_name="EV-1",
                                          allocated_to=self.recipient, status="Open")
        self.frappe = SimpleNamespace(
            whitelist=lambda **kwargs: lambda method: method,
            session=SimpleNamespace(user=self.user), local=SimpleNamespace(site="live-site"),
            PermissionError=PermissionError,
            throw=Mock(side_effect=lambda message, error=ValueError: (_ for _ in ()).throw(error(message))),
            get_doc=Mock(return_value=self.event),
            db=SimpleNamespace(get_value=Mock(side_effect=self.get_value), exists=Mock(return_value=False)),
            get_all=Mock(return_value=[{"fcm_token": "fake-local-token"}]), log_error=Mock(),
        )
        self.app = SimpleNamespace(project_id="automategenie-mobile")
        self.credentials = SimpleNamespace(Certificate=Mock(return_value=SimpleNamespace(project_id="automategenie-mobile")))
        self.messaging = SimpleNamespace(Message=Mock(), AndroidConfig=Mock(), send=Mock(return_value="projects/automategenie-mobile/messages/test"))
        self.firebase = SimpleNamespace(get_app=Mock(return_value=self.app), initialize_app=Mock(return_value=self.app),
                                        credentials=self.credentials, messaging=self.messaging)
        path = Path(__file__).resolve().parents[1] / "backend_patches/automategenie_fcm/fcm_utils.py"
        spec = importlib.util.spec_from_file_location("local_automategenie_fcm_sender", path)
        self.module = importlib.util.module_from_spec(spec)
        with patch.dict("sys.modules", {"frappe": self.frappe, "firebase_admin": self.firebase}):
            spec.loader.exec_module(self.module)
        self.payload = {"type": "EVENT_ASSIGNED", "doctype": "Event", "docname": "EV-1",
                        "assignment_id": "TODO-1", "for_user": self.recipient,
                        "title": "Untrusted title", "body": "Untrusted body"}

    def get_value(self, doctype, *args, **kwargs):
        return self.assignment if doctype == "ToDo" else 1

    def send(self):
        return self.module.send_fcm_to_user(self.recipient, self.payload)

    def test_verified_assignment_uses_named_project_and_canonical_data_only_payload(self):
        self.assertEqual(self.send()["status"], "sent")
        self.firebase.get_app.assert_called_once_with("automategenie-mobile:live-site")
        self.messaging.send.assert_called_once_with(self.messaging.Message.return_value, app=self.app)
        args = self.messaging.Message.call_args.kwargs
        self.assertNotIn("notification", args)
        self.assertEqual(args["data"]["body"], "Actual event")
        self.assertEqual(args["data"]["title"], "New event assigned")
        self.assertEqual(args["data"]["assignment_id"], "TODO-1")
        self.assertEqual(args["data"]["for_user"], self.recipient)
        self.messaging.AndroidConfig.assert_called_once_with(priority="high")
        self.assertEqual(self.frappe.get_all.call_args.kwargs["limit_page_length"], 1)

    def test_initialization_uses_sibling_credential_and_leaves_default_app_untouched(self):
        self.firebase.get_app.side_effect = ValueError("Not initialized")
        self.assertEqual(self.send()["status"], "sent")
        credential_path = Path(self.credentials.Certificate.call_args.args[0])
        self.assertEqual(credential_path.name, "automategenie-service-account.json")
        self.assertEqual(credential_path.parent, Path(self.module.__file__).parent)
        self.assertEqual(self.firebase.initialize_app.call_args.kwargs["name"], "automategenie-mobile:live-site")

    def test_only_recipient_sales_user_or_designer_role_enables_alarm(self):
        for roles, expected in [([], "0"), (["Employee"], "0"),
                                (["Sales Manager"], "0"), (["Sales User"], "1"),
                                (["Designer"], "1"), (["Sales User", "Designer"], "1"),
                                (["Sales Manager", "Sales User"], "1")]:
            with self.subTest(roles=roles):
                self.frappe.db.exists.side_effect = lambda doctype, filters: (
                    doctype == "Has Role" and filters["parent"] == self.recipient
                    and filters["parenttype"] == "User" and filters["parentfield"] == "roles"
                    and any(role in roles for role in filters["role"][1])
                )
                # Caller-provided flags cannot enable or disable the alarm.
                self.payload["alarm_enabled"] = "0" if expected == "1" else "1"
                self.assertEqual(self.send()["status"], "sent")
                data = self.messaging.Message.call_args.kwargs["data"]
                self.assertEqual(data["alarm_enabled"], expected)
                self.assertEqual(data["for_user"], self.recipient)

    def test_guest_cannot_send(self):
        self.frappe.session.user = "Guest"
        with self.assertRaises(PermissionError):
            self.send()
        self.messaging.send.assert_not_called()

    def test_different_event_owner_requires_document_write_permission(self):
        self.event["owner"] = "someone-else@example.test"
        self.event.check_permission.side_effect = PermissionError("Denied")
        with self.assertRaises(PermissionError):
            self.send()
        self.event.check_permission.assert_called_once_with("write")
        self.messaging.send.assert_not_called()

    def test_assignment_must_match_event_recipient_and_open_status(self):
        for field, value in [("reference_type", "Opportunity"), ("reference_name", "EV-2"),
                             ("allocated_to", "other@example.test"), ("status", "Cancelled")]:
            old = getattr(self.assignment, field)
            setattr(self.assignment, field, value)
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.send()
            setattr(self.assignment, field, old)
        self.messaging.send.assert_not_called()

    def test_recipient_and_payload_type_cannot_be_forged(self):
        for field, value in [("for_user", "other@example.test"), ("type", "LEAD_ASSIGNED"),
                             ("assignment_id", ""), ("docname", [])]:
            old = self.payload[field]
            self.payload[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.send()
            self.payload[field] = old
        self.messaging.send.assert_not_called()

    def test_wrong_credential_project_does_not_send(self):
        self.firebase.get_app.side_effect = ValueError("Not initialized")
        self.credentials.Certificate.return_value.project_id = "old-project"
        self.assertEqual(self.send()["status"], "failed")
        self.firebase.initialize_app.assert_not_called()
        self.messaging.send.assert_not_called()

    def test_cached_wrong_project_does_not_send(self):
        self.app.project_id = "old-project"
        self.assertEqual(self.send()["status"], "failed")
        self.messaging.send.assert_not_called()

    def test_missing_token_does_not_change_device_binding(self):
        self.frappe.get_all.return_value = []
        self.assertEqual(self.send()["status"], "failed")
        self.assertEqual(self.frappe.log_error.call_args.kwargs["title"], "FCM Token Missing")
        self.messaging.send.assert_not_called()

    def test_sdk_failure_logs_no_token_or_error_text(self):
        self.messaging.send.side_effect = RuntimeError("sensitive-fake-token")
        self.assertEqual(self.send()["status"], "failed")
        entry = self.frappe.log_error.call_args.kwargs
        self.assertEqual(entry["title"], "FCM Push Failed")
        self.assertIn("RuntimeError", entry["message"])
        self.assertNotIn("sensitive-fake-token", entry["message"])

    def test_cancelled_event_does_not_send(self):
        self.event["docstatus"] = 2
        self.assertEqual(self.send()["status"], "failed")
        self.messaging.send.assert_not_called()

    def test_json_payload_supported_and_invalid_json_rejected(self):
        import json
        self.payload = json.dumps(self.payload)
        self.assertEqual(self.send()["status"], "sent")
        self.payload = "not json"
        with self.assertRaises(ValueError):
            self.send()


if __name__ == "__main__":
    unittest.main()
