"""Custom Frappe app Python, NOT a restricted Server Script.

Install as apps/itgenie/itgenie/fcm/fcm_utils.py. Place the private credential
beside this file as automategenie-service-account.json and exclude it from Git.
FCM Notification rules use a trusted, after-commit worker. Generic deliveries
cannot be invoked over HTTP. No DocType-specific payload builders are used.
"""

import json
import hashlib
import inspect
from importlib import import_module
from contextvars import ContextVar
from pathlib import Path
from threading import Lock

import firebase_admin
from firebase_admin import credentials, messaging
import frappe


PROJECT_ID = "automategenie-mobile"
_APP_LOCK = Lock()
_NOTIFICATION_DISPATCH = ContextVar("genie_fcm_notification_dispatch", default=None)


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


def send_fcm_to_user(user, payload):
    """Internal sender for generic Notification payloads, never a public API."""
    if isinstance(payload, str):
        if len(payload) > 8192:
            frappe.throw("Invalid FCM notification payload.")
        try:
            payload = json.loads(payload)
        except (TypeError, ValueError):
            frappe.throw("Invalid FCM notification payload.")
    if not isinstance(payload, dict) or payload.get("type") != "DOCUMENT_NOTIFICATION":
        frappe.throw("Only generic DOCUMENT_NOTIFICATION payloads are supported.")
    return _send_document_notification(user, payload)


class FCMNotificationMixin:
    """Shared override channel behavior. Other channels use super()."""

    def send(self, doc):
        # Older v15 dispatches its built-in channels directly inside send(),
        # without ever calling send_notification_by_channel(). On newer builds
        # let the native send() reach our channel handler, avoiding two jobs.
        if self.get("channel") != "FCM" or callable(
            getattr(super(), "send_notification_by_channel", None)
        ):
            return super().send(doc)
        if not self.get("enabled") or self.get("event") == "Custom":
            return
        self._enqueue_fcm_notification(doc)
        # Keep v15's standard context, optional ERP bell and property-after-alert
        # handling. Its built-in channel switch does not send FCM itself.
        return super().send(doc)

    def validate(self):
        if self.get("channel") == "FCM":
            from frappe.utils.jinja import validate_template

            if self.get("event") == "Custom":
                frappe.throw("Manual/custom FCM notifications are not enabled.")
            if not (self.get("subject") or "").strip():
                frappe.throw("Subject is required for an FCM Notification.")
            if not (self.get("message") or "").strip():
                frappe.throw("Message is required for an FCM Notification.")
            validate_template(self.subject)
        return super().validate()

    def send_notification_by_channel(self, doc, context):
        if self.get("channel") != "FCM":
            return super().send_notification_by_channel(doc, context)
        if not self.get("enabled") or self.get("event") == "Custom":
            return
        self._enqueue_fcm_notification(doc)
        # Preserve the standard optional ERP bell notification.
        if self.get("send_system_notification"):
            try:
                self.create_system_notification(doc, context)
            except Exception as error:
                _log_notification_failure(self.name, type(error).__name__)

    def _enqueue_fcm_notification(self, doc):
        try:
            # Frappe already evaluated the Notification event and condition.
            frappe.enqueue(
                "itgenie.fcm.fcm_utils.dispatch_document_notification",
                queue="default", timeout=600, enqueue_after_commit=True,
                notification_name=self.name, doctype=doc.doctype, docname=doc.name,
                document_version=str(doc.get("modified") or doc.get("creation") or ""),
            )
        except Exception as error:
            _log_notification_failure(self.name, type(error).__name__)


def _notification_context(rule, document):
    """Match the installed Notification implementation's template context."""
    notification_module = import_module("frappe.email.doctype.notification.notification")

    context = notification_module.get_context(document)
    comments_helper = getattr(notification_module, "get_comments_for_context", None)
    if callable(comments_helper):
        comments = comments_helper(document)
    else:
        # v15.69.3 reads the document's existing _comments JSON in send().
        raw_comments = document.get("_comments")
        comments = json.loads(raw_comments) if raw_comments else None
    context.update({"doc": document, "alert": rule, "comments": comments})
    if rule.get("is_standard"):
        rule.load_standard_properties(context)
    return context


def dispatch_document_notification(notification_name, doctype, docname, document_version=""):
    """Internal queue target. Intentionally NOT whitelisted/public."""
    from frappe.utils.safe_exec import safe_exec

    rule = frappe.get_doc("Notification", notification_name)
    if not rule.get("enabled") or rule.get("channel") != "FCM" or rule.get("event") == "Custom":
        return {"status": "skipped"}
    if rule.get("document_type") != doctype:
        frappe.throw("Notification DocType mismatch.")
    document = frappe.get_doc(doctype, docname)
    script_name = frappe.db.get_value("Server Script", {
        "api_method": "mobile_fcm_notification", "script_type": "API", "disabled": 0,
    }, "name")
    if not script_name:
        _log_notification_failure(rule.name, "Generic Server Script missing or disabled")
        return {"status": "failed", "message": "Generic Server Script missing or disabled"}
    script = frappe.get_doc("Server Script", script_name)
    dispatch = {"rule": rule, "document": document, "version": document_version}
    marker = _NOTIFICATION_DISPATCH.set(dispatch)
    try:
        context = _notification_context(rule, document)
        # Pass the Python callable directly. Restricted frappe.call/safe_enqueue
        # may invoke HTTP-method checks in a worker where no request exists.
        execution = {"_locals": {"fcm_trigger": {
            "notification_name": rule.name, "doctype": doctype, "docname": docname,
            "context": context, "send_fcm_to_user": send_fcm_to_user,
            "render_template": render_notification_template,
        }}}
        if "script_filename" in inspect.signature(safe_exec).parameters:
            execution["script_filename"] = script.name
        scope, unused_locals = safe_exec(script.script, **execution)
        return scope["frappe"].flags.get("fcm_notification_result") or {"status": "processed"}
    except Exception as error:
        _log_notification_failure(rule.name, type(error).__name__)
        return {"status": "failed", "message": "FCM Notification dispatch failed"}
    finally:
        _NOTIFICATION_DISPATCH.reset(marker)


def render_notification_template(template, context):
    """Use restricted globals where supported, including v15 backports.

    Earlier v15 Jinja renderers use their standard sandbox and do not expose
    the restrict_globals keyword. Detect the signature instead of retrying a
    failed render (which could hide an actual template error).
    """
    if "restrict_globals" in inspect.signature(frappe.render_template).parameters:
        return frappe.render_template(template, context, restrict_globals=True)
    return frappe.render_template(template, context)


def _log_notification_failure(notification_name, error_name):
    # Do not log SDK messages, device tokens, rendered customer data or locals.
    frappe.log_error(title="FCM Notification dispatch failed",
        message="Notification " + str(notification_name) + "; " + str(error_name))


def _send_document_notification(user, payload):
    dispatch = _NOTIFICATION_DISPATCH.get()
    if not dispatch:
        frappe.throw("Generic notifications can only be sent by the Notification worker.", frappe.PermissionError)
    rule, document = dispatch["rule"], dispatch["document"]
    if not isinstance(user, str) or not user.strip() or len(user) > 140 or user == "Guest":
        frappe.throw("Invalid FCM recipient.")
    user = user.strip()
    if (payload.get("notification_name") != rule.name or payload.get("doctype") != document.doctype
            or payload.get("docname") != document.name or payload.get("for_user") != user):
        frappe.throw("FCM notification references do not match the trusted trigger.")
    if (not rule.get("enabled") or rule.get("channel") != "FCM"
            or rule.get("document_type") != document.doctype or rule.get("event") == "Custom"):
        return {"status": "skipped"}
    if not frappe.db.get_value("User", user, "enabled") or not document.has_permission("read", user=user):
        return {"status": "skipped", "message": "Recipient is disabled or has no document access"}
    if any(not isinstance(payload.get(key), str) or not payload[key].strip() for key in ["title", "body"]):
        frappe.throw("FCM title and body are required.")
    # Retry/duplicate protection per rule, document version and recipient.
    identity = json.dumps([str(frappe.local.site), rule.name, document.doctype, document.name,
        dispatch["version"], rule.get("event"), user], separators=(",", ":"))
    delivery_key = "genie_fcm_notification:" + hashlib.sha256(identity.encode()).hexdigest()
    cache = frappe.cache()
    with cache.lock(delivery_key + ":lock", timeout=30, blocking_timeout=5):
        if cache.get_value(delivery_key):
            return {"status": "skipped", "message": "Already accepted by FCM"}
        devices = frappe.get_all("FCM Device", filters={"user": user, "is_active": 1},
            fields=["fcm_token"], order_by="modified desc, name desc", limit_page_length=1)
        token = devices[0].get("fcm_token") if devices else None
        if not isinstance(token, str) or not token.strip():
            _log_notification_failure(rule.name, "No active device token")
            return {"status": "failed", "message": "No active device token"}
        alarm_enabled = bool(frappe.db.exists("Has Role", {
            "parent": user, "parenttype": "User", "parentfield": "roles",
            "role": ["in", ["Sales User", "Designer"]],
        }))
        data = {
            "type": "DOCUMENT_NOTIFICATION",
            "notification_name": rule.name,
            "doctype": document.doctype,
            "docname": document.name,
            "assignment_id": "",
            "for_user": user,
            "alarm_enabled": "1" if alarm_enabled else "0",
            "title": payload["title"].strip()[:200],
            "body": payload["body"].strip()[:240],
        }
        try:
            response = messaging.send(messaging.Message(token=token.strip(), data=data,
                android=messaging.AndroidConfig(priority="high")), app=get_firebase_app())
        except Exception as error:
            _log_notification_failure(rule.name, type(error).__name__)
            return {"status": "failed", "message": "FCM sending failed"}
        # Firebase acceptance is recorded; it is not proof of phone delivery.
        cache.set_value(delivery_key, str(response), expires_in_sec=86400)
        return {"status": "sent", "response": response}


def setup_fcm_notification_channel():
    """Run once from bench console as Administrator/System Manager, not HTTP."""
    frappe.only_for("System Manager")
    from frappe.custom.doctype.property_setter.property_setter import make_property_setter

    meta = frappe.get_meta("Notification")
    channels = [value for value in (meta.get_field("channel").options or "").splitlines() if value]
    if "FCM" not in channels:
        channels.append("FCM")
        make_property_setter("Notification", "channel", "options", "\n".join(channels), "Text")
    for fieldname, property_name in [("subject", "depends_on"), ("subject", "mandatory_depends_on"), ("message", "depends_on")]:
        previous = meta.get_field(fieldname).get(property_name) or ""
        if "doc.channel == 'FCM'" in previous:
            continue
        if previous.startswith("eval:"):
            expression = "eval:doc.channel == 'FCM' or (" + previous[5:] + ")"
        elif previous:
            expression = "eval:doc.channel == 'FCM' or doc.get(" + json.dumps(previous) + ")"
        elif property_name == "mandatory_depends_on":
            expression = "eval:doc.channel == 'FCM'"
        else:
            continue
        make_property_setter("Notification", fieldname, property_name, expression, "Code")
    frappe.clear_cache(doctype="Notification")


def validate_fcm_notification_installation():
    """Console check after registration; detects another app masking the hook."""
    from frappe.model.base_document import get_controller

    controller = get_controller("Notification")
    if not issubclass(controller, FCMNotificationMixin):
        frappe.throw("The FCM Notification controller is not active. Check hooks and installed-app order.")
    return {"status": "ready", "controller": controller.__name__}
