"""Run with: python -m unittest discover -s test -p expense_claim_api_test.py"""
from datetime import date
from io import BytesIO
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock


class Row(dict):
    __getattr__ = dict.get
    __setattr__ = dict.__setitem__


class Document(Row):
    def append(self, field, value):
        self.setdefault(field, []).append(Row(value))

    def insert(self, **kwargs):
        self.insert_options = kwargs
        self.inserted = True
        if self.doctype == "Expense Claim":
            self.name = "HR-EXP-TEST"
            for index, row in enumerate(self.expenses, 1):
                row.name = "EXP-" + str(index)
            self.total_claimed_amount = sum(row.amount for row in self.expenses)
            self.total_sanctioned_amount = sum(row.sanctioned_amount for row in self.expenses)
        else:
            self.name = "FILE-" + self.file_name
            self.file_url = "/private/files/" + self.file_name
        return self


class ExpenseClaimApiTest(unittest.TestCase):
    def setUp(self):
        self.script = (Path(__file__).resolve().parents[1] /
                       "frappe_server_scripts/create_expense_claim_from_mobile.py").read_text()
        self.employee = Row(name="EMP-1", employee_name="Staff", company="Company",
                            department="Sales", user_id="staff@example.test", status="Active",
                            expense_approver="approver@example.test")
        self.company = Row(default_currency="INR", cost_center="Main - C",
                           default_expense_claim_payable_account="Payable - C")
        self.created = []
        self.params = dict(employee="EMP-1", expense_approver="approver@example.test",
                           expense_type="Travel", description="Taxi", expense_date="2026-10-13",
                           amount="125.50")
        self.uploads = [self.upload("bill.png")]
        self.frappe = SimpleNamespace(
            session=Row(user=self.employee.user_id, data=Row(csrf_token="csrf")),
            request=SimpleNamespace(method="POST", files=SimpleNamespace(
                getlist=lambda key: self.uploads if key == "file" else [])),
            response={}, get_meta=lambda name: SimpleNamespace(get_field=lambda field: True),
            get_all=Mock(side_effect=self.get_all),
            new_doc=Mock(side_effect=self.new_doc),
            db=SimpleNamespace(get_value=Mock(side_effect=self.get_value),
                               exists=Mock(side_effect=self.exists)),
            utils=SimpleNamespace(getdate=date.fromisoformat, today=lambda: "2026-10-13"),
            throw=lambda message: (_ for _ in ()).throw(ValueError(message)),
        )

    def upload(self, name, content=b"image"):
        return SimpleNamespace(filename=name, stream=BytesIO(content))

    def new_doc(self, doctype):
        doc = Document(doctype=doctype)
        self.created.append(doc)
        return doc

    def get_value(self, doctype, name, *args, **kwargs):
        if doctype == "Employee":
            return self.employee if name == self.employee.name else None
        if doctype == "Company":
            return self.company
        self.fail("Unexpected lookup: " + doctype)

    def exists(self, doctype, filters):
        if doctype == "Expense Claim Type":
            return filters in ["Travel", "Meals"]
        if doctype == "User":
            return filters["name"] in ["approver@example.test", "other@example.test"]
        if doctype in ["Department Approver", "Has Role"]:
            return False
        self.fail("Unexpected existence check: " + doctype)

    def get_all(self, doctype, **kwargs):
        if doctype == "Employee":
            return [self.employee]
        if doctype == "User":
            return [Row(name="approver@example.test", full_name="Approver")]
        if doctype == "Expense Claim Type":
            return [Row(name="Travel", expense_type="Travel"), Row(name="Meals", expense_type="Meals")]
        if doctype in ["Has Role", "Department Approver"]:
            return []
        self.fail("Unexpected options lookup: " + doctype)

    def run_api(self, **overrides):
        self.frappe.form_dict = dict(self.params, **overrides)
        exec(compile(self.script, "create_expense_claim_from_mobile.py", "exec"),
             {"frappe": self.frappe, "json": json})
        return self.frappe.response["message"]

    def rows(self):
        return [dict(expense_type="Travel", description="Taxi", expense_date="2026-10-12", amount="125.50"),
                dict(expense_type="Meals", description="Lunch", expense_date="2026-10-13", amount="80")]

    def test_multiple_rows_and_bills_create_one_claim_with_correct_totals(self):
        self.uploads.append(self.upload("lunch.png", b"second image"))
        result = self.run_api(expenses=json.dumps(self.rows()))
        claim, bill1, bill2 = self.created
        self.assertEqual([doc.doctype for doc in self.created], ["Expense Claim", "File", "File"])
        self.assertEqual(result["total_claimed_amount"], 205.50)
        self.assertEqual(result["total_sanctioned_amount"], 205.50)
        self.assertEqual([row.expense_type for row in claim.expenses], ["Travel", "Meals"])
        self.assertEqual([row.expense_date for row in claim.expenses], [date(2026, 10, 12), date(2026, 10, 13)])
        self.assertEqual([row.description for row in claim.expenses], ["Taxi", "Lunch"])
        self.assertTrue(all(row.cost_center == self.company.cost_center for row in claim.expenses))
        self.assertEqual(claim.employee, self.employee.name)
        self.assertEqual(claim.approval_status, "Draft")
        for bill in [bill1, bill2]:
            self.assertEqual(bill.attached_to_name, claim.name)
            self.assertEqual(bill.attached_to_doctype, "Expense Claim")
            self.assertEqual(bill.is_private, 1)
        self.assertEqual(bill2.content, b"second image")
        self.assertEqual(len(result["expenses"]), 2)
        self.assertEqual(len(result["bill_files"]), 2)
        self.assertEqual(result["expense_row"], "EXP-1")
        self.assertEqual(result["bill_file_url"], bill1.file_url)

    def test_legacy_single_row_request_and_response_remain_supported(self):
        result = self.run_api()
        self.assertEqual(result["amount"], 125.50)
        self.assertEqual(result["sanctioned_amount"], 125.50)
        self.assertEqual(result["description"], "Taxi")
        self.assertEqual(len(result["expenses"]), 1)
        self.assertEqual(len(result["bill_files"]), 1)

    def test_one_bill_can_cover_multiple_expenses(self):
        result = self.run_api(expenses=json.dumps(self.rows()))
        self.assertEqual(len(result["expenses"]), 2)
        self.assertEqual(len(result["bill_files"]), 1)

    def test_invalid_second_row_never_creates_partial_claim(self):
        for field, value in [("expense_type", "Unknown"), ("description", " "),
                             ("expense_date", "invalid"), ("amount", "NaN"),
                             ("amount", "Infinity"), ("amount", "-1"), ("amount", "0"),
                             ("amount", "bad"), ("amount", ""), ("expense_date", "")]:
            with self.subTest(field=field, value=value):
                rows = self.rows()
                rows[1][field] = value
                with self.assertRaisesRegex(ValueError, "Expense 2:"):
                    self.run_api(expenses=json.dumps(rows))
                self.assertEqual(self.created, [])

    def test_malformed_or_empty_list_never_falls_back_to_legacy_fields(self):
        for payload in ["bad json", "[]", "{}", "null", '["bad row"]', ""]:
            with self.subTest(payload=payload):
                with self.assertRaises(ValueError):
                    self.run_api(expenses=payload)
                self.assertEqual(self.created, [])

    def test_missing_or_empty_bill_is_rejected_before_insert(self):
        for uploads in [[], [self.upload("empty.png", b"")],
                        [self.upload("ok.png"), self.upload("empty.png", b"")]]:
            self.uploads = uploads
            with self.assertRaises(ValueError):
                self.run_api(expenses=json.dumps(self.rows()))
            self.assertEqual(self.created, [])

    def test_employee_and_approver_scope_still_enforced(self):
        for overrides in [dict(employee="EMP-OTHER"), dict(expense_approver="other@example.test")]:
            self.uploads = [self.upload("bill.png")]
            with self.assertRaises(ValueError):
                self.run_api(expenses=json.dumps(self.rows()), **overrides)
            self.assertEqual(self.created, [])
        self.employee.user_id = "another@example.test"
        self.uploads = [self.upload("bill.png")]
        with self.assertRaisesRegex(ValueError, "allowed to create claims"):
            self.run_api(expenses=json.dumps(self.rows()))
        self.assertEqual(self.created, [])

    def test_get_options_advertise_multiple_expenses_without_creating_documents(self):
        self.frappe.request.method = "GET"
        result = self.run_api()
        self.assertIs(result["supports_multiple_expenses"], True)
        self.assertEqual(result["expense_approver"], "approver@example.test")
        self.assertEqual(result["csrf_token"], "csrf")
        self.assertEqual(len(result["expense_types"]), 2)
        self.assertEqual(self.created, [])


if __name__ == "__main__":
    unittest.main()
