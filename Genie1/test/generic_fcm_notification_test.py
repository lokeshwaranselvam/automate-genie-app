"""Local mocks: no ERP writes and no Firebase delivery."""
from contextlib import contextmanager, nullcontext
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch
import ast
import unittest

from test import automategenie_fcm_sender_test as legacy

Row = legacy.Row


class Flags(Row):
    __setattr__ = dict.__setitem__


SCRIPT = (Path(__file__).resolve().parents[1] / "frappe_server_scripts/mobile_fcm_notification.py").read_text()


class GenericFcmNotificationTest(unittest.TestCase):
    get_value = legacy.AutomateGenieFcmSenderTest.get_value

    def setUp(self):
        legacy.AutomateGenieFcmSenderTest.setUp(self)
        self.document = Row(doctype="Lead", name="LEAD-1", owner=self.user, modified="2026-10-28 12:00:00")
        self.document.has_permission = Mock(return_value=True)
        self.rule = Row(name="New Lead", document_type="Lead", channel="FCM", enabled=1,
                        event="New", subject="New lead", message="Please contact the customer")
        self.rule.get_list_of_recipients = Mock(return_value=(
            [self.recipient, self.recipient, "disabled@example.test"], [], []))
        self.payload = {"type": "DOCUMENT_NOTIFICATION", "notification_name": self.rule.name,
                        "doctype": "Lead", "docname": "LEAD-1", "for_user": self.recipient,
                        "title": "New lead", "body": "Please contact the customer", "alarm_enabled": "1"}
        self.cache_values = {}
        self.cache = SimpleNamespace(lock=Mock(side_effect=lambda *a, **k: nullcontext()),
            get_value=lambda key: self.cache_values.get(key),
            set_value=lambda key, value, **kwargs: self.cache_values.update({key: value}))
        self.frappe.cache = Mock(return_value=self.cache)
        self.frappe.enqueue = Mock()

    @contextmanager
    def trusted(self, version="2026-10-28 12:00:00"):
        marker = self.module._NOTIFICATION_DISPATCH.set({
            "rule": self.rule, "document": self.document, "version": version})
        try:
            yield
        finally:
            self.module._NOTIFICATION_DISPATCH.reset(marker)

    def send(self):
        return self.module.send_fcm_to_user(self.recipient, self.payload)

    def test_generic_payload_is_not_a_public_broadcast_endpoint(self):
        with self.assertRaises(PermissionError):
            self.send()
        self.messaging.send.assert_not_called()

    def test_shared_payload_and_server_owned_alarm_flag(self):
        with self.trusted():
            self.assertEqual(self.send()["status"], "sent")
        data = self.messaging.Message.call_args.kwargs["data"]
        self.assertEqual(data["doctype"], "Lead")
        self.assertEqual(data["docname"], "LEAD-1")
        self.assertEqual(data["notification_name"], "New Lead")
        self.assertEqual(data["alarm_enabled"], "0")
        self.assertEqual(data["assignment_id"], "")
        self.assertNotIn("notification", self.messaging.Message.call_args.kwargs)

    def test_sales_user_or_designer_enables_alarm(self):
        self.frappe.db.exists.side_effect = lambda dt, filters: (
            dt == "Has Role" and filters["parent"] == self.recipient
            and filters["role"] == ["in", ["Sales User", "Designer"]])
        with self.trusted():
            self.assertEqual(self.send()["status"], "sent")
        self.assertEqual(self.messaging.Message.call_args.kwargs["data"]["alarm_enabled"], "1")

    def test_references_cannot_be_forged(self):
        for key, value in [("doctype", "Task"), ("docname", "LEAD-2"),
                           ("for_user", "other@example.test"), ("notification_name", "Other rule")]:
            with self.subTest(key=key), self.trusted():
                original = self.payload[key]
                self.payload[key] = value
                with self.assertRaises(ValueError):
                    self.send()
                self.payload[key] = original
        self.messaging.send.assert_not_called()

    def test_recipient_must_have_document_access(self):
        self.document.has_permission.return_value = False
        with self.trusted():
            self.assertEqual(self.send()["status"], "skipped")
        self.messaging.send.assert_not_called()

    def test_success_is_deduplicated_but_new_document_version_can_send(self):
        with self.trusted():
            self.assertEqual(self.send()["status"], "sent")
            self.assertEqual(self.send()["status"], "skipped")
        self.assertEqual(self.messaging.send.call_count, 1)
        with self.trusted(version="2026-10-28 12:01:00"):
            self.assertEqual(self.send()["status"], "sent")
        self.assertEqual(self.messaging.send.call_count, 2)

    def test_failed_send_is_not_recorded_as_success_and_secrets_are_not_logged(self):
        self.messaging.send.side_effect = RuntimeError("sensitive-device-token")
        with self.trusted():
            self.assertEqual(self.send()["status"], "failed")
        self.assertFalse(self.cache_values)
        self.assertNotIn("sensitive-device-token", str(self.frappe.log_error.call_args))

    def test_other_channels_disabled_rules_and_custom_events_do_not_send(self):
        for field, value in [("channel", "Email"), ("enabled", 0), ("event", "Custom")]:
            original = self.rule[field]
            self.rule[field] = value
            with self.subTest(field=field), self.trusted():
                self.assertEqual(self.send()["status"], "skipped")
            self.rule[field] = original
        self.messaging.send.assert_not_called()

    def test_channel_extension_preserves_existing_handler(self):
        base_send = Mock(return_value="existing-channel")
        base_validate = Mock()

        class Base(Row):
            send_notification_by_channel = base_send
            validate = base_validate

        class Notification(self.module.FCMNotificationMixin, Base):
            pass

        rule = Notification(self.rule)
        rule["channel"] = "Email"
        self.assertEqual(rule.send_notification_by_channel(self.document, {}), "existing-channel")
        self.frappe.enqueue.assert_not_called()
        rule["channel"] = "FCM"
        rule.send_notification_by_channel(self.document, {})
        self.assertTrue(self.frappe.enqueue.call_args.kwargs["enqueue_after_commit"])
        self.assertEqual(self.frappe.enqueue.call_args.kwargs["doctype"], "Lead")
        rule["send_system_notification"] = 1
        rule.create_system_notification = Mock()
        rule.send_notification_by_channel(self.document, {})
        rule.create_system_notification.assert_called_once_with(self.document, {})

    def test_script_rejects_direct_call_and_has_no_imports_or_custom_functions(self):
        self.assertFalse(any(isinstance(n, (ast.Import, ast.ImportFrom, ast.FunctionDef))
                             for n in ast.walk(ast.parse(SCRIPT))))
        with self.assertRaisesRegex(ValueError, "trusted"):
            exec(compile(SCRIPT, "mobile_fcm_notification.py", "exec"), {"frappe": self.frappe})
        self.messaging.send.assert_not_called()

    def test_fcm_validation_requires_subject_message_and_excludes_custom(self):
        base_validate = Mock()

        class Base(Row):
            validate = base_validate

        class Notification(self.module.FCMNotificationMixin, Base):
            pass

        rule = Notification(self.rule)
        validate_template = Mock()
        with patch.dict("sys.modules", {"frappe.utils.jinja": SimpleNamespace(validate_template=validate_template)}):
            rule.validate()
            base_validate.assert_called_once()
            validate_template.assert_called_once_with("New lead")
            for field, value in [("subject", ""), ("message", ""), ("event", "Custom")]:
                original = rule[field]
                rule[field] = value
                with self.subTest(field=field), self.assertRaises(ValueError):
                    rule.validate()
                rule[field] = original

    def test_channel_setup_preserves_existing_options_and_is_repeatable(self):
        fields = {
            "channel": Row(options="Email\nSlack\nSystem Notification\nSMS\nExisting Custom"),
            "subject": Row(depends_on="eval:doc.channel == 'Email'", mandatory_depends_on="eval:doc.channel == 'Email'"),
            "message": Row(depends_on="eval:!doc.email_template"),
        }
        setters = []

        def setter(doctype, fieldname, property_name, value, property_type):
            self.assertEqual(doctype, "Notification")
            setters.append((fieldname, property_name, value))
            fields[fieldname][property_name] = value

        self.frappe.only_for = Mock()
        self.frappe.get_meta = Mock(return_value=SimpleNamespace(get_field=lambda name: fields[name]))
        self.frappe.clear_cache = Mock()
        with patch.dict("sys.modules", {
            "frappe.custom.doctype.property_setter.property_setter": SimpleNamespace(make_property_setter=setter),
        }):
            self.module.setup_fcm_notification_channel()
            self.assertEqual(fields["channel"]["options"], "Email\nSlack\nSystem Notification\nSMS\nExisting Custom\nFCM")
            self.assertEqual(fields["subject"]["depends_on"],
                "eval:doc.channel == 'FCM' || (doc.channel == 'Email')")
            self.assertEqual(fields["message"]["depends_on"],
                "eval:doc.channel == 'FCM' || (!doc.email_template)")
            count = len(setters)
            self.module.setup_fcm_notification_channel()
            self.assertEqual(len(setters), count)
        self.frappe.only_for.assert_called_with("System Manager")

    def test_channel_setup_repairs_saved_conditions_and_preserves_other_channels(self):
        cases = [
            ("eval:doc.channel == 'FCM' or (in_list(['Email', 'Slack', 'System Notification'], doc.channel))",
             "eval:doc.channel == 'FCM' || (in_list(['Email', 'Slack', 'System Notification'], doc.channel))"),
            ('eval:doc.channel == \'FCM\' or doc.get("email_template")',
             'eval:doc.channel == \'FCM\' || doc["email_template"]'),
            ('eval:doc.channel == \'FCM\' || doc.get("email_template")',
             'eval:doc.channel == \'FCM\' || doc["email_template"]'),
            ('email_template', 'eval:doc.channel == \'FCM\' || doc["email_template"]'),
            ("eval:doc.channel == 'FCM' || (doc.channel == 'Email')",
             "eval:doc.channel == 'FCM' || (doc.channel == 'Email')"),
            ("eval:doc.channel == 'FCM'", "eval:doc.channel == 'FCM'"),
        ]
        for previous, expected in cases:
            with self.subTest(previous=previous):
                fields = {
                    "channel": Row(options="Email\nFCM"),
                    "subject": Row(depends_on=previous, mandatory_depends_on=previous),
                    "message": Row(depends_on=previous),
                }
                setter = Mock(side_effect=lambda dt, field, prop, value, kind:
                    fields[field].update({prop: value}))
                self.frappe.only_for = Mock()
                self.frappe.get_meta = Mock(return_value=SimpleNamespace(get_field=fields.get))
                self.frappe.clear_cache = Mock()
                with patch.dict("sys.modules", {
                    "frappe.custom.doctype.property_setter.property_setter": SimpleNamespace(make_property_setter=setter),
                }):
                    self.module.setup_fcm_notification_channel()
                    self.assertEqual(fields["subject"]["depends_on"], expected)
                    self.assertEqual(fields["subject"]["mandatory_depends_on"], expected)
                    self.assertEqual(fields["message"]["depends_on"], expected)
                    count = setter.call_count
                    self.module.setup_fcm_notification_channel()
                    self.assertEqual(setter.call_count, count)

    def test_channel_setup_keeps_empty_visibility_and_requires_subject_for_fcm(self):
        fields = {"channel": Row(options="Email\nFCM"), "subject": Row(), "message": Row()}
        setter = Mock(side_effect=lambda dt, field, prop, value, kind: fields[field].update({prop: value}))
        self.frappe.only_for = Mock()
        self.frappe.get_meta = Mock(return_value=SimpleNamespace(get_field=fields.get))
        self.frappe.clear_cache = Mock()
        with patch.dict("sys.modules", {
            "frappe.custom.doctype.property_setter.property_setter": SimpleNamespace(make_property_setter=setter),
        }):
            self.module.setup_fcm_notification_channel()
        setter.assert_called_once_with("Notification", "subject", "mandatory_depends_on",
            "eval:doc.channel == 'FCM'", "Code")

    def test_worker_and_real_script_resolve_recipients_without_http_request(self):
        self.frappe.flags = Flags()
        self.frappe.utils = SimpleNamespace(strip_html=lambda text: text)
        self.frappe.render_template = Mock(side_effect=lambda text, context, **kwargs: text)
        self.frappe.call = Mock(side_effect=AssertionError("HTTP dispatch must not be used in workers"))
        script_doc = Row(name="Generic FCM", script=SCRIPT)
        self.frappe.get_doc.side_effect = lambda dt, name: {
            "Notification": self.rule, "Lead": self.document, "Server Script": script_doc}[dt]
        self.frappe.db.get_value.side_effect = lambda dt, *a, **kw: (
            "Generic FCM" if dt == "Server Script" else 1)
        self.frappe.get_all.side_effect = lambda dt, **kw: (
            [Row(name=self.recipient)] if dt == "User" else [{"fcm_token": "fake-local-token"}])

        def safe_exec(source, _locals, script_filename=None):
            self.assertEqual(script_filename, "Generic FCM")
            scope = {"frappe": self.frappe, **_locals}
            exec(compile(source, "mobile_fcm_notification.py", "exec"), scope)
            return scope, _locals

        with patch.dict("sys.modules", {
            "frappe.email.doctype.notification.notification": SimpleNamespace(
                get_context=lambda doc: {"doc": doc}, get_comments_for_context=lambda doc: []),
            "frappe.utils.safe_exec": SimpleNamespace(safe_exec=safe_exec),
        }):
            result = self.module.dispatch_document_notification("New Lead", "Lead", "LEAD-1", "version-1")
        self.assertEqual(result, {"status": "processed", "sent": 1, "failed": 0, "skipped": 1})
        self.assertIsNone(self.module._NOTIFICATION_DISPATCH.get())
        self.frappe.call.assert_not_called()
        self.assertEqual(self.messaging.send.call_count, 1)
        templates = [call.args[0] for call in self.frappe.render_template.call_args_list]
        self.assertEqual(templates, ["New lead", "Please contact the customer"])


if __name__ == "__main__":
    unittest.main()
