"""v15/v16 controller and callable-signature compatibility; local stubs only."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from test import generic_fcm_notification_test as generic


ROOT = Path(__file__).resolve().parents[1] / "backend_patches/automategenie_fcm"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class NotificationVersionCompatibilityTest(unittest.TestCase):
    get_value = generic.legacy.AutomateGenieFcmSenderTest.get_value

    def setUp(self):
        generic.GenericFcmNotificationTest.setUp(self)
        self.hooks = load("fcm_test_hooks", ROOT / "notification_hooks.py")

    def test_both_versions_use_the_same_override_without_version_selection(self):
        for version in ["15.70.1", "16.1.0"]:
            with self.subTest(version=version):
                self.frappe.__version__ = version
                hooks = {"override_doctype_class": {"Notification": "other.CustomNotification", "Task": "other.Task"}}
                self.hooks.configure_notification_hooks(hooks)
                self.hooks.configure_notification_hooks(hooks)
                self.assertEqual(hooks["override_doctype_class"]["Notification"], [
                    "other.CustomNotification", "itgenie.fcm.notification_hooks.FCMNotification"])
                self.assertEqual(hooks["override_doctype_class"]["Task"], "other.Task")
                self.assertNotIn("extend_doctype_class", hooks)

    def test_migration_removes_only_previous_fcm_extension_and_override(self):
        hooks = {
            "extend_doctype_class": {"Notification": ["other.Mixin", "itgenie.fcm.fcm_utils.FCMNotificationMixin"], "Task": ["other.TaskMixin"]},
            "override_doctype_class": {"Notification": ["other.Base", "itgenie.fcm.notification_v15.FCMNotification"]},
        }
        self.hooks.configure_notification_hooks(hooks)
        self.assertEqual(hooks["extend_doctype_class"], {"Notification": ["other.Mixin"], "Task": ["other.TaskMixin"]})
        self.assertEqual(hooks["override_doctype_class"]["Notification"], [
            "other.Base", "itgenie.fcm.notification_hooks.FCMNotification"])

    def test_migration_removes_empty_fcm_extension_entry(self):
        hooks = {"extend_doctype_class": {"Notification": ["itgenie.fcm.fcm_utils.FCMNotificationMixin"]}}
        self.hooks.configure_notification_hooks(hooks)
        self.assertNotIn("Notification", hooks["extend_doctype_class"])
        self.assertEqual(hooks["override_doctype_class"]["Notification"], ["itgenie.fcm.notification_hooks.FCMNotification"])

    def override_controller(self, other=False):
        class Core(generic.Row):
            def send_notification_by_channel(self, doc, context):
                return "core-channel"

        class Existing(Core):
            def send_notification_by_channel(self, doc, context):
                return "previous-custom-channel"

        self.frappe.get_hooks = Mock(return_value={"Notification": (
            ["other.Notification", "itgenie.fcm.notification_hooks.FCMNotification"] if other else
            ["itgenie.fcm.notification_hooks.FCMNotification"])})
        self.frappe.get_attr = Mock(return_value=Existing)
        with patch.dict("sys.modules", {
            "frappe": self.frappe,
            "frappe.email.doctype.notification.notification": SimpleNamespace(Notification=Core),
            "itgenie.fcm.fcm_utils": self.module,
        }):
            module = load("itgenie.fcm.notification_hooks", ROOT / "notification_hooks.py")
            controller = module.FCMNotification
            self.assertIs(controller, module.FCMNotification)
        return controller

    def test_override_controller_keeps_core_channels_and_adds_fcm(self):
        controller = self.override_controller()
        rule = controller(self.rule)
        rule["channel"] = "Email"
        self.assertEqual(rule.send_notification_by_channel(self.document, {}), "core-channel")
        self.frappe.enqueue.assert_not_called()
        rule["channel"] = "FCM"
        rule.send_notification_by_channel(self.document, {})
        self.assertTrue(self.frappe.enqueue.call_args.kwargs["enqueue_after_commit"])

    def test_override_retains_other_apps_custom_notification_handler(self):
        controller = self.override_controller(other=True)
        rule = controller(self.rule)
        rule["channel"] = "SMS"
        self.assertEqual(rule.send_notification_by_channel(self.document, {}), "previous-custom-channel")
        self.frappe.enqueue.assert_not_called()

    def test_v15_69_send_queues_fcm_and_preserves_native_bell_and_post_alert(self):
        native_calls = []

        # This base deliberately has NO send_notification_by_channel method.
        class LegacyNotification(generic.Row):
            def send(self, doc):
                native_calls.append(self.get("channel"))
                if self.get("send_system_notification"):
                    self.create_system_notification(doc, {"doc": doc})
                self.property_after_alert = "preserved"
                return "legacy-send"

        class Notification(self.module.FCMNotificationMixin, LegacyNotification):
            pass

        rule = Notification(self.rule)
        rule["send_system_notification"] = 1
        rule.create_system_notification = Mock()
        self.assertEqual(rule.send(self.document), "legacy-send")
        self.frappe.enqueue.assert_called_once()
        self.assertTrue(self.frappe.enqueue.call_args.kwargs["enqueue_after_commit"])
        rule.create_system_notification.assert_called_once()
        self.assertEqual(rule.property_after_alert, "preserved")
        self.assertEqual(native_calls, ["FCM"])

        for channel in ["Email", "SMS", "Slack", "System Notification"]:
            self.frappe.enqueue.reset_mock()
            rule["channel"] = channel
            self.assertEqual(rule.send(self.document), "legacy-send")
            self.frappe.enqueue.assert_not_called()

    def test_v15_69_disabled_and_custom_fcm_do_not_queue_or_send(self):
        native_send = Mock()

        class LegacyNotification(generic.Row):
            send = native_send

        class Notification(self.module.FCMNotificationMixin, LegacyNotification):
            pass

        for changes in [{"enabled": 0}, {"event": "Custom"}]:
            Notification({**self.rule, **changes}).send(self.document)
        native_send.assert_not_called()
        self.frappe.enqueue.assert_not_called()

    def test_modern_send_reaches_channel_handler_and_queues_only_once(self):
        class ModernNotification(generic.Row):
            def send(self, doc):
                self.send_notification_by_channel(doc, {"doc": doc})
                return "modern-send"

            def send_notification_by_channel(self, doc, context):
                return "native-channel"

        class Notification(self.module.FCMNotificationMixin, ModernNotification):
            pass

        rule = Notification(self.rule)
        rule["send_system_notification"] = 1
        rule.create_system_notification = Mock()
        self.assertEqual(rule.send(self.document), "modern-send")
        self.frappe.enqueue.assert_called_once()
        rule.create_system_notification.assert_called_once()
        self.frappe.enqueue.reset_mock()
        rule["channel"] = "Email"
        self.assertEqual(rule.send(self.document), "modern-send")
        self.frappe.enqueue.assert_not_called()

    def test_context_falls_back_to_v15_comments_and_keeps_standard_properties(self):
        self.document["_comments"] = '[{"comment": "Follow up"}]'
        self.rule["is_standard"] = 1
        self.rule.load_standard_properties = Mock(
            side_effect=lambda context: context.update({"standard_value": "kept"}))
        with patch.dict("sys.modules", {
            "frappe.email.doctype.notification.notification": SimpleNamespace(
                get_context=lambda doc: {"existing": "kept"}),
        }):
            context = self.module._notification_context(self.rule, self.document)
            self.assertEqual(context["comments"], [{"comment": "Follow up"}])
            self.assertEqual(context["existing"], "kept")
            self.assertEqual(context["standard_value"], "kept")
            self.assertIs(context["doc"], self.document)
            self.assertIs(context["alert"], self.rule)
            self.document.pop("_comments")
            self.assertIsNone(self.module._notification_context(self.rule, self.document)["comments"])

    def test_modern_context_uses_native_comments_helper(self):
        helper = Mock(return_value=[{"comment": "Native helper"}])
        self.document["_comments"] = "unused-invalid-json"
        with patch.dict("sys.modules", {
            "frappe.email.doctype.notification.notification": SimpleNamespace(
                get_context=lambda doc: {"doc": doc}, get_comments_for_context=helper),
        }):
            context = self.module._notification_context(self.rule, self.document)
        self.assertEqual(context["comments"], [{"comment": "Native helper"}])
        helper.assert_called_once_with(self.document)

    def test_template_renderer_supports_older_and_newer_signatures(self):
        calls = []

        def old_renderer(template, context):
            calls.append((template, context))
            return "old-sandbox"

        def new_renderer(template, context, restrict_globals=False):
            calls.append(restrict_globals)
            return "restricted-sandbox"

        self.frappe.render_template = old_renderer
        self.assertEqual(self.module.render_notification_template("Subject", {}), "old-sandbox")
        self.frappe.render_template = new_renderer
        self.assertEqual(self.module.render_notification_template("Subject", {}), "restricted-sandbox")
        self.assertTrue(calls[-1])

    def test_render_errors_are_not_retried_with_weaker_arguments(self):
        calls = []

        def renderer(template, context, restrict_globals=False):
            calls.append(restrict_globals)
            raise TypeError("Actual template problem")

        self.frappe.render_template = renderer
        with self.assertRaisesRegex(TypeError, "Actual template"):
            self.module.render_notification_template("Subject", {})
        self.assertEqual(calls, [True])

    def test_worker_supports_safe_exec_without_script_filename(self):
        self.frappe.flags = generic.Flags()
        self.frappe.get_doc.side_effect = lambda dt, name: {
            "Notification": self.rule, "Lead": self.document,
            "Server Script": generic.Row(name="FCM script", script="bridge-script"),
        }[dt]
        self.frappe.db.get_value.return_value = "FCM script"
        self.frappe.db.get_value.side_effect = None
        called = []

        def old_safe_exec(source, _locals):
            called.append(source)
            self.assertTrue(callable(_locals["fcm_trigger"]["render_template"]))
            self.frappe.flags.fcm_notification_result = {"status": "processed"}
            return {"frappe": self.frappe}, _locals

        with patch.dict("sys.modules", {
            "frappe.email.doctype.notification.notification": SimpleNamespace(
                get_context=lambda doc: {"doc": doc}, get_comments_for_context=lambda doc: []),
            "frappe.utils.safe_exec": SimpleNamespace(safe_exec=old_safe_exec),
        }):
            result = self.module.dispatch_document_notification("New Lead", "Lead", "LEAD-1")
        self.assertEqual(result, {"status": "processed"})
        self.assertEqual(called, ["bridge-script"])
        self.assertIsNone(self.module._NOTIFICATION_DISPATCH.get())

    def test_v15_69_worker_runs_real_recipient_script_without_missing_helpers(self):
        self.frappe.flags = generic.Flags()
        self.frappe.utils = SimpleNamespace(strip_html=lambda text: text)
        self.frappe.render_template = lambda text, context: text
        self.frappe.get_doc.side_effect = lambda dt, name: {
            "Notification": self.rule, "Lead": self.document,
            "Server Script": generic.Row(name="Generic FCM", script=generic.SCRIPT),
        }[dt]
        self.frappe.db.get_value.side_effect = lambda dt, *a, **kw: (
            "Generic FCM" if dt == "Server Script" else 1)
        self.frappe.get_all.side_effect = lambda dt, **kw: (
            [generic.Row(name=self.recipient)] if dt == "User"
            else [{"fcm_token": "fake-local-token"}])

        def legacy_safe_exec(source, _locals):
            scope = {"frappe": self.frappe, **_locals}
            exec(compile(source, "mobile_fcm_notification.py", "exec"), scope)
            return scope, _locals

        with patch.dict("sys.modules", {
            "frappe.email.doctype.notification.notification": SimpleNamespace(
                get_context=lambda doc: {"doc": doc}),
            "frappe.utils.safe_exec": SimpleNamespace(safe_exec=legacy_safe_exec),
        }):
            result = self.module.dispatch_document_notification(
                "New Lead", "Lead", "LEAD-1", "legacy-version")
        self.assertEqual(result, {"status": "processed", "sent": 1, "failed": 0, "skipped": 1})
        self.messaging.send.assert_called_once()
        self.assertIsNone(self.module._NOTIFICATION_DISPATCH.get())

    def test_console_validation_detects_masked_controller(self):
        class Other:
            pass

        with patch.dict("sys.modules", {
            "frappe.model.base_document": SimpleNamespace(get_controller=lambda dt: Other),
        }):
            with self.assertRaisesRegex(ValueError, "not active"):
                self.module.validate_fcm_notification_installation()


if __name__ == "__main__":
    unittest.main()
