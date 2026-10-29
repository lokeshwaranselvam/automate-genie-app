"""Attendance retries are serialized and checkout requires an open check-in."""
import ast
from datetime import datetime
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
FILES = ("api_utils.py", "api_single_device_updated.py", "attendance_api.py")


class Row(dict):
    __getattr__ = dict.get
    __setattr__ = dict.__setitem__


class AttendanceRetryGuardTest(unittest.TestCase):
    def load(self, filename, lock_result=1, in_logs=None):
        self.saved = []
        self.sql = []
        now = datetime(2026, 10, 13, 12)
        in_logs = [Row(name="IN-1", time=now, custom_office_type="Office")] if in_logs is None else in_logs

        def sql(query, *args, **kwargs):
            self.sql.append(query.strip())
            if "GET_LOCK" in query:
                return [(lock_result,)]
            if "RELEASE_LOCK" in query:
                return [(1,)]
            return [Row(event_id="Employee Checked In", creation=now, latitude=13.0, longitude=80.0,
                        source="Office", destination=None, destination_lat=None, destination_lng=None)]

        def new_doc(doctype):
            doc = Row(doctype=doctype, name=doctype + "-1")
            doc.save = Mock(side_effect=lambda **kwargs: self.saved.append(doc))
            return doc

        self.frappe = SimpleNamespace(
            session=SimpleNamespace(user="staff@example.test"), local=SimpleNamespace(site="site.test", response={}),
            db=SimpleNamespace(get_value=Mock(return_value="EMP-1"), exists=Mock(return_value=False),
                               sql=Mock(side_effect=sql), commit=Mock(), rollback=Mock()),
            form_dict=Row(), new_doc=new_doc, utils=SimpleNamespace(nowdate=lambda: "2026-10-13"),
            get_all=Mock(side_effect=lambda doctype, **kwargs: in_logs if kwargs["filters"]["log_type"] == "IN" else []),
            throw=Mock(side_effect=lambda message, *a: (_ for _ in ()).throw(ValueError(message))),
            log_error=Mock(), get_traceback=lambda: "trace", PermissionError=PermissionError,
        )
        tree = ast.parse((ROOT / "backend_patches" / filename).read_text(encoding="utf-8"))
        nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in ("checkin", "checkout", "_ensure_own_user")]
        for node in nodes:
            node.decorator_list = []
        namespace = dict(frappe=self.frappe, json=json, requests=SimpleNamespace(),
                         now_datetime=lambda: now, nowdate=lambda: "2026-10-13",
                         getdate=lambda value: datetime.fromisoformat(str(value)).date())
        exec(compile(ast.Module(body=nodes, type_ignores=[]), filename, "exec"), namespace)
        return namespace

    def test_lock_is_taken_before_checks_and_always_released(self):
        for filename in FILES:
            for name in ("checkin", "checkout"):
                with self.subTest(filename=filename, name=name):
                    api = self.load(filename)
                    api[name]("staff@example.test", "13.2", "80.2", address="Home")
                    self.assertIn("Successfully", self.frappe.local.response["message"])
                    self.assertTrue(self.sql[0].startswith("SELECT GET_LOCK"))
                    self.assertTrue(self.sql[-1].startswith("SELECT RELEASE_LOCK"))
                    self.frappe.db.commit.assert_called()

    def test_busy_lock_rejects_retry_without_writes(self):
        for filename in FILES:
            for name in ("checkin", "checkout"):
                with self.subTest(filename=filename, name=name):
                    api = self.load(filename, lock_result=0)
                    api[name]("staff@example.test", "13.2", "80.2", address="Home")
                    self.assertEqual(self.frappe.local.response["http_status_code"], 409)
                    self.assertEqual(self.saved, [])
                    self.assertFalse(any("RELEASE_LOCK" in q for q in self.sql))

    def test_checkout_without_any_check_in_is_rejected(self):
        for filename in FILES:
            with self.subTest(filename=filename):
                api = self.load(filename, in_logs=[])
                api["checkout"]("staff@example.test", "13.2", "80.2", address="Home")
                self.assertEqual(self.frappe.local.response["message"], "No check-in found to check out from.")
                self.assertEqual(self.frappe.local.response["http_status_code"], 400)
                self.assertEqual(self.saved, [])
                self.assertTrue(self.sql[-1].startswith("SELECT RELEASE_LOCK"))


if __name__ == "__main__":
    unittest.main()
