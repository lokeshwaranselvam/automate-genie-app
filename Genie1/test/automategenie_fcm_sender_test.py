"""Generic sender transport mocks; no live Frappe/Firebase operations."""
import importlib.util
import json
from contextlib import nullcontext
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
        self.document = Row(doctype="Lead", name="LEAD-1", owner=self.user)
        self.document.has_permission = Mock(return_value=True)
        self.rule = Row(name="New Lead", document_type="Lead", channel="FCM", enabled=1, event="New")
        self.frappe = SimpleNamespace(
            session=SimpleNamespace(user=self.user), local=SimpleNamespace(site="live-site"),
            PermissionError=PermissionError,
            throw=Mock(side_effect=lambda message, error=ValueError: (_ for _ in ()).throw(error(message))),
            get_doc=Mock(return_value=self.document),
            db=SimpleNamespace(get_value=Mock(side_effect=self.get_value), exists=Mock(return_value=False)),
            get_all=Mock(return_value=[{"fcm_token": "fake-local-token"}]), log_error=Mock(),
            cache=Mock(return_value=SimpleNamespace(lock=lambda *a, **k: nullcontext(),
                get_value=lambda key: None, set_value=Mock())),
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
        self.payload = {"type": "DOCUMENT_NOTIFICATION", "notification_name": "New Lead",
                        "doctype": "Lead", "docname": "LEAD-1", "for_user": self.recipient,
                        "title": "New lead", "body": "Contact the customer"}

    def get_value(self, doctype, *args, **kwargs):
        return 1

    def send(self):
        marker = self.module._NOTIFICATION_DISPATCH.set({
            "rule": self.rule, "document": self.document, "version": "revision-1"})
        try:
            return self.module.send_fcm_to_user(self.recipient, self.payload)
        finally:
            self.module._NOTIFICATION_DISPATCH.reset(marker)

    def test_generic_notification_uses_named_project_and_shared_data_payload(self):
        self.assertEqual(self.send()["status"], "sent")
        self.firebase.get_app.assert_called_once_with("automategenie-mobile:live-site")
        args = self.messaging.Message.call_args.kwargs
        self.assertNotIn("notification", args)
        self.assertEqual(args["data"]["type"], "DOCUMENT_NOTIFICATION")
        self.assertEqual(args["data"]["body"], "Contact the customer")
        self.assertEqual(args["data"]["for_user"], self.recipient)
        self.messaging.AndroidConfig.assert_called_once_with(priority="high")
        self.assertEqual(self.frappe.get_all.call_args.kwargs["limit_page_length"], 1)

    def test_initialization_uses_sibling_credential_and_keeps_default_app(self):
        self.firebase.get_app.side_effect = ValueError("Not initialized")
        self.assertEqual(self.send()["status"], "sent")
        path = Path(self.credentials.Certificate.call_args.args[0])
        self.assertEqual(path.name, "automategenie-service-account.json")
        self.assertEqual(path.parent, Path(self.module.__file__).parent)
        self.assertEqual(self.firebase.initialize_app.call_args.kwargs["name"], "automategenie-mobile:live-site")

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
        self.messaging.send.assert_not_called()

    def test_sdk_errors_do_not_log_device_tokens_or_raw_exception_text(self):
        self.messaging.send.side_effect = RuntimeError("sensitive-device-token")
        self.assertEqual(self.send()["status"], "failed")
        self.assertIn("RuntimeError", str(self.frappe.log_error.call_args))
        self.assertNotIn("sensitive-device-token", str(self.frappe.log_error.call_args))

    def test_legacy_event_payload_is_rejected_and_has_no_separate_sender(self):
        self.payload = {"type": "EVENT_ASSIGNED", "doctype": "Event", "docname": "EV-1"}
        with self.assertRaisesRegex(ValueError, "Only generic"):
            self.send()
        self.messaging.send.assert_not_called()

    def test_json_generic_payload_and_invalid_input_validation(self):
        self.payload = json.dumps(self.payload)
        self.assertEqual(self.send()["status"], "sent")
        for payload in ["bad json", "x" * 8193, None, [], {"type": "OTHER"}]:
            self.payload = payload
            with self.subTest(payload_type=type(payload).__name__), self.assertRaises(ValueError):
                self.send()

    def test_generic_sender_is_internal_not_an_http_whitelisted_method(self):
        self.assertNotIn("@frappe.whitelist", Path(self.module.__file__).read_text())
        with self.assertRaises(PermissionError):
            self.module.send_fcm_to_user(self.recipient, self.payload)
        self.messaging.send.assert_not_called()


if __name__ == "__main__":
    unittest.main()
