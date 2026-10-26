"""Custom Frappe app Python, NOT a restricted Server Script.

Install as apps/itgenie/itgenie/fcm/fcm_utils.py. Place the private credential
beside this file as automategenie-service-account.json and exclude it from Git.
This module handles EVENT_ASSIGNED only; existing notification senders stay intact.
"""

import json
from pathlib import Path
from threading import Lock

import firebase_admin
from firebase_admin import credentials, messaging
import frappe


PROJECT_ID = "automategenie-mobile"
_APP_LOCK = Lock()


def get_firebase_app():
    """Use a site-specific named app without changing the default Firebase app."""
    app_name = PROJECT_ID + ":" + str(frappe.local.site)
    with _APP_LOCK:
        try:
            app = firebase_admin.get_app(app_name)
        except ValueError:
            credential_path = Path(__file__).with_name(
                "automategenie-service-account.json"
            )
            credential = credentials.Certificate(str(credential_path))
            if credential.project_id != PROJECT_ID:
                raise ValueError("Credential must belong to automategenie-mobile")
            app = firebase_admin.initialize_app(
                credential,
                options={"projectId": PROJECT_ID, "httpTimeout": 10},
                name=app_name,
            )
        if app.project_id != PROJECT_ID:
            raise ValueError("Unexpected Firebase project configuration")
        return app


@frappe.whitelist(methods=["POST"])
def send_fcm_to_user(user, payload):
    """Send a verified Event assignment to its assignee's latest active device.

Works with mobile_site_visit's existing frappe.call during its POST request.
Client-supplied titles/bodies are discarded; message content comes from Event.
No device tokens, session bindings, existing hooks, or Event data are changed.
"""
    current_user = frappe.session.user
    if not current_user or current_user == "Guest":
        frappe.throw("Sign in to send an Event alert.", frappe.PermissionError)

    if isinstance(payload, str):
        if len(payload) > 8192:
            frappe.throw("Invalid Event alert payload.")
        try:
            payload = json.loads(payload)
        except (TypeError, ValueError):
            frappe.throw("Invalid Event alert payload.")
    if not isinstance(payload, dict):
        frappe.throw("Invalid Event alert payload.")
    if payload.get("type") != "EVENT_ASSIGNED" or payload.get("doctype") != "Event":
        frappe.throw("This sender accepts Event assignment alerts only.")

    parameters = [user, payload.get("docname"), payload.get("assignment_id")]
    if any(not isinstance(value, str) or not value.strip() or len(value) > 140
           for value in parameters):
        frappe.throw("Recipient, Event and assignment ID are required.")
    user, event_id, assignment_id = [value.strip() for value in parameters]
    if user == "Guest" or payload.get("for_user") != user:
        frappe.throw("Invalid Event alert recipient.")

    event = frappe.get_doc("Event", event_id)
    # mobile_site_visit inserts the Event as its authenticated owner. Other
    # callers must have document-level write permission to this specific Event.
    if event.owner != current_user:
        event.check_permission("write")

    assignment = frappe.db.get_value(
        "ToDo", assignment_id,
        ["reference_type", "reference_name", "allocated_to", "status"],
        as_dict=True,
    )
    if (not assignment or assignment.reference_type != "Event"
            or assignment.reference_name != event.name
            or assignment.allocated_to != user or assignment.status != "Open"):
        frappe.throw("The recipient has no matching open Event assignment.")
    if event.docstatus == 2 or event.get("status") in ["Closed", "Completed", "Cancelled"]:
        return {"status": "failed", "message": "Event is no longer active"}
    if not frappe.db.get_value("User", user, "enabled"):
        return {"status": "failed", "message": "Recipient is disabled or missing"}

    devices = frappe.get_all(
        "FCM Device",
        filters={"user": user, "is_active": 1},
        fields=["fcm_token"], order_by="modified desc, name desc",
        limit_page_length=1,
    )
    token = devices[0].get("fcm_token") if devices else None
    if not isinstance(token, str) or not token.strip():
        frappe.log_error(
            title="FCM Token Missing",
            message="No active device token for the assignee of Event " + event.name,
        )
        return {"status": "failed", "message": "No active device token"}

    # Decide from the assignee's current ERP roles, never the caller's roles
    # or a client-supplied flag. Everyone still receives the visual push.
    alarm_enabled = bool(frappe.db.exists(
        "Has Role",
        {"parent": user, "parenttype": "User", "parentfield": "roles",
         "role": ["in", ["Sales User", "Designer"]]},
    ))
    data = {
        "type": "EVENT_ASSIGNED",
        "doctype": "Event",
        "docname": event.name,
        "assignment_id": assignment_id,
        "for_user": user,
        "alarm_enabled": "1" if alarm_enabled else "0",
        "title": "New event assigned",
        "body": str(event.get("subject") or event.name)[:240],
    }
    try:
        app = get_firebase_app()
        message = messaging.Message(
            token=token.strip(), data=data,
            android=messaging.AndroidConfig(priority="high"),
        )
        response = messaging.send(message, app=app)
        frappe.log_error(title="FCM Push Response", message=str(response))
        return {"status": "sent", "response": response}
    except Exception as error:
        # Do not log traceback locals or SDK error text containing device tokens.
        frappe.log_error(
            title="FCM Push Failed",
            message="Event " + event.name + "; project " + PROJECT_ID
            + "; error " + type(error).__name__,
        )
        return {"status": "failed", "message": "FCM sending failed; check FCM Push Failed"}
