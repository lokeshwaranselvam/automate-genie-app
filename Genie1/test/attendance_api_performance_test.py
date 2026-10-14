"""Exercise the replacement app API without connecting to an ERP site."""
import ast
from datetime import datetime
import inspect
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock


class Row(dict):
    __getattr__ = dict.get
    __setattr__ = dict.__setitem__


class AttendanceApiPerformanceTest(unittest.TestCase):
    def setUp(self):
        self.saved = []
        self.now = datetime(2026, 10, 13, 12)
        self.previous = Row(
            event_id="EVENT-1", creation=self.now, latitude=13.0,
            longitude=80.0, destination_lat=13.1, destination_lng=80.1,
            source="Office", destination="Site",
        )
        self.db = SimpleNamespace(
            get_value=Mock(return_value="EMP-1"), exists=Mock(return_value=False),
            sql=Mock(side_effect=lambda *args, **kwargs: [self.previous]),
            commit=Mock(), rollback=Mock(),
        )

        def new_doc(doctype):
            doc = Row(doctype=doctype, name=doctype + "-1")
            doc.save = Mock(side_effect=lambda **kwargs: self.saved.append(doc))
            return doc

        self.frappe = SimpleNamespace(
            db=self.db, form_dict=Row(include_timings="1"),
            local=SimpleNamespace(response={}), new_doc=new_doc,
            get_all=Mock(side_effect=lambda doctype, **kwargs: (
                [Row(name="IN-1", time=self.now, custom_office_type="Office")]
                if kwargs["filters"]["log_type"] == "IN" else []
            )),
            utils=SimpleNamespace(nowdate=lambda: "2026-10-13"),
            throw=Mock(side_effect=lambda message: (_ for _ in ()).throw(ValueError(message))),
            log_error=Mock(), get_traceback=lambda: "trace",
        )
        self.requests = SimpleNamespace(
            request=Mock(return_value=SimpleNamespace(text=json.dumps({
                "status": "OK", "rows": [{"elements": [{
                    "status": "OK", "distance": {"text": "5 km"},
                }]}],
            }))),
            exceptions=SimpleNamespace(Timeout=TimeoutError),
        )
        source = (Path(__file__).resolve().parents[1] / "backend_patches/api.py").read_text()
        tree = ast.parse(source)
        tree.body = [node for node in tree.body if isinstance(node, ast.FunctionDef)]
        for node in tree.body:
            node.decorator_list = []
        self.namespace = dict(
            frappe=self.frappe, requests=self.requests, json=json,
            now_datetime=lambda: self.now, nowdate=lambda: "2026-10-13",
            getdate=lambda value: datetime.fromisoformat(str(value)).date(),
        )
        exec(compile(tree, "attendance_api.py", "exec"), self.namespace)

    def checkout(self, **kwargs):
        self.namespace["checkout"](
            user="staff@example.test", lat=13.2, lng=80.2, address="Home",
            photo_url="/private/files/selfie.jpg", face_verification="receipt-1",
            include_timings="1", **kwargs,
        )
        return self.frappe.local.response

    def test_whitelisted_functions_accept_app_face_fields(self):
        for name in ("checkin", "checkout"):
            arguments = inspect.signature(self.namespace[name]).parameters
            for field in ("photo_url", "face_verification", "include_timings"):
                self.assertIn(field, arguments)

    def test_checkin_keeps_both_document_saves_and_commit(self):
        self.namespace["checkin"](
            user="staff@example.test", lat=13.0, lng=80.0,
            address="Office", office_type="Office",
            photo_url="/private/files/selfie.jpg", face_verification="receipt-1",
        )
        self.assertEqual(self.frappe.local.response["message"], "Check-In Created Successfully")
        self.assertEqual([doc.doctype for doc in self.saved], ["Employee Checkin", "Visit"])
        self.assertEqual(self.saved[1].custom_employee_checkin, self.saved[0].name)
        self.db.commit.assert_called_once()
        self.db.rollback.assert_not_called()

    def test_duplicate_checkin_keeps_original_response_without_saves(self):
        self.db.exists.return_value = True
        self.namespace["checkin"](user="staff@example.test", lat=13.0, lng=80.0)
        self.assertEqual(self.frappe.local.response["message"], "Employee already checked in today!")
        self.assertEqual(self.saved, [])
        self.db.commit.assert_not_called()

    def test_checkin_reports_stages_and_failure_total(self):
        self.namespace["checkin"](user="staff@example.test", lat=13, lng=80)
        timings = self.frappe.local.response["attendance_timings_ms"]
        self.assertEqual(set(timings), {
            "checkin_employee_lookup", "checkin_existing_in", "checkin_checkin_save",
            "checkin_visit_save", "checkin_commit", "checkin_total",
        })
        self.assertTrue(all(value >= 0 for value in timings.values()))
        self.frappe.local.response = {}
        self.db.get_value.side_effect = ValueError("Database unavailable")
        self.namespace["checkin"](user="staff@example.test", lat=13, lng=80)
        self.assertEqual(self.frappe.local.response["http_status_code"], 500)
        self.assertIn("checkin_total", self.frappe.local.response["attendance_timings_ms"])
        self.db.rollback.assert_called_once()

    def test_checkin_timings_are_opt_in(self):
        self.frappe.form_dict.clear()
        self.namespace["checkin"](user="staff@example.test", lat=13, lng=80)
        self.assertNotIn("attendance_timings_ms", self.frappe.local.response)

    def test_generator_can_read_already_patched_module(self):
        import sys
        from unittest.mock import patch
        directory = Path(__file__).resolve().parents[1] / "backend_patches"
        with patch.object(sys, "path", [str(directory), *sys.path]):
            from prepare_attendance_api import build_replacements
            source = (directory / "api.py").read_text()
            generated = build_replacements(source)
            self.assertEqual(build_replacements(generated), generated)

    def test_duplicate_route_uses_one_bounded_request_and_normal_saves(self):
        response = self.checkout(with_event="true")
        self.assertEqual(response["message"], "Check-Out Created Successfully")
        self.requests.request.assert_called_once()
        self.assertEqual(self.requests.request.call_args.kwargs["timeout"], (3.05, 10))
        self.assertEqual([doc.doctype for doc in self.saved], ["Employee Checkin", "Visit"])
        self.assertEqual(self.saved[1].custom_distance, "5 km")
        self.assertEqual(self.saved[0].custom_office_type, "Office")
        self.db.get_value.assert_called_once()  # No second office-type read.
        self.db.commit.assert_called_once()
        self.db.rollback.assert_not_called()
        self.assertIn("checkout_commit", response["attendance_timings_ms"])

    def test_no_event_skips_distance_lookup(self):
        self.previous.event_id = "Employee Checked In"
        response = self.checkout(with_event="false")
        self.assertEqual(response["http_status_code"], 200)
        self.requests.request.assert_not_called()

    def test_maps_timeout_rolls_back_without_success(self):
        self.requests.request.side_effect = TimeoutError()
        response = self.checkout(with_event="true")
        self.assertEqual(response["http_status_code"], 500)
        self.assertIn("timed out", response["message"])
        self.db.rollback.assert_called_once()
        self.db.commit.assert_not_called()

    def test_failed_checkin_hook_prevents_visit_and_commit(self):
        def rejected_doc(doctype):
            return Row(save=Mock(side_effect=ValueError("Receipt expired")))
        self.frappe.new_doc = rejected_doc
        response = self.checkout()
        self.assertEqual(response["http_status_code"], 500)
        self.requests.request.assert_not_called()
        self.db.rollback.assert_called_once()
        self.db.commit.assert_not_called()

    def test_active_event_still_blocks_checkout(self):
        self.db.exists.return_value = True
        response = self.checkout()
        self.assertEqual(response["http_status_code"], 403)
        self.assertEqual(self.saved, [])
        self.requests.request.assert_not_called()


if __name__ == "__main__":
    unittest.main()
