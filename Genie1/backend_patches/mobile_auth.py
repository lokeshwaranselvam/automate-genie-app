"""Single-installation mobile login for the custom Frappe app (not Safe Exec).

Install beside utils/api.py; run install() once before replacing api.login.
MariaDB advisory locks intentionally survive commits made inside Frappe login.
"""
from contextlib import contextmanager
import hashlib
import hmac
import re

import frappe
from frappe.auth import LoginManager
from frappe.sessions import delete_session
from frappe.utils.password import get_decrypted_password

DOCTYPE = "Genie Mobile Session"
DEVICE_PATTERN = re.compile(r"^[A-Za-z0-9_-]{43}$")


def install():
    """Run from bench console/execute as Administrator, not as a public API."""
    frappe.only_for("System Manager")
    if not frappe.db.exists("DocType", DOCTYPE):
        frappe.get_doc({
            "doctype": "DocType", "name": DOCTYPE, "module": "Custom",
            "custom": 1, "autoname": "field:user", "track_changes": 0,
            "fields": [
                {"fieldname": "user", "label": "User", "fieldtype": "Link",
                 "options": "User", "reqd": 1, "unique": 1},
                {"fieldname": "device_hash", "label": "Installation Hash",
                 "fieldtype": "Data", "reqd": 1, "read_only": 1},
                {"fieldname": "session_id", "label": "Session",
                 "fieldtype": "Data", "hidden": 1},
            ],
            # Ordinary users cannot read or modify installation credentials.
            "permissions": [{"role": "System Manager", "read": 1}],
        }).insert(ignore_permissions=True)
    frappe.db.commit()


def _device_hash(device_key):
    if not isinstance(device_key, str) or not DEVICE_PATTERN.fullmatch(device_key):
        frappe.throw("Update the Genie app before signing in.", frappe.ValidationError)
    return hashlib.sha256(device_key.encode()).hexdigest()


@contextmanager
def _user_lock(user):
    # Connection-scoped MariaDB mutex: unlike SELECT FOR UPDATE it survives
    # the commits in Session.start(), session cleanup, and CSRF initialization.
    name = hashlib.sha256((frappe.local.site + ":genie:" + user).encode()).hexdigest()
    result = frappe.db.sql("SELECT GET_LOCK(%s, 10)", (name,))
    if not result or result[0][0] != 1:
        frappe.throw("Another sign-in is being processed. Please retry.", frappe.ValidationError)
    try:
        # Authentication may already have opened a repeatable-read snapshot.
        # Discard it so a waiter sees the preceding login's committed binding.
        frappe.db.commit()
        yield
    finally:
        frappe.db.sql("SELECT RELEASE_LOCK(%s)", (name,))


def _error(message, code):
    frappe.local.response["http_status_code"] = code
    frappe.local.response["message"] = {"key": 0, "message": message}


def _revoke_session(sid, user):
    if sid and sid != "Guest":
        delete_session(sid, user=user, reason="Genie mobile sign out")


def login(usr, pwd, device_key=None):
    """Called only through api.login. Passwords are checked before lock details."""
    device_hash = _device_hash(device_key)
    manager = LoginManager()
    manager.authenticate(usr, pwd)
    user = manager.user  # Canonical ID, including logins using Employee/User aliases.
    if not frappe.db.exists("DocType", DOCTYPE):
        return _error("Mobile login setup is incomplete. Contact your administrator.", 503)
    with _user_lock(user):
        # Read after mutex acquisition; don't use a stale cached document.
        binding = frappe.db.get_value(
            DOCTYPE, user, ["device_hash", "session_id"], as_dict=True,
        )
        if binding and not hmac.compare_digest(binding.device_hash, device_hash):
            return _error(
                "This account is already signed in on another phone. "
                "Log out from that phone first, then sign in here.", 409,
            )
        employees = frappe.get_all(
            "Employee", filters={"user_id": user, "status": "Active"},
            fields=["name"], limit_page_length=2,
        )
        if len(employees) != 1:
            return _error("An active Employee profile is required. Contact your administrator.", 403)
        # The mapping is a Child Table, not a column on tabEmployee.
        # Load its rows through the document, matching the existing API.
        employee = frappe.get_doc("Employee", employees[0].name)
        if not employee.custom_office_type_mapping:
            return _error("Access Denied: No office type mapped to your profile.", 403)

        # Use Frappe's full login flow, including password policy, 2FA and IP/hour
        # checks. A rejected second phone never reaches session creation.
        if manager.login() is False:
            return
        if frappe.session.user != user or frappe.session.sid == "Guest":
            return _error("Sign-in was not completed. Please retry.", 401)
        sid = frappe.session.sid
        try:
            account = frappe.get_doc("User", user)
            secret = get_decrypted_password("User", user, "api_secret", raise_exception=False)
            # Rotate on a NEW claim, never on a same-installation retry. An old
            # build/token from before this rollout cannot retain API access.
            if not binding or not account.api_key or not secret:
                if not account.api_key:
                    account.api_key = frappe.generate_hash(length=15)
                # Keep the generated value separately: Frappe masks Password
                # fields on the document during save (e.g. "********").
                secret = frappe.generate_hash(length=32)
                account.api_secret = secret
                account.save(ignore_permissions=True)
            if binding:
                frappe.db.set_value(DOCTYPE, user, "session_id", sid)
            else:
                frappe.get_doc({
                    "doctype": DOCTYPE, "user": user,
                    "device_hash": device_hash, "session_id": sid,
                }).insert(ignore_permissions=True)
            frappe.db.commit()
        except Exception:
            frappe.db.rollback()
            _revoke_session(sid, user)
            raise
        if binding and binding.session_id != sid:
            _revoke_session(binding.session_id, user)
        frappe.local.response.update({
            "message": "Logged In", "email": user, "full_name": account.full_name,
            "name": account.full_name, "employee_id": employee.name,
            "token": "token " + account.api_key + ":" + secret,
            "api_key": account.api_key, "api_secret": secret,
            "single_device_login": True,
        })


def logout(user, device_key):
    """A 256-bit installation credential allows logout even after SID expiry.

    The app calls this without cookies or API headers; the installation key is
    the bearer credential. A different phone cannot release someone else's lock.
    The empty-row case is idempotent for a lost logout response.
    """
    device_hash = _device_hash(device_key)
    if not isinstance(user, str) or not user or len(user) > 140:
        frappe.throw("Invalid user.", frappe.ValidationError)
    with _user_lock(user):
        binding = frappe.db.get_value(
            DOCTYPE, user, ["device_hash", "session_id"], as_dict=True,
        )
        if binding:
            if not hmac.compare_digest(binding.device_hash, device_hash):
                return _error("This phone cannot sign out that account.", 403)
            _release(user, binding.session_id)
    frappe.local.response["message"] = {"status": "success"}


def _release(user, sid):
    # Revoke the token too: merely deleting an SID leaves API-token calls valid.
    account = frappe.get_doc("User", user)
    account.api_secret = frappe.generate_hash(length=32)
    account.save(ignore_permissions=True)
    _revoke_session(sid, user)
    frappe.db.delete(DOCTYPE, {"name": user})
    frappe.db.commit()


def reset_device(user):
    """Administrator console recovery for a lost/reinstalled phone; never whitelist."""
    frappe.only_for("System Manager")
    with _user_lock(user):
        sid = frappe.db.get_value(DOCTYPE, user, "session_id")
        if sid:
            _release(user, sid)
