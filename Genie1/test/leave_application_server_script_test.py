from test.business_policy_stub import install as install_business_policy
"""Local API contract tests; these do not run Frappe document hooks."""
from datetime import date
from pathlib import Path
from types import SimpleNamespace
import unittest


class Row(dict):
    __getattr__ = dict.get
    __setattr__ = dict.__setitem__


class LeaveApplicationServerScriptTest(unittest.TestCase):
    def setUp(self):
        self.script = (Path(__file__).resolve().parents[1] /
                       "frappe_server_scripts/create_leave_application_from_mobile.py").read_text()
        self.employee = Row(name="EMP-1", employee_name="Staff", company="Company",
                            department="Sales", leave_approver="manager@example.test")
        self.allocations = [Row(employee="EMP-1", leave_type="Annual", docstatus=1,
                                from_date="2026-01-01", to_date="2026-12-31")]
        self.lwps = []
        self.created = []
        self.tasks_field = Row(fieldtype="Link", options="Employee", ignore_user_permissions=0)
        self.search_calls = []
        self.frappe = SimpleNamespace(
            session=Row(user="staff@example.test", data=Row(csrf_token="csrf")),
            request=SimpleNamespace(method="GET"), response={},
            form_dict=dict(leave_type="Annual", from_date="2026-10-25",
                           to_date="2026-10-26", description="Family", half_day="0", custom_tasks_assigned_to="EMP-2"),
            get_meta=lambda name: SimpleNamespace(get_field=lambda field: self.tasks_field),
            get_all=self.get_all, db=SimpleNamespace(exists=self.exists), call=self.call,
            utils=SimpleNamespace(today=lambda: "2026-10-25", getdate=date.fromisoformat),
            new_doc=self.new_doc,
            throw=lambda message: (_ for _ in ()).throw(ValueError(message)),
        )

    def matches(self, row, filters):
        for key, value in filters.items():
            actual = row[key]
            if isinstance(value, list):
                comparison_date = str(value[1])
                if value[0] == "<=" and actual > comparison_date:
                    return False
                if value[0] == ">=" and actual < comparison_date:
                    return False
            elif actual != value:
                return False
        return True

    def get_all(self, doctype, **kwargs):
        if doctype == "Employee":
            self.assertEqual(kwargs["filters"],
                             {"user_id": "staff@example.test", "status": "Active"})
            return [self.employee]
        if doctype == "Leave Allocation":
            names = {row.leave_type for row in self.allocations
                     if self.matches(row, kwargs["filters"])}
            return [Row(leave_type=name) for name in sorted(names)]
        if doctype == "Department Approver":
            return [Row(approver="department@example.test")]
        self.fail("Unexpected lookup: " + doctype)

    def exists(self, doctype, filters):
        if doctype == "Leave Type":
            return filters in ["Annual", "Sick", "Leave Without Pay"]
        if doctype == "Leave Allocation":
            return any(self.matches(row, filters) for row in self.allocations)
        self.fail("Unexpected existence check: " + doctype)

    def call(self, method, **kwargs):
        if method == "frappe.desk.search.search_link":
            self.search_calls.append(kwargs)
            self.assertEqual(kwargs["doctype"], "Employee")
            self.assertIs(kwargs["ignore_user_permissions"], self.tasks_field.ignore_user_permissions in [1, "1", True])
            self.assertEqual(kwargs["reference_doctype"], "Leave Application")
            self.assertIs(type(kwargs["page_length"]), int)
            if "filters" in kwargs:
                self.assertEqual(kwargs["page_length"], 1)
                self.assertEqual(kwargs["filters"], {"name": kwargs["txt"]})
                allowed = kwargs["txt"] == "EMP-2" or (kwargs["txt"] == "1223" and kwargs["ignore_user_permissions"])
                return [Row(value=kwargs["txt"], description="Employee")] if allowed else []
            self.assertEqual(kwargs["page_length"], 10)
            return [Row(value="1223", description="Arun Adithya T")] if kwargs["txt"] == "1223" else []
        self.assertEqual(method,
                         "hrms.hr.doctype.leave_application.leave_application.get_leave_details")
        self.assertEqual(kwargs["employee"], "EMP-1")
        filters = {"employee": kwargs["employee"], "docstatus": 1,
                   "from_date": ["<=", kwargs["date"]],
                   "to_date": [">=", kwargs["date"]]}
        return {"leave_allocation": {row.leave_type: {} for row in self.allocations
                                     if self.matches(row, filters)}, "lwps": self.lwps}

    def new_doc(self, doctype):
        self.assertEqual(doctype, "Leave Application")
        doc = Row(flags=Row(), name="LEAVE-TEST", total_leave_days=2, status="Open")
        doc.insert = lambda **kwargs: self.created.append(doc)
        return doc

    def run_api(self, method="GET"):
        self.frappe.request.method = method
        install_business_policy(self.frappe)
        exec(compile(self.script, "create_leave_application_from_mobile.py", "exec"),
             {"frappe": self.frappe})
        return self.frappe.response["message"]

    def test_get_only_current_submitted_session_employee_allocations(self):
        for employee, leave_type, status, start, end in [
            ("EMP-OTHER", "Sick", 1, "2026-01-01", "2026-12-31"),
            ("EMP-1", "Sick", 0, "2026-01-01", "2026-12-31"),
            ("EMP-1", "Sick", 2, "2026-01-01", "2026-12-31"),
            ("EMP-1", "Sick", 1, "2025-01-01", "2025-12-31"),
            ("EMP-1", "Sick", 1, "2027-01-01", "2027-12-31"),
        ]:
            self.allocations.append(Row(employee=employee, leave_type=leave_type,
                                        docstatus=status, from_date=start, to_date=end))
        result = self.run_api()
        self.assertEqual(result["leave_types"], [{"value": "Annual", "label": "Annual"}])
        self.assertEqual(result["employee"], "EMP-1")
        self.assertEqual(result["csrf_token"], "csrf")
        self.assertEqual(self.created, [])

    def test_duplicate_allocations_return_one_option(self):
        self.allocations.append(self.allocations[0].copy())
        # Keep the test rows compatible with the mock database's row objects.
        self.allocations[-1] = Row(self.allocations[-1])
        self.assertEqual(len(self.run_api()["leave_types"]), 1)

    def test_no_allocation_returns_clear_error(self):
        self.allocations = []
        with self.assertRaisesRegex(ValueError, "No eligible Leave Types"):
            self.run_api()

    def test_unallocated_type_rejected_before_insert(self):
        self.frappe.form_dict["leave_type"] = "Sick"
        with self.assertRaisesRegex(ValueError, "available for your Employee"):
            self.run_api("POST")
        self.assertEqual(self.created, [])

    def test_post_uses_requested_date_instead_of_today(self):
        self.frappe.form_dict.update(from_date="2027-01-02", to_date="2027-01-03")
        with self.assertRaisesRegex(ValueError, "available for your Employee"):
            self.run_api("POST")
        self.allocations[0].to_date = "2027-12-31"
        self.assertEqual(self.run_api("POST")["status"], "success")

    def test_post_preserves_half_day_employee_and_department_approver_fallback(self):
        self.employee.leave_approver = ""
        self.frappe.form_dict["half_day"] = "1"
        self.frappe.form_dict["employee"] = "EMP-OTHER"
        result = self.run_api("POST")
        self.assertEqual(result["employee"], "EMP-1")
        self.assertEqual(result["half_day"], 1)
        self.assertEqual(self.created[0].half_day_date, date(2026, 10, 25))
        self.assertEqual(self.created[0].leave_approver, "department@example.test")

    def test_tasks_assigned_to_is_required_before_insert(self):
        for value in [None, "", "   ", ["EMP-2"], {"name": "EMP-2"}]:
            self.frappe.form_dict["custom_tasks_assigned_to"] = value
            with self.assertRaisesRegex(ValueError, "Tasks Assigned To is required"):
                self.run_api("POST")
            self.assertEqual(self.created, [])

    def test_unknown_or_inaccessible_assignee_is_rejected(self):
        self.frappe.form_dict["custom_tasks_assigned_to"] = "EMP-DENIED"
        with self.assertRaisesRegex(ValueError, "valid Employee"):
            self.run_api("POST")
        self.assertEqual(self.created, [])

    def test_assignee_is_trimmed_saved_and_returned(self):
        self.frappe.form_dict["custom_tasks_assigned_to"] = " EMP-2 "
        result = self.run_api("POST")
        self.assertEqual(self.created[0].custom_tasks_assigned_to, "EMP-2")
        self.assertEqual(result["custom_tasks_assigned_to"], "EMP-2")
        self.assertEqual(result["employee"], "EMP-1")

    def test_missing_or_wrong_custom_field_configuration_is_rejected(self):
        self.frappe.get_meta = lambda name: SimpleNamespace(get_field=lambda field: None)
        with self.assertRaisesRegex(ValueError, "Employee Link"):
            self.run_api("POST")
        self.assertEqual(self.created, [])

    def test_assignee_policy_is_mandatory_and_visible(self):
        policy = self.run_api()["business_policy"]["fields"]["custom_tasks_assigned_to"]
        self.assertTrue(policy["required"])
        self.assertTrue(policy["visible"])

    def test_employee_search_uses_server_side_link_search(self):
        self.frappe.form_dict.update(view="tasks_assigned_options", txt=" 1223 ")
        result = self.run_api()
        self.assertEqual(result["options"], [{"value": "1223", "description": "Arun Adithya T"}])
        self.assertEqual(self.created, [])

    def test_search_follows_configured_field_permission_exception(self):
        self.tasks_field.ignore_user_permissions = 1
        self.frappe.form_dict.update(view="tasks_assigned_options", txt="1223")
        self.run_api()
        self.assertIs(self.search_calls[-1]["ignore_user_permissions"], True)

    def test_submission_accepts_employee_under_configured_field_exception(self):
        self.tasks_field.ignore_user_permissions = 1
        self.frappe.form_dict["custom_tasks_assigned_to"] = "1223"
        result = self.run_api("POST")
        self.assertEqual(result["custom_tasks_assigned_to"], "1223")
        self.assertEqual(self.created[0].custom_tasks_assigned_to, "1223")
        self.assertIs(self.search_calls[-1]["ignore_user_permissions"], True)

    def test_caller_cannot_override_field_permission_policy(self):
        self.tasks_field.ignore_user_permissions = 0
        self.frappe.form_dict.update(custom_tasks_assigned_to="1223", ignore_user_permissions="1")
        with self.assertRaisesRegex(ValueError, "valid Employee"):
            self.run_api("POST")
        self.assertIs(self.search_calls[-1]["ignore_user_permissions"], False)
        self.assertEqual(self.created, [])

    def test_invalid_employee_still_rejected_with_field_exception(self):
        self.tasks_field.ignore_user_permissions = 1
        self.frappe.form_dict["custom_tasks_assigned_to"] = "EMP-NONEXISTENT"
        with self.assertRaisesRegex(ValueError, "valid Employee"):
            self.run_api("POST")
        self.assertEqual(self.created, [])

    def test_employee_search_returns_empty_matches(self):
        self.frappe.form_dict.update(view="tasks_assigned_options", txt="missing")
        self.assertEqual(self.run_api(), {"options": []})

    def test_employee_search_rejects_invalid_text(self):
        for value in [["1223"], {"name": "1223"}, "a" * 141]:
            self.frappe.form_dict.update(view="tasks_assigned_options", txt=value)
            with self.assertRaisesRegex(ValueError, "140 characters"):
                self.run_api()

    def test_employee_search_requires_active_session_employee(self):
        self.frappe.form_dict.update(view="tasks_assigned_options", txt="1223")
        self.frappe.get_all = lambda *args, **kwargs: []
        with self.assertRaisesRegex(ValueError, "No active Employee"):
            self.run_api()

    def test_employee_search_rejects_guest(self):
        self.frappe.form_dict.update(view="tasks_assigned_options", txt="1223")
        self.frappe.session.user = "Guest"
        with self.assertRaisesRegex(ValueError, "sign in"):
            self.run_api()

    def test_guest_is_rejected(self):
        self.frappe.session.user = "Guest"
        with self.assertRaisesRegex(ValueError, "sign in"):
            self.run_api()

    def test_lwp_only_employee_gets_single_option_without_allocation(self):
        self.allocations = []
        self.lwps = ["Leave Without Pay"]
        result = self.run_api()
        self.assertEqual(result["leave_types"], [
            {"value": "Leave Without Pay", "label": "Leave Without Pay"}])
        self.assertEqual(result["employee"], "EMP-1")
        self.assertEqual(result["csrf_token"], "csrf")

    def test_lwp_submission_does_not_require_allocation(self):
        self.allocations = []
        self.lwps = ["Leave Without Pay"]
        self.frappe.form_dict["leave_type"] = "Leave Without Pay"
        result = self.run_api("POST")
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["leave_type"], "Leave Without Pay")

    def test_allocations_and_lwp_are_combined_without_duplicates(self):
        self.lwps = ["Annual", "Leave Without Pay", "Leave Without Pay"]
        self.assertEqual(self.run_api()["leave_types"], [
            {"value": "Annual", "label": "Annual"},
            {"value": "Leave Without Pay", "label": "Leave Without Pay"}])


if __name__ == "__main__":
    unittest.main()
