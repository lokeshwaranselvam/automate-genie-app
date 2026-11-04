"""Custom app Python, not a restricted Frappe Server Script.

Install as itgenie/lead_calling/event_assignment_notifications.py and merge
on_event_assignment into the ToDo.after_insert hook. Other hooks are unchanged.
"""
import frappe

from itgenie.lead_calling.fcm_utils import send_fcm_to_user


def on_event_assignment(doc, method=None):
    if (doc.get("reference_type") != "Event" or doc.get("status") != "Open"
            or not doc.get("allocated_to") or not doc.get("reference_name")):
        return
    try:
        # The worker must see the committed ToDo and Event, including mobile
        # creation transactions that have not finished when after_insert runs.
        frappe.enqueue(
            "itgenie.lead_calling.event_assignment_notifications.send_event_assignment_alarm",
            queue="short", enqueue_after_commit=True, todo_name=doc.name,
        )
    except Exception:
        # Notification infrastructure must not roll back an Event assignment.
        frappe.log_error(title="Event assignment alarm enqueue failed", message=frappe.get_traceback())


def send_event_assignment_alarm(todo_name):
    todo = frappe.db.get_value("ToDo", todo_name,
        ["name", "reference_type", "reference_name", "allocated_to", "status"], as_dict=True)
    if not todo or todo.reference_type != "Event" or todo.status != "Open":
        return
    user = todo.allocated_to
    if not user or user == "Guest" or not frappe.db.get_value("User", user, "enabled"):
        return
    event = frappe.db.get_value("Event", todo.reference_name,
        ["name", "subject", "status", "docstatus"], as_dict=True)
    if not event or event.status != "Open" or event.docstatus == 2:
        return
    return send_fcm_to_user(user, {
        "type": "EVENT_ASSIGNED",
        "doctype": "Event",
        "docname": event.name,
        "assignment_id": todo.name,
        "for_user": user,
        "title": "New event assigned",
        "body": event.subject or event.name,
    })
