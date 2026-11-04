"""Focused local mocks; no ERP deployment, database writes or Firebase delivery."""
import ast
import importlib.util
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch
import unittest

ROOT = Path(__file__).resolve().parents[1]
API = (ROOT / "frappe_server_scripts/mobile_sales_summary.py").read_text()
SCHEDULER = (ROOT / "frappe_server_scripts/sales_summary_daily_scheduler.py").read_text()


class Row(dict):
    __getattr__ = dict.get
    __setattr__ = dict.__setitem__


def throw(message, error=ValueError):
    raise error(message)


class SalesSummaryApiTest(unittest.TestCase):
    def setUp(self):
        self.roles = ["Sales User"]
        self.frappe = SimpleNamespace(
            session=Row(user="user@example.test"), PermissionError=PermissionError,
            response={}, form_dict={}, throw=throw,
            db=SimpleNamespace(get_value=Mock(return_value=1)),
            get_all=Mock(side_effect=lambda *args, **kwargs: self.roles),
            get_meta=Mock(return_value=SimpleNamespace(has_field=lambda field: True,
                get_field=lambda field: Row(options="Open\nProspect\nPipeline"))),
            get_list=Mock(return_value=[Row(status="Prospect", total=3), Row(status="Pipeline", total=2)]),
            utils=SimpleNamespace(cint=int, now=lambda: "2026-11-02 13:00:00"),
        )

    def run_api(self):
        exec(compile(API, "mobile_sales_summary", "exec"), {"frappe": self.frappe})
        return self.frappe.response["message"]

    def test_enabled_users_are_not_restricted_to_the_fcm_roles(self):
        for roles in [["Sales Manager"], ["Sales User"], ["Designer"], ["Employee"], []]:
            self.roles = roles
            result = self.run_api()
            self.assertEqual(result["user"], "user@example.test")
            self.assertEqual((result["prospect_count"], result["pipeline_count"], result["total_count"]), (3, 2, 5))
            args, kwargs = self.frappe.get_list.call_args
            self.assertEqual(args, ("Opportunity",))
            self.assertNotIn("opportunity_owner", kwargs["filters"])
            self.assertEqual(kwargs["or_filters"], [
                ["opportunity_owner", "=", "user@example.test"],
                ["custom_field_owner_1", "=", "user@example.test"],
                ["custom_field_owner_2", "=", "user@example.test"],
            ])
            self.assertEqual(kwargs["filters"]["status"], ["in", ["Prospect", "Pipeline"]])
            self.assertEqual(kwargs["group_by"], "status")
            self.assertEqual(kwargs["limit_page_length"], 2)
            self.assertNotIn("ignore_permissions", kwargs)
        self.frappe.get_all.assert_not_called()

    def test_guest_and_disabled_users_are_rejected(self):
        for user, enabled in [("Guest", 1), ("user@example.test", 0)]:
            self.frappe.session.user = user
            self.frappe.db.get_value.return_value = enabled
            with self.assertRaises(PermissionError): self.run_api()
        self.frappe.get_list.assert_not_called()

    def test_user_parameter_cannot_select_another_account(self):
        for key in ["user", "owner", "opportunity_owner", "custom_field_owner_1", "custom_field_owner_2", "for_user"]:
            self.frappe.form_dict = {key: "someone-else@example.test"}
            with self.assertRaises(PermissionError): self.run_api()
        self.frappe.get_list.assert_not_called()

    def test_each_owner_field_matches_without_double_counting_or_broadening_status(self):
        user = self.frappe.session.user
        rows = [
            Row(status="Prospect", opportunity_owner=user),
            Row(status="Prospect", custom_field_owner_1=user),
            Row(status="Pipeline", custom_field_owner_2=user),
            Row(status="Pipeline", opportunity_owner=user, custom_field_owner_1=user, custom_field_owner_2=user),
            Row(status="Prospect", opportunity_owner="other@example.test"),
            Row(status="Closed", custom_field_owner_1=user),
            Row(status="Pipeline", custom_field_owner_2=user, docstatus=2),
            Row(status="Prospect", custom_field_owner_1=user, permitted=False),
        ]
        def permission_filtered_query(doctype, **kwargs):
            counts = {}
            for row in rows:
                if row.get("permitted") is False or row.get("docstatus", 0) == 2:
                    continue
                if row.status not in kwargs["filters"]["status"][1]:
                    continue
                if not any(row.get(field) == value for field, operator, value in kwargs["or_filters"]):
                    continue
                counts[row.status] = counts.get(row.status, 0) + 1
            return [Row(status=status, total=total) for status, total in counts.items()]
        self.frappe.get_list.side_effect = permission_filtered_query
        result = self.run_api()
        self.assertEqual(result["prospect_count"], 2)
        self.assertEqual(result["pipeline_count"], 2)
        self.assertEqual(result["total_count"], 4)

    def test_empty_and_missing_groups_are_zero(self):
        self.frappe.get_list.return_value = []
        self.assertEqual(self.run_api()["total_count"], 0)
        self.frappe.get_list.return_value = [Row(status="Pipeline", total="4")]
        result = self.run_api()
        self.assertEqual(result["prospect_count"], 0)
        self.assertEqual(result["pipeline_count"], 4)

    def test_missing_schema_and_permission_failure_fail_closed(self):
        self.frappe.get_meta.return_value = SimpleNamespace(has_field=lambda field: False)
        with self.assertRaises(ValueError): self.run_api()
        self.setUp()
        self.frappe.get_meta.return_value.get_field = lambda field: Row(options="Open\nProspect")
        with self.assertRaises(ValueError): self.run_api()
        self.setUp()
        self.frappe.get_list.side_effect = PermissionError("No document access")
        with self.assertRaises(PermissionError): self.run_api()

    def test_restricted_scripts_have_no_imports_functions_or_permission_bypass(self):
        for source in [API, SCHEDULER]:
            tree = ast.parse(source)
            self.assertFalse(any(isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.AsyncFunctionDef)) for node in ast.walk(tree)))
            self.assertNotIn("ignore_permissions", source)
        enqueue = Mock()
        frappe = SimpleNamespace(session=Row(user="Administrator"), enqueue=enqueue)
        exec(SCHEDULER, {"frappe": frappe})
        self.assertEqual(enqueue.call_args.args, ("itgenie.fcm.fcm_utils.send_daily_sales_summary",))
        self.assertTrue(enqueue.call_args.kwargs["enqueue_after_commit"])


class SalesSummarySenderTest(unittest.TestCase):
    def setUp(self):
        self.user = "user@example.test"
        self.logs = {}
        self.accepted = set()
        self.enabled = True
        self.has_role = True
        self.token = "private-test-token"
        self.commits = 0
        self.frappe = SimpleNamespace(
            session=Row(user="Administrator"), local=Row(site="erp.example.test"),
            PermissionError=PermissionError, throw=throw, whitelist=lambda **kwargs: lambda fn: fn,
            utils=SimpleNamespace(today=lambda: "2026-11-02"),
            cache=lambda: SimpleNamespace(lock=lambda *args, **kwargs: nullcontext()),
            db=SimpleNamespace(get_value=lambda *args: int(self.enabled), exists=self.exists,
                commit=self.commit, get_single_value=lambda *args: "Asia/Kolkata"),
            get_doc=self.get_doc, get_all=Mock(side_effect=self.get_all), enqueue=Mock(), log_error=Mock(),
        )
        self.messaging = SimpleNamespace(send=Mock(return_value="provider-id"), Message=lambda **kwargs: Row(kwargs), AndroidConfig=lambda **kwargs: kwargs)
        spec = importlib.util.spec_from_file_location("itgenie.fcm.fcm_utils", ROOT / "backend_patches/automategenie_fcm/fcm_utils.py")
        self.module = importlib.util.module_from_spec(spec)
        with patch.dict("sys.modules", {
            "frappe": self.frappe, "firebase_admin": SimpleNamespace(credentials=SimpleNamespace(), messaging=self.messaging),
        }): spec.loader.exec_module(self.module)
        self.module.get_firebase_app = lambda: "shared-firebase-app"

    def commit(self): self.commits += 1

    def exists(self, doctype, value):
        if doctype == "Has Role": return self.has_role
        if doctype == "Notification Log": return value in self.logs
        if doctype == "Comment": return value["reference_name"] in self.accepted
        raise AssertionError(doctype)

    def get_doc(self, value, name=None):
        if isinstance(value, str): return self.logs[name]
        log = Row(value)
        def insert(ignore_permissions, set_name):
            self.assertTrue(ignore_permissions)
            log.name = set_name
            self.logs[set_name] = log
            return log
        def comment(kind, text):
            self.assertEqual(kind, "Info")
            self.assertEqual(text, self.module._SALES_SUMMARY_ACCEPTED_COMMENT)
            self.accepted.add(log.name)
        log.insert = insert
        log.add_comment = comment
        return log

    def get_all(self, doctype, **kwargs):
        if doctype == "FCM Device": return [{"fcm_token": self.token}] if self.token else []
        if doctype == "Has Role":
            self.assertEqual(kwargs["group_by"], "parent")
            return [Row(parent=self.user), Row(parent="Administrator")]
        if doctype == "User": return [self.user, "Administrator"]
        raise AssertionError(doctype)

    def send(self, day="2026-11-02"):
        return self.module.deliver_sales_summary_reminder(self.user, day)

    def test_scheduler_groups_roles_and_excludes_administrator(self):
        self.module.send_fcm_to_user = Mock(side_effect=AssertionError("Document sender must not run"))
        self.module.dispatch_document_notification = Mock(side_effect=AssertionError("Document dispatch must not run"))
        result = self.module.send_daily_sales_summary()
        self.assertEqual(result["recipients"], 1)
        args = self.frappe.enqueue.call_args
        self.assertEqual(args.args, ("itgenie.fcm.fcm_utils.deliver_sales_summary_reminder",))
        self.assertEqual(args.kwargs["user"], self.user)
        self.assertEqual(args.kwargs["day"], "2026-11-02")
        self.assertTrue(args.kwargs["enqueue_after_commit"])
        self.module.send_fcm_to_user.assert_not_called()
        self.module.dispatch_document_notification.assert_not_called()

    def test_importing_combined_module_does_not_send_or_queue_anything(self):
        self.messaging.send.assert_not_called()
        self.frappe.enqueue.assert_not_called()
        self.assertFalse(self.logs)

    def test_non_admin_and_http_calls_cannot_broadcast(self):
        self.frappe.session.user = self.user
        with self.assertRaises(PermissionError): self.module.send_daily_sales_summary()
        self.frappe.session.user = "Administrator"
        self.frappe.local.request = Row(method="POST")
        with self.assertRaises(PermissionError): self.module.send_daily_sales_summary()
        self.messaging.send.assert_not_called()

    def test_wrong_timezone_is_rejected(self):
        self.frappe.db.get_single_value = lambda *args: "UTC"
        with self.assertRaises(ValueError): self.module.send_daily_sales_summary()

    def test_sends_only_once_with_one_durable_inbox_record_and_no_counts(self):
        result = self.send()
        self.assertEqual(result["status"], "sent")
        self.assertEqual(self.send()["status"], "already_sent")
        self.assertEqual(len(self.logs), 1)
        self.messaging.send.assert_called_once()
        payload = self.messaging.send.call_args.args[0].data
        self.assertEqual(payload["notification_log"], result["notification_log"])
        self.assertEqual(payload["doctype"], "Notification Log")
        self.assertEqual(payload["page_route"], "/genie-sales-summary")
        self.assertEqual(payload["for_user"], self.user)
        self.assertEqual(payload["alarm_enabled"], "0")
        self.assertTrue(all(isinstance(value, str) for value in payload.values()))
        self.assertNotIn("prospect_count", payload)
        self.assertGreaterEqual(self.commits, 2)

    def test_disabled_or_removed_role_and_stale_jobs_do_not_send(self):
        self.enabled = False
        self.assertEqual(self.send()["status"], "skipped")
        self.enabled = True
        self.has_role = False
        self.assertEqual(self.send()["status"], "skipped")
        self.has_role = True
        self.assertEqual(self.send("2026-11-01")["status"], "skipped")
        self.messaging.send.assert_not_called()
        self.assertFalse(self.logs)

    def test_missing_device_retains_inbox_and_can_retry_later(self):
        self.token = None
        self.assertEqual(self.send()["status"], "inbox_only")
        self.assertEqual(len(self.logs), 1)
        self.token = "private-test-token"
        self.assertEqual(self.send()["status"], "sent")
        self.assertEqual(len(self.logs), 1)

    def test_provider_failure_is_retryable_and_does_not_log_secrets(self):
        self.messaging.send.side_effect = RuntimeError("secret-token-or-provider-detail")
        self.assertEqual(self.send()["status"], "failed")
        self.assertNotIn("secret-token", str(self.frappe.log_error.call_args))
        self.assertFalse(self.accepted)
        self.messaging.send.side_effect = None
        self.assertEqual(self.send()["status"], "sent")
        self.assertEqual(len(self.logs), 1)


if __name__ == "__main__": unittest.main()
