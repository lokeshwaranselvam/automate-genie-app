"""Local contract/SQL checks, not a deployed Frappe Safe Exec integration test."""
import ast
import sqlite3
import unittest
from pathlib import Path
from types import SimpleNamespace

SOURCE = (Path(__file__).parents[1] / "frappe_server_scripts/mobile_opportunity_policy.py").read_text()
USER = "sales@example.test"
FIELDS = ["opportunity_owner", "custom_field_owner_1", "custom_field_owner_2"]

class Attr(dict):
    def __getattr__(self, name):
        return self.get(name)

class Document(Attr):
    def check_permission(self, kind):
        if not self.get("readable"):
            raise PermissionError("ERP read denied")
    def has_permission(self, kind):
        return self.get("writable", False)
    def apply_fieldlevel_read_permissions(self):
        self.pop("protected_secret", None)
    def as_dict(self):
        return dict(self)

class FakeFrappe:
    connections = []
    PermissionError = PermissionError
    def __init__(self, args=None, user=USER):
        self.session = Attr(user=user)
        self.form_dict = {"action": "list", **(args or {})}
        self.response = {}
        self.calls = []
        self.call = lambda *args, **kwargs: {"policy": {}}
        self.rows = []
        self.conn = sqlite3.connect(":memory:")
        self.connections.append(self.conn)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("CREATE TABLE `tabOpportunity` (name TEXT, owner TEXT, opportunity_owner TEXT, custom_field_owner_1 TEXT, custom_field_owner_2 TEXT, status TEXT, phone TEXT, contact_mobile TEXT, creation TEXT, readable INTEGER)")
        self.db = SimpleNamespace(sql=self.sql, escape=lambda value, percent=True: "'" + value.replace("'", "''") + "'")
    def add(self, name, field=None, readable=True, status="Open", phone="9876543210"):
        row = Document(name=name, owner="creator", opportunity_owner="other", custom_field_owner_1="", custom_field_owner_2="", status=status, phone=phone, contact_mobile="", creation=name, readable=readable, protected_secret="secret")
        if field:
            row[field] = USER
        self.rows.append(row)
        keys = ["name", "owner"] + FIELDS + ["status", "phone", "contact_mobile", "creation", "readable"]
        self.conn.execute("INSERT INTO `tabOpportunity` VALUES (?,?,?,?,?,?,?,?,?,?)", [row[k] for k in keys])
        return row
    def throw(self, message, exc=ValueError):
        raise exc(message)
    def get_meta(self, dt):
        return SimpleNamespace(get_field=lambda field: Attr(fieldtype="Link", options="User") if field in FIELDS else Attr(fieldtype="Data"))
    def get_doc(self, dt, name):
        return next(r for r in self.rows if r.name == name)
    def get_list(self, dt, **kw):
        self.calls.append(kw)
        assert dt == "Opportunity"
        assert not kw.get("ignore_permissions")
        filters = kw.get("filters", [])
        ors = kw.get("or_filters", [])
        def literal(value):
            return "'" + value.replace("'", "''") + "'"
        def condition(f):
            field, op, value = f
            if op == "in":
                return field + " IN (" + ",".join(literal(x) for x in value) + ")"
            assert op in ["=", "like"]
            return field + " " + op + " " + literal(value)
        where = ["readable = 1"] + [condition(f) for f in filters]
        if ors:
            where.append("(" + " OR ".join(condition(f) for f in ors) + ")")
        sql = "SELECT name FROM `tabOpportunity` WHERE " + " AND ".join(where) + " ORDER BY name ASC"
        if kw.get("run") is False:
            assert kw["limit_page_length"] in [0, 50]
            return sql
        names = [r[0] for r in self.conn.execute(sql)]
        return [dict(r) for r in sorted(self.rows, key=lambda r: r.name, reverse=True) if r.name in names][:kw["limit_page_length"]]
    def sql(self, query, values=None, as_dict=False):
        if values is not None:
            # Model the driver's percent substitution, including escaped LIKE literals.
            query = query % values
        return [Attr(dict(r)) for r in self.conn.execute(query)]
    def run(self):
        exec(compile(SOURCE, "mobile_opportunity_policy.py", "exec"), {"frappe": self})
        return self.response["message"]

class AccessTests(unittest.TestCase):
    def tearDown(self):
        for conn in FakeFrappe.connections:
            conn.close()
        FakeFrappe.connections.clear()
    def test_restricted_script_structure(self):
        tree = ast.parse(SOURCE)
        self.assertFalse(any(isinstance(n, (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.AsyncFunctionDef)) for n in ast.walk(tree)))
    def test_all_owners_normal_permissions_no_duplicates(self):
        f = FakeFrappe()
        for i, field in enumerate(FIELDS):
            f.add(str(i), field)
        f.conn.execute("UPDATE `tabOpportunity` SET custom_field_owner_2 = ? WHERE name = ?", [USER, "0"])
        f.add("unrelated")
        f.add("denied", FIELDS[1], readable=False)
        m = f.run()
        self.assertEqual({r["name"] for r in m["items"]}, {"0", "1", "2"})
        self.assertEqual(f.calls[0]["or_filters"], [
            ["custom_field_owner_2", "=", USER],
            ["custom_field_owner_1", "=", USER],
            ["opportunity_owner", "=", USER],
        ])
        self.assertFalse(m["has_more"])
        f.form_dict = {"action": "count"}
        self.assertEqual(f.run()["count"], 3)
    def test_only_first_populated_owner_can_list_count_or_read(self):
        cases = [
            # Primary, Owner 1, Owner 2, expected reader.
            (USER, "first@example.test", "second@example.test", "second@example.test"),
            (USER, USER, "second@example.test", "second@example.test"),
            (USER, "first@example.test", "", "first@example.test"),
            (USER, "", "", USER),
            (USER, None, None, USER),
            (USER, USER, USER, USER),
            (USER, None, "second@example.test", "second@example.test"),
            (None, None, None, None),
        ]
        for primary, first, second, expected in cases:
            for actor in [USER, "first@example.test", "second@example.test"]:
                with self.subTest(owners=(primary, first, second), actor=actor):
                    f = FakeFrappe(user=actor)
                    row = f.add("OPP")
                    for key, value in zip(FIELDS, [primary, first, second]):
                        row[key] = value
                    f.conn.execute("UPDATE `tabOpportunity` SET opportunity_owner=?, custom_field_owner_1=?, custom_field_owner_2=? WHERE name='OPP'", [primary, first, second])
                    visible = actor == expected
                    self.assertEqual(bool(f.run()["items"]), visible)
                    f.form_dict = {"action": "count"}
                    self.assertEqual(f.run()["count"], int(visible))
                    f.form_dict = {"action": "detail", "name": "OPP"}
                    if visible:
                        self.assertEqual(f.run()["document"]["name"], "OPP")
                    else:
                        with self.assertRaises(PermissionError):
                            f.run()

    def test_phone_and_status_are_combined_with_owner_scope(self):
        f = FakeFrappe({"phone": "+98-7", "status": "Demo"})
        f.add("match", FIELDS[2], status="Demo", phone="98 7")
        f.add("wrong-phone", FIELDS[0], status="Demo", phone="123")
        f.add("wrong-status", FIELDS[1])
        f.add("unrelated", status="Demo")
        self.assertEqual([r["name"] for r in f.run()["items"]], ["match"])
        f.form_dict["action"] = "count"
        self.assertEqual(f.run()["count"], 1)
    def test_pagination_is_bounded_and_stable(self):
        f = FakeFrappe()
        for i in range(52):
            f.add(str(i).zfill(3), FIELDS[i % 3])
        first = f.run()
        self.assertEqual(len(first["items"]), 50)
        self.assertTrue(first["has_more"])
        f.form_dict = {"action": "list", "start": first["next_start"]}
        second = f.run()
        self.assertEqual(len(second["items"]), 2)
        self.assertFalse(second["has_more"])
        self.assertFalse({r["name"] for r in first["items"]} & {r["name"] for r in second["items"]})
    def test_detail_rejects_unrelated_and_erp_denied(self):
        for field, readable in [(None, True), (FIELDS[1], False)]:
            f = FakeFrappe({"action": "detail", "name": "OPP"})
            f.add("OPP", field, readable=readable)
            with self.assertRaises(PermissionError):
                f.run()
    def test_details_strip_protected_fields_and_preserve_edit_scope(self):
        for field in FIELDS:
            f = FakeFrappe({"action": "detail", "name": "OPP"})
            row = f.add("OPP", field)
            row["writable"] = True
            result = f.run()
            self.assertEqual(result["can_edit"], field == "opportunity_owner")
            self.assertNotIn("protected_secret", result["document"])
    def test_primary_owner_without_write_permission_stays_read_only(self):
        f = FakeFrappe({"action": "detail", "name": "OPP"})
        f.add("OPP", FIELDS[0])
        self.assertFalse(f.run()["can_edit"])
    def test_missing_owner_field_configuration_fails_closed(self):
        f = FakeFrappe()
        f.get_meta = lambda dt: SimpleNamespace(get_field=lambda field: None)
        with self.assertRaises(ValueError):
            f.run()
        self.assertFalse(f.calls)
    def test_guest_invalid_action_and_invalid_parameters(self):
        with self.assertRaises(ValueError):
            FakeFrappe(user="Guest").run()
        for args in [{"action": "delete"}, {"start": "-1"}, {"phone": "987%"}, {"phone": "x' OR 1=1"}]:
            with self.assertRaises(ValueError):
                FakeFrappe(args).run()

if __name__ == "__main__":
    unittest.main()
