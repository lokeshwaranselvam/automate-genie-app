"""Per-user access guards in the custom-app mobile API, without a live ERP."""
import ast
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]
FILES = ("api_utils.py", "api_single_device_updated.py")
HELPERS = ("_ensure_own_user", "_ensure_event_access")


class PermissionDenied(Exception):
    pass


def load(filename, names, frappe):
    tree = ast.parse((ROOT / "backend_patches" / filename).read_text(encoding="utf-8"))
    nodes = []
    for node in tree.body:
        if isinstance(node, ast.Assign) and node.targets[0].id == "OTHER_USER_READ_ROLES":
            nodes.append(node)
        elif isinstance(node, ast.FunctionDef) and node.name in HELPERS + tuple(names):
            node.decorator_list = []
            nodes.append(node)
    namespace = {"frappe": frappe}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), filename, "exec"), namespace)
    return namespace


def fake_frappe(session_user="sales@example.test", roles=("Employee",), assigned=False):
    def throw(message, exc=None):
        raise (exc or Exception)(message)

    def only_for(role):
        if role not in roles:
            raise PermissionDenied("only " + role)

    return SimpleNamespace(
        session=SimpleNamespace(user=session_user),
        get_roles=Mock(return_value=list(roles)),
        throw=throw, only_for=only_for, PermissionError=PermissionDenied,
        db=SimpleNamespace(exists=Mock(return_value="TODO-1" if assigned else None),
                           get_value=Mock(return_value=None)),
        get_doc=Mock(), get_all=Mock(return_value=[]), local=SimpleNamespace(response={}),
        form_dict={},
    )


class OwnUserGuardTest(unittest.TestCase):
    def test_reads_for_another_user_are_rejected_for_employees(self):
        for filename in FILES:
            for name, args in [("event_list", ("other@example.test",)),
                               ("history_list", ("other@example.test",)),
                               ("officetype", ("other@example.test",)),
                               ("checkin_status", ("other@example.test",)),
                               ("checkout_status", ("other@example.test",)),
                               ("event_list_date", ("other@example.test", "2026-10-29")),
                               ("get_checkin_checkout_status", ("other@example.test",))]:
                with self.subTest(filename=filename, name=name):
                    frappe = fake_frappe()
                    fn = load(filename, [name], frappe)[name]
                    with self.assertRaises(PermissionDenied):
                        fn(*args)
                    frappe.db.get_value.assert_not_called()
                    frappe.get_all.assert_not_called()

    def test_own_reads_and_manager_reads_are_allowed(self):
        for filename in FILES:
            for session_user, roles in [("sales@example.test", ("Employee",)),
                                        ("hr@example.test", ("HR Manager",)),
                                        ("admin@example.test", ("System Manager",))]:
                with self.subTest(filename=filename, session_user=session_user):
                    frappe = fake_frappe(session_user, roles)
                    fn = load(filename, ["event_list"], frappe)["event_list"]
                    self.assertEqual(fn("sales@example.test"), [])
                    frappe.get_all.assert_called_once()

    def test_attendance_for_another_user_is_rejected_even_for_managers(self):
        for filename in FILES:
            for name in ("checkin", "checkout"):
                with self.subTest(filename=filename, name=name):
                    frappe = fake_frappe("admin@example.test", ("System Manager", "HR Manager"))
                    fn = load(filename, [name], frappe)[name]
                    with self.assertRaises(PermissionDenied):
                        fn("sales@example.test", "12.9", "77.5")
                    frappe.db.get_value.assert_not_called()


class EventAccessGuardTest(unittest.TestCase):
    def event(self, owner="planner@example.test"):
        data = {"name": "EVENT-1", "owner": owner, "event_participants": []}
        event = Mock()
        event.get.side_effect = lambda key, default=None: data.get(key, default)
        event.as_dict.return_value = data
        return event

    def test_unassigned_employee_cannot_read_event(self):
        for filename in FILES:
            with self.subTest(filename=filename):
                frappe = fake_frappe(assigned=False)
                frappe.get_doc.return_value = self.event()
                fn = load(filename, ["event_details"], frappe)["event_details"]
                with self.assertRaises(PermissionDenied):
                    fn("EVENT-1")
                filters = frappe.db.exists.call_args.args[1]
                self.assertEqual(filters["allocated_to"], "sales@example.test")
                self.assertEqual(filters["status"], ["!=", "Cancelled"])

    def test_assignee_owner_and_manager_can_read_event(self):
        for filename in FILES:
            for frappe, owner in [(fake_frappe(assigned=True), "planner@example.test"),
                                  (fake_frappe(), "sales@example.test"),
                                  (fake_frappe("hr@example.test", ("HR Manager",)), "planner@example.test")]:
                with self.subTest(filename=filename, owner=owner):
                    frappe.get_doc.return_value = self.event(owner)
                    fn = load(filename, ["event_details"], frappe)["event_details"]
                    self.assertEqual(fn("EVENT-1")["event"]["name"], "EVENT-1")


class GenerateKeysGuardTest(unittest.TestCase):
    def test_only_system_manager_can_generate_keys(self):
        for filename in FILES:
            with self.subTest(filename=filename):
                frappe = fake_frappe()
                fn = load(filename, ["generate_keys"], frappe)["generate_keys"]
                with self.assertRaises(PermissionDenied):
                    fn("Administrator")
                frappe.get_doc.assert_not_called()


if __name__ == "__main__":
    unittest.main()
