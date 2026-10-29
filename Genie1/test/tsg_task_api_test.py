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


class Session(dict):
    __getattr__ = dict.get


class TsgTaskCompleteAndGetTest(unittest.TestCase):
    def frappe(self, form_dict):
        return SimpleNamespace(
            form_dict=form_dict, response={},
            session=Session(user="sales@example.test", csrf_token="", data=SimpleNamespace(csrf_token="csrf-1")),
            db=SimpleNamespace(exists=Mock(return_value=None), sql=Mock(return_value=[])),
            get_doc=Mock(return_value=SimpleNamespace(name="TASK-1", save=Mock())),
            throw=Mock(side_effect=lambda message, exc=None: (_ for _ in ()).throw(Denied(message))),
            utils=SimpleNamespace(today=lambda: "2026-10-29", add_days=lambda d, n: d,
                                  get_first_day=lambda d, as_str=False: d, strip_html_tags=lambda v: v),
        )

    def test_cancelled_assignment_cannot_complete_task(self):
        frappe = self.frappe({"action": "complete", "task_id": "TASK-1"})
        with self.assertRaises(Denied):
            exec(compile(SCRIPT, "tsg_task_api.py", "exec"), {"frappe": frappe})
        doctype, filters = frappe.db.exists.call_args.args
        self.assertEqual(doctype, "ToDo")
        self.assertEqual(filters["status"], ["!=", "Cancelled"])
        frappe.get_doc.return_value.save.assert_not_called()

    def test_get_returns_session_csrf_token_without_sessions_module(self):
        frappe = self.frappe({"action": "get", "all_data": "1"})
        exec(compile(SCRIPT, "tsg_task_api.py", "exec"), {"frappe": frappe})
        self.assertEqual(frappe.response["message"]["csrf_token"], "csrf-1")


class MyAssignedTasksCompleteTest(unittest.TestCase):
    def test_cancelled_todo_does_not_count_as_assignment(self):
        script = (Path(__file__).resolve().parents[1] / "frappe_server_scripts" / "my_assigned_tasks_api.py").read_text(encoding="utf-8")
        frappe = SimpleNamespace(
            form_dict={"action": "complete", "task_id": "TASK-1"}, response={},
            session=SimpleNamespace(user="sales@example.test"),
            db=SimpleNamespace(sql=Mock(return_value=[])), get_doc=Mock(),
            throw=Mock(side_effect=lambda message: (_ for _ in ()).throw(Denied(message))),
        )
        with self.assertRaisesRegex(Denied, "assigned to your user"):
            exec(compile(script, "my_assigned_tasks_api.py", "exec"), {"frappe": frappe})
        self.assertIn("assigned_todo.status != 'Cancelled'", frappe.db.sql.call_args.args[0])
        frappe.get_doc.assert_not_called()


if __name__ == "__main__":
    unittest.main()
