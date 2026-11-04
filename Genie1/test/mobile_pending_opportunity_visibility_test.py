"""Local permission/query contracts; not deployed ERP verification."""
import ast
import sqlite3
import unittest
from datetime import date
from pathlib import Path
from types import SimpleNamespace

SOURCE = (Path(__file__).parents[1] / "frappe_server_scripts/mobile_pending_work_api.py").read_text()
USER = "sales@example.test"
FIELDS = ["name", "creation", "owner", "title", "custom_citytown", "custom_customer_category", "custom_product_enquired", "custom_description", "contact_mobile", "opportunity_owner", "party_name", "custom_field_owner_1", "custom_field_owner_2"]

class FakeFrappe:
    PermissionError = PermissionError
    def __init__(self, user=USER, roles=None):
        self.session = SimpleNamespace(user=user)
        self.form_dict = {"action": "opportunities"}
        self.response = {}
        self.roles = roles if roles is not None else ["Sales User"]
        self.queries = []
        self.conn = sqlite3.connect(":memory:")
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("CREATE TABLE `tabOpportunity` (" + ", ".join(field + " TEXT" for field in FIELDS) + ", status TEXT, readable INTEGER)")
        self.db = SimpleNamespace(sql=self.sql, get_value=self.get_value)
        self.utils = SimpleNamespace(today=lambda: "2026-10-31", getdate=date.fromisoformat)
    def throw(self, message, exc=ValueError):
        raise exc(message)
    def get_all(self, dt, **kwargs):
        if dt == "Has Role":
            return self.roles
        if dt == "Opportunity":
            raise AssertionError("Opportunity reads must use ERP permissions")
        return []
    def get_meta(self, dt):
        return SimpleNamespace(get_field=lambda field: SimpleNamespace(fieldtype="Link", options="User"))
    def get_value(self, dt, name, fields, as_dict=False):
        if dt == "User":
            return {"full_name": name, "enabled": 1} if as_dict else name
        return None
    def get_list(self, dt, **kw):
        assert dt == "Opportunity" and kw["run"] is False
        assert kw["filters"] == {"status": "Open"}
        assert not kw.get("ignore_permissions")
        assert kw["limit_page_length"] == 0
        self.queries.append(kw)
        # Model ERP read restrictions and field-level removal of a protected field.
        columns = [field for field in kw["fields"] if field != "custom_description"]
        return "SELECT " + ", ".join(columns) + " FROM `tabOpportunity` WHERE status='Open' AND readable=1 ORDER BY creation DESC"
    def sql(self, query, values=None, as_dict=False):
        if not query.startswith("SELECT visible_opportunities.*"):
            return []  # Unrelated overdue/delivery sections have empty fixtures.
        escaped = {key: "'" + value.replace("'", "''") + "'" for key, value in values.items()}
        return [dict(row) for row in self.conn.execute(query % escaped)]
    def add(self, name, primary=USER, first="", second="", status="Open", readable=True, creator="other.creator@example.test"):
        row = dict.fromkeys(FIELDS, "")
        row.update(name=name, creation=name, title=name, owner=creator,
                   opportunity_owner=primary, custom_field_owner_1=first, custom_field_owner_2=second,
                   custom_description="protected")
        self.conn.execute("INSERT INTO `tabOpportunity` VALUES (" + ",".join("?" for _ in range(len(FIELDS) + 2)) + ")", list(row.values()) + [status, readable])
    def run(self, action="opportunities"):
        self.form_dict = {"action": action}
        exec(compile(SOURCE, "mobile_pending_work_api.py", "exec"), {"frappe": self})
        return self.response["message"]

class PendingOpportunityTests(unittest.TestCase):
    def fake(self, **kwargs):
        fake = FakeFrappe(**kwargs)
        self.addCleanup(fake.conn.close)
        return fake
    def test_all_priority_cases_and_creator_does_not_grant_visibility(self):
        cases = [
            (USER, "first@example.test", "second@example.test", "second@example.test"),
            (USER, USER, "second@example.test", "second@example.test"),
            (USER, "first@example.test", "", "first@example.test"),
            (USER, "", "", USER),
            (USER, None, None, USER),
            (USER, USER, USER, USER),
            (None, None, None, None),
        ]
        for primary, first, second, expected in cases:
            for actor in [USER, "first@example.test", "second@example.test", "creator@example.test"]:
                with self.subTest(owners=(primary, first, second), actor=actor):
                    f = self.fake(user=actor)
                    f.add("OPP-1", primary, first, second, creator="creator@example.test")
                    result = f.run()
                    self.assertEqual(result["count"], int(actor == expected))
                    self.assertEqual(len(result["items"]), result["count"])
                    self.assertFalse(any(row["description"] for row in result["items"]))
    def test_open_status_normal_permissions_order_and_dashboard_count(self):
        f = self.fake()
        for i in range(8):
            f.add("OPP-" + str(i), primary="other@example.test", second=USER)
        f.add("FOLLOW-UP", second=USER, status="Follow-up")
        f.add("ERP-DENIED", second=USER, readable=False)
        f.add("NOT-ASSIGNED", primary="other@example.test", creator=USER)
        rows = f.run()
        self.assertEqual(rows["count"], 8)
        self.assertEqual([r["name"] for r in rows["items"]], ["OPP-" + str(i) for i in reversed(range(8))])
        dashboard = f.run("dashboard")
        self.assertEqual(dashboard["opportunities"]["count"], 8)
        self.assertEqual(dashboard["opportunities"]["items"], rows["items"][:5])
    def test_guest_and_non_sales_role_are_rejected(self):
        for kwargs in [{"user": "Guest"}, {"roles": ["Manufacturing User"]}]:
            with self.subTest(kwargs=kwargs), self.assertRaises(PermissionError):
                self.fake(**kwargs).run()
    def test_session_user_is_bound_as_a_value(self):
        actor = "sales' OR 1=1 --@example.test"
        f = self.fake(user=actor)
        f.add("ASSIGNED", primary=actor)
        f.add("UNRELATED", primary=USER)
        self.assertEqual([r["name"] for r in f.run()["items"]], ["ASSIGNED"])
    def test_restricted_script_has_no_imports_or_function_definitions(self):
        self.assertFalse(any(isinstance(n, (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.AsyncFunctionDef)) for n in ast.walk(ast.parse(SOURCE))))

if __name__ == "__main__":
    unittest.main()
