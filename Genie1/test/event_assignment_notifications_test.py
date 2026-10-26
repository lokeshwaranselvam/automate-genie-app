"""Local tests for the custom app Event-assignment hook (no live Frappe/FCM)."""
import importlib.util
from pathlib import Path
import sys
from types import ModuleType
import unittest
from unittest.mock import Mock, patch


class Row(dict):
    __getattr__ = dict.get


class EventAssignmentTests(unittest.TestCase):
    def setUp(self):
        self.frappe = ModuleType("frappe")
        self.frappe.enqueue = Mock()
        self.frappe.log_error = Mock()
        self.frappe.get_traceback = Mock(return_value="traceback")
        self.frappe.db = Mock()
        self.sender = ModuleType("itgenie.lead_calling.fcm_utils")
        self.sender.send_fcm_to_user = Mock(return_value={"status": "sent"})
        path = Path(__file__).resolve().parents[1] / "backend_patches/event_assignment_notifications.py"
        spec = importlib.util.spec_from_file_location("event_assignment_hook", path)
        self.module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {"frappe": self.frappe, "itgenie.lead_calling.fcm_utils": self.sender}):
            spec.loader.exec_module(self.module)
        self.todo = Row(name="TODO-1", reference_type="Event", reference_name="EVENT-1",
                        allocated_to="designer@example.test", status="Open")
        self.event = Row(name="EVENT-1", subject="Measurement visit", status="Open", docstatus=0)

    def test_new_event_assignment_enqueues_only_after_transaction_commit(self):
        self.module.on_event_assignment(self.todo)
        self.frappe.enqueue.assert_called_once_with(
            "itgenie.lead_calling.event_assignment_notifications.send_event_assignment_alarm",
            queue="short", enqueue_after_commit=True, todo_name="TODO-1")
        self.sender.send_fcm_to_user.assert_not_called()

    def test_non_event_or_incomplete_assignments_do_not_enqueue(self):
        for changes in [{"reference_type": "Task"}, {"status": "Closed"},
                        {"allocated_to": ""}, {"reference_name": ""}]:
            self.module.on_event_assignment(Row(self.todo, **changes))
        self.frappe.enqueue.assert_not_called()

    def test_queue_outage_does_not_break_the_assignment(self):
        self.frappe.enqueue.side_effect = RuntimeError("Redis unavailable")
        self.module.on_event_assignment(self.todo)
        self.frappe.log_error.assert_called_once()

    def test_worker_sends_only_to_current_assignee_with_stable_assignment_identity(self):
        self.frappe.db.get_value.side_effect = [self.todo, 1, self.event]
        self.assertEqual(self.module.send_event_assignment_alarm("TODO-1"), {"status": "sent"})
        user, payload = self.sender.send_fcm_to_user.call_args.args
        self.assertEqual(user, "designer@example.test")
        self.assertEqual(payload, dict(type="EVENT_ASSIGNED", doctype="Event", docname="EVENT-1",
            assignment_id="TODO-1", for_user="designer@example.test", title="New event assigned", body="Measurement visit"))
        self.frappe.db.get_value.assert_any_call("User", "designer@example.test", "enabled")

    def test_worker_skips_removed_or_cancelled_assignments_and_disabled_users(self):
        for todo, enabled, event in [
            (None, 1, self.event), (Row(self.todo, status="Cancelled"), 1, self.event),
            (Row(self.todo, reference_type="Task"), 1, self.event),
            (self.todo, 0, self.event), (self.todo, 1, None),
            (self.todo, 1, Row(self.event, docstatus=2)),
            (self.todo, 1, Row(self.event, status="Completed")),
        ]:
            self.frappe.db.get_value.side_effect = [todo, enabled, event]
            self.module.send_event_assignment_alarm("TODO-1")
        self.sender.send_fcm_to_user.assert_not_called()


if __name__ == "__main__":
    unittest.main()
