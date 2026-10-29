"""Task board save permissions in the Tsg API Server Script, without a live ERP."""
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

SCRIPT = (Path(__file__).resolve().parents[1] / "frappe_server_scripts" / "tsg_task_api.py").read_text(encoding="utf-8")


class Denied(Exception):
    pass


class TsgTaskSaveTest(unittest.TestCase):
    def run_save(self, owner="planner@example.test", assigned=False, write_permission=False):
        task = SimpleNamespace(name="TASK-1", owner=owner, save=Mock(), insert=Mock())

        def throw(message, exc=None):
            raise Denied(message)

        frappe = SimpleNamespace(
            form_dict={"action": "save", "task_id": "TASK-1", "subject": "Fix gate"},
            session=SimpleNamespace(user="sales@example.test"),
            db=SimpleNamespace(
                get_value=Mock(side_effect=lambda doctype, name, field=None: (
                    1 if field == "enabled" else name if doctype == "User" else None)),
                exists=Mock(return_value="TODO-1" if assigned else None),
                set_value=Mock(),
            ),
            get_doc=Mock(return_value=task), new_doc=Mock(return_value=SimpleNamespace(
                name="TODO-NEW", insert=Mock(), save=Mock())),
            has_permission=Mock(return_value=write_permission),
            throw=throw, response={},
        )
        self.frappe = frappe
        exec(compile(SCRIPT, "tsg_task_api.py", "exec"), {"frappe": frappe})
        return task, frappe

    def test_unrelated_user_cannot_edit_task(self):
        with self.assertRaises(Denied):
            self.run_save()

    def test_creator_assignee_and_permitted_user_can_edit(self):
        for kwargs in ({"owner": "sales@example.test"}, {"assigned": True}, {"write_permission": True}):
            with self.subTest(**kwargs):
                task, frappe = self.run_save(**kwargs)
                task.save.assert_called_once_with(ignore_permissions=True)
                self.assertEqual(frappe.response["message"]["task_id"], "TASK-1")

    def test_assignment_check_ignores_cancelled_todos(self):
        with self.assertRaises(Denied):
            self.run_save()
        doctype, filters = self.frappe.db.exists.call_args.args
        self.assertEqual(doctype, "ToDo")
        self.assertEqual(filters["allocated_to"], "sales@example.test")
        self.assertEqual(filters["status"], ["!=", "Cancelled"])
        self.frappe.has_permission.assert_called_once_with("Task", "write", "TASK-1")


if __name__ == "__main__":
    unittest.main()
