"""Self-service attendance metadata in the existing restricted policy script."""
import unittest
from datetime import date, timedelta
from types import SimpleNamespace
from unittest.mock import Mock

from test.business_policy_stub import Row, install


class AttendanceShiftPolicyTest(unittest.TestCase):
    def setUp(self):
        self.employees = [Row(name="EMP-1", default_shift="General Shift")]
        self.requests = [Row(shift_type="Day Shift")]
        self.today_logs = []
        self.previous_logs = []
        self.office_mappings = []
        self.frappe = SimpleNamespace(
            session=Row(user="staff@example.test"), form_dict={}, flags=Row(),
            utils=SimpleNamespace(today=lambda: "2026-10-28",
                add_days=lambda value, days: str(date.fromisoformat(value) + timedelta(days=days))),
            get_all=Mock(side_effect=self.rows),
            throw=lambda msg: (_ for _ in ()).throw(ValueError(msg)),
        )
        self.call = install(self.frappe)

    def rows(self, doctype, **query):
        if doctype == "Employee Office Type Mapping":
            self.assertEqual(query["filters"], {
                "parent": "EMP-1", "parenttype": "Employee", "parentfield": "custom_office_type_mapping"})
            self.assertEqual(query["fields"], ["office_type"])
            self.assertEqual(query["order_by"], "idx asc")
            self.assertEqual(query["limit_page_length"], 100)
            return self.office_mappings
        if doctype == "Employee Checkin":
            self.assertEqual(query["filters"][0], ["employee", "=", "EMP-1"])
            self.assertEqual(query["fields"], ["log_type", "time"])
            if query["limit_page_length"] == 1000:
                self.assertEqual(query["filters"][1:], [
                    ["time", ">=", "2026-10-28 00:00:00"],
                    ["time", "<", "2026-10-29 00:00:00"]])
                return self.today_logs
            self.assertEqual(query["limit_page_length"], 1)
            return self.previous_logs
        if doctype == "Employee":
            self.assertEqual(query["filters"], {
                "user_id": "staff@example.test", "status": "Active"})
            self.assertEqual(query["fields"], ["name", "default_shift"])
            self.assertEqual(query["limit_page_length"], 2)
            return self.employees
        self.assertEqual(doctype, "Shift Request")
        self.assertEqual(query["filters"], {
            "employee": "EMP-1", "docstatus": 1, "status": "Approved",
            "from_date": ["<=", "2026-10-28"],
        })
        self.assertEqual(query["or_filters"], [
            ["to_date", ">=", "2026-10-28"], ["to_date", "is", "not set"]])
        self.assertEqual(query["order_by"], "from_date desc, modified desc, name desc")
        self.assertEqual(query["limit_page_length"], 1)
        self.assertEqual(query["fields"], ["shift_type"])
        return self.requests

    def read(self, **kwargs):
        return self.call("mobile_business_policy", feature="attendance", **kwargs)["policy"]["attendance"]

    def test_request_takes_priority_and_client_cannot_select_another_employee(self):
        result = self.read(user="other@example.test", employee="EMP-2")
        result.pop("status")
        self.assertEqual(result, {
            "shift": "Day Shift", "shift_source": "shift_request", "date": "2026-10-28",
            "checkin_location": ""})

    def test_no_applicable_request_uses_employee_default(self):
        self.requests = []
        self.assertEqual(self.read()["shift"], "General Shift")
        self.assertEqual(self.read()["shift_source"], "employee_default")

    def test_no_shift_returns_empty(self):
        self.requests = []
        self.employees[0].default_shift = None
        self.assertEqual(self.read()["shift"], "")

    def test_missing_or_ambiguous_employee_never_reads_requests(self):
        for employees in [[], self.employees * 2]:
            self.employees = employees
            self.frappe.get_all.reset_mock()
            self.assertEqual(self.read()["shift"], "")
            self.assertEqual(self.frappe.get_all.call_count, 1)

    def test_guest_rejected_before_employee_lookup(self):
        self.frappe.session.user = "Guest"
        with self.assertRaisesRegex(ValueError, "Sign in"):
            self.read()
        self.frappe.get_all.assert_not_called()

    def test_location_comes_from_employee_and_logs_from_checkin(self):
        self.office_mappings = [Row(office_type="Head Office")]
        self.assertEqual(self.read()["checkin_location"], "Head Office")
        self.assertEqual([call.args[0] for call in self.frappe.get_all.call_args_list],
                         ["Employee", "Shift Request", "Employee Office Type Mapping", "Employee Checkin", "Employee Checkin"])

    def test_empty_mapping_returns_empty_location(self):
        for mappings in [[], [Row(office_type=None)], [Row(office_type="")]]:
            self.office_mappings = mappings
            self.assertEqual(self.read()["checkin_location"], "")

    def test_multiselect_office_rows_display_unique_names(self):
        self.office_mappings = [Row(office_type="Head Office"), Row(office_type="Head Office"),
                                Row(office_type="Site"), Row(office_type=" ")]
        self.assertEqual(self.read()["checkin_location"], "Head Office, Site")

    def test_server_resolves_current_checkin_and_checkout_times(self):
        self.today_logs = [Row(log_type="IN", time="2026-10-28 09:00:00")]
        status = self.read()["status"]
        self.assertTrue(status["checked_in"])
        self.assertEqual(status["check_in_time"], "2026-10-28 09:00:00")
        self.today_logs.insert(0, Row(log_type="OUT", time="2026-10-28 18:00:00"))
        status = self.read()["status"]
        self.assertFalse(status["checked_in"])
        self.assertTrue(status["completed_today"])
        self.assertEqual(status["check_out_time"], "2026-10-28 18:00:00")

    def test_previous_day_pending_does_not_mark_today_checked_in(self):
        self.previous_logs = [Row(log_type="IN", time="2026-10-27 09:00:00")]
        status = self.read()["status"]
        self.assertTrue(status["previous_checkout_pending"])
        self.assertFalse(status["checked_in"])
        self.assertEqual(status["check_in_time"], "2026-10-27 09:00:00")
        self.previous_logs = [Row(log_type="OUT", time="2026-10-27 18:00:00")]
        self.assertFalse(self.read()["status"]["previous_checkout_pending"])

    def test_deleted_logs_restore_checkin_without_completion(self):
        status = self.read()["status"]
        self.assertTrue(status["attendance_records_verified"])
        self.assertFalse(status["checked_in"])
        self.assertFalse(status["completed_today"])

    def test_invalid_log_type_does_not_verify_attendance(self):
        self.today_logs = [Row(log_type="UNKNOWN", time="2026-10-28 09:00:00")]
        self.assertFalse(self.read()["status"]["attendance_records_verified"])


if __name__ == "__main__":
    unittest.main()
