"""Compare restriction results with the original captured SQL; no ERP writes.

SQLite verifies result semantics only, not MariaDB query plans or latency.
"""
import ast
from collections import Counter
from itertools import product
from pathlib import Path
import sqlite3
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = {
    "mr": "unprocessed_mr_checkout_restriction.py",
    "quotation": "bioman_confirmed_quotation_checkout_restriction.py",
}


class RestrictionQueriesTest(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.addCleanup(self.db.close)
        self.db.create_function("CURDATE", 0, lambda: "2026-10-13")
        self.db.executescript('''
            CREATE TABLE `tabMaterial Request` (name TEXT PRIMARY KEY, schedule_date TEXT,
                docstatus INTEGER, material_request_type TEXT, status TEXT, workflow_state TEXT);
            CREATE TABLE `tabToDo` (reference_type TEXT, reference_name TEXT, status TEXT, allocated_to TEXT);
            CREATE TABLE `tabPurchase Order` (name TEXT PRIMARY KEY, docstatus INTEGER);
            CREATE TABLE `tabPurchase Order Item` (parent TEXT, material_request TEXT);
            CREATE TABLE `tabProject` (name TEXT PRIMARY KEY, project_name TEXT, project_type TEXT,
                status TEXT, owner TEXT, modified TEXT);
            CREATE TABLE `tabQuotation` (name TEXT PRIMARY KEY, custom_project TEXT, workflow_state TEXT);
            CREATE TABLE `tabSales Order` (name TEXT PRIMARY KEY, project TEXT, docstatus INTEGER);
        ''')

    def queries(self, kind):
        original = (ROOT / "test/fixtures" / (kind + "_checkout_original.sql")).read_text()
        source = (ROOT / "frappe_server_scripts" / SCRIPTS[kind]).read_text()
        queries = [node.value for node in ast.walk(ast.parse(source))
                   if isinstance(node, ast.Constant) and isinstance(node.value, str)
                   and "SELECT" in node.value]
        return original.replace("%s", "?"), queries[-1].replace("%s", "?")

    def test_mr_query_preserves_exemptions_nulls_and_duplicate_assignment_count(self):
        cases = product([0, 1, 2], ["Purchase", "Material Issue"],
                        ["Pending", "Draft", "Stopped", "Cancelled", None],
                        ["Approved", "Cancelled", None], ["2026-10-12", "2026-10-14", None])
        for i, (docstatus, kind, status, workflow, scheduled) in enumerate(cases):
            name = "MR-" + str(i)
            self.db.execute("INSERT INTO `tabMaterial Request` VALUES (?, ?, ?, ?, ?, ?)",
                            (name, scheduled, docstatus, kind, status, workflow))
            for user in ["staff", "staff", "other"]:
                self.db.execute("INSERT INTO `tabToDo` VALUES ('Material Request', ?, 'Open', ?)", (name, user))
            # Exercise no PO, draft/cancelled POs, and duplicate submitted items.
            if i % 4:
                po = "PO-" + str(i)
                self.db.execute("INSERT INTO `tabPurchase Order` VALUES (?, ?)", (po, i % 4 - 1))
                for _ in range(2):
                    self.db.execute("INSERT INTO `tabPurchase Order Item` VALUES (?, ?)", (po, name))
        self.db.execute("INSERT INTO `tabMaterial Request` VALUES ('BIO-MR-1176', '2026-10-12', 1, 'Purchase', 'Pending', 'Approved')")
        self.db.execute("INSERT INTO `tabToDo` VALUES ('Material Request', 'BIO-MR-1176', 'Open', 'staff')")
        self.db.execute("INSERT INTO `tabMaterial Request` VALUES ('PENDING', '2026-10-12', 1, 'Purchase', 'Pending', 'Approved')")
        for _ in range(2):
            self.db.execute("INSERT INTO `tabToDo` VALUES ('Material Request', 'PENDING', 'Open', 'staff')")
        original, revised = self.queries("mr")
        for user in ["staff", "other", "nobody"]:
            old = self.db.execute(original, (user,)).fetchall()
            # The revised query binds the site date instead of DB-timezone CURDATE().
            new = self.db.execute(revised, ("2026-10-13", user)).fetchall()
            self.assertEqual(Counter(old), Counter(new))
            if user == "staff":
                self.assertTrue(new)
                self.assertTrue(all(count == 2 for count in Counter(new).values()))
                self.assertNotIn("BIO-MR-1176", [row[0] for row in new])

    def test_quotation_query_preserves_order_multiple_quotations_and_submitted_so_rule(self):
        cases = product(["staff", "other"], ["Bioman Production", "Other"],
                        ["Open", "Completed", "Cancelled", None], [None, 0, 1, 2])
        for i, (owner, kind, status, so_status) in enumerate(cases):
            name = "P-" + str(i)
            self.db.execute("INSERT INTO `tabProject` VALUES (?, ?, ?, ?, ?, ?)",
                            (name, name, kind, status, owner, str(i).zfill(4)))
            for q, state in [("A", "Confirmed"), ("B", "Confirmed"), ("C", "Draft"), ("D", None)]:
                self.db.execute("INSERT INTO `tabQuotation` VALUES (?, ?, ?)", (name + q, name, state))
            if so_status is not None:
                for j in range(2):
                    self.db.execute("INSERT INTO `tabSales Order` VALUES (?, ?, ?)", (name + str(j), name, so_status))
        self.db.execute("INSERT INTO `tabSales Order` VALUES ('UNLINKED', NULL, 1)")
        original, revised = self.queries("quotation")
        for user in ["staff", "other", "nobody"]:
            old = self.db.execute(original, (user,)).fetchall()
            new = self.db.execute(revised, (user,)).fetchall()
            self.assertEqual(old, new)
            if user == "staff":
                self.assertTrue(new)

    def run_script(self, kind, log_type="OUT", checkin=True, user="staff", leave=False, permission=False, pending=False, latest="IN"):
        sql = Mock(side_effect=lambda query, *args, **kwargs:
                   ([{"name": "EXEMPT"}] if leave else []) if "tabLeave Application" in query else
                   ([{"name": "EXEMPT"}] if permission else []) if "tabAttendance Request" in query else
                   [SimpleNamespace(name="MR", project_id="P", quotation="Q")] if pending else [])
        frappe = SimpleNamespace(
            utils=SimpleNamespace(today=lambda: "2026-10-13"),
            get_all=Mock(return_value=[SimpleNamespace(log_type=latest)] if checkin else []),
            db=SimpleNamespace(get_value=Mock(return_value=user), sql=sql),
            throw=Mock(side_effect=ValueError("blocked")), ValidationError=ValueError,
        )
        self.frappe = frappe
        source = (ROOT / "frappe_server_scripts" / SCRIPTS[kind]).read_text()
        exec(compile(source, SCRIPTS[kind], "exec"),
             {"frappe": frappe, "doc": SimpleNamespace(employee="EMP", log_type=log_type)})
        return sql

    def test_restrictions_skip_in_missing_checkin_and_missing_user(self):
        for kind in SCRIPTS:
            for params in [{"log_type": "IN"}, {"checkin": False}, {"latest": "OUT"}, {"user": None}]:
                with self.subTest(kind=kind, params=params):
                    self.run_script(kind, **params).assert_not_called()

    def test_open_in_from_any_day_is_restricted_using_site_date(self):
        for kind in SCRIPTS:
            with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, "blocked"):
                self.run_script(kind, pending=True)
            # No date window: an overnight IN (latest log) is still the open IN.
            filters = self.frappe.get_all.call_args.kwargs["filters"]
            self.assertEqual(filters, {"employee": "EMP"})
            self.assertEqual(self.frappe.get_all.call_args.kwargs["order_by"], "time desc, creation desc")
            source = (ROOT / "frappe_server_scripts" / SCRIPTS[kind]).read_text()
            self.assertNotIn("CURDATE", source)
        sql = Mock(return_value=[])
        frappe = SimpleNamespace(utils=SimpleNamespace(today=lambda: "2026-10-13"),
            get_all=Mock(return_value=[SimpleNamespace(log_type="IN")]),
            db=SimpleNamespace(get_value=Mock(return_value="staff"), sql=sql), throw=Mock())
        exec(compile((ROOT / "frappe_server_scripts" / SCRIPTS["mr"]).read_text(), "mr", "exec"),
             {"frappe": frappe, "doc": SimpleNamespace(employee="EMP", log_type="OUT")})
        self.assertEqual([call.args[1] for call in sql.call_args_list],
                         [("EMP", "2026-10-13", "2026-10-13"), ("EMP", "2026-10-13"), ("2026-10-13", "staff")])

    def test_halfday_and_permission_still_exempt_mr_checkout(self):
        for params in [{"leave": True}, {"permission": True}]:
            sql = self.run_script("mr", pending=True, **params)
            self.assertEqual(sql.call_count, 2)

    def test_pending_records_still_block_and_empty_records_allow(self):
        for kind in SCRIPTS:
            self.run_script(kind)
            with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, "blocked"):
                self.run_script(kind, pending=True)


if __name__ == "__main__":
    unittest.main()
