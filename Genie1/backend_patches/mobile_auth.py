"""Permanent installation binding for the custom Frappe app (not Safe Exec).

Deploy to apps/itgenie/itgenie/mobile_auth.py; run install() before replacing api.login.
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

DOCTYPE = "FCM Device"
HASH_FIELD = "custom_mobile_device_hash"
SESSION_FIELD = "custom_mobile_session_id"
DEVICE_PATTERN = re.compile(r"^[A-Za-z0-9_-]{43}$")


def install():
    """Add protected fields to the existing FCM Device; never create a DocType.

    No legacy Genie Mobile Session records are read, copied or deleted.
    Run from bench as Administrator during the backend rollout.
    """
    from frappe.custom.doctype.custom_field.custom_field import create_custom_fields

    frappe.only_for("System Manager")
    if not frappe.db.exists("DocType", DOCTYPE):
        frappe.throw("FCM Device must already exist.", frappe.ValidationError)
    meta = frappe.get_meta(DOCTYPE)
    for name in ("user", "employee", "fcm_token", "is_active"):
        if not meta.has_field(name):
            frappe.throw("FCM Device schema is missing: " + name, frappe.ValidationError)
    # Hidden/read-only alone do not prevent API reads. No existing role is
    # granted permission level 1; ordinary FCM readers cannot see these fields.
    if any(p.permlevel == 1 for p in meta.permissions):
        frappe.throw("Review FCM Device permission level 1 before installation.", frappe.ValidationError)
    for name in (HASH_FIELD, SESSION_FIELD):
        field = meta.get_field(name)
        if field and field.fieldtype != "Data":
            frappe.throw("Unexpected mobile login field type: " + name, frappe.ValidationError)
    create_custom_fields({DOCTYPE: [
        {"fieldname": HASH_FIELD, "label": "Mobile Installation Hash",
         "fieldtype": "Data", "length": 64, "insert_after": "device_id",
         "hidden": 1, "read_only": 1, "permlevel": 1, "no_copy": 1, "reqd": 0},
        {"fieldname": SESSION_FIELD, "label": "Mobile Session ID",
         "fieldtype": "Data", "length": 255, "insert_after": HASH_FIELD,
         "hidden": 1, "read_only": 1, "permlevel": 1, "no_copy": 1, "reqd": 0},
    ]})
    frappe.db.commit()


def _setup_ready():
    if not frappe.db.exists("DocType", DOCTYPE):
        return False
    meta = frappe.get_meta(DOCTYPE)
    return all(meta.has_field(name) for name in (HASH_FIELD, SESSION_FIELD))


def _binding(user):
    # FCM Device is named by Employee, not by User. Reject ambiguous mappings.
    rows = frappe.get_all(
        DOCTYPE, filters={"user": user},
        fields=["name", "employee", HASH_FIELD, SESSION_FIELD], limit_page_length=2,
    )
    if len(rows) > 1:
        frappe.throw("Multiple FCM Device records are linked to this user. Contact your administrator.",
                     frappe.ValidationError)
    if not rows:
        return None
    row = rows[0]
    return {"name": row.name, "employee": row.employee,
            "device_hash": row.get(HASH_FIELD), "session_id": row.get(SESSION_FIELD)}


def _save_binding(user, employee, device_hash, sid, binding, platform=None):
    # Serialize first-row creation with register_device(), including requests
    # authenticated before the API secret was rotated by this login.
    frappe.db.get_value("Employee", employee, "name", for_update=True)
    existing = frappe.db.get_value(
        DOCTYPE, {"employee": employee}, ["name", "user", "platform"], as_dict=True, for_update=True,
    )
    if existing and existing.user not in (None, "", user):
        frappe.throw("FCM Device belongs to another user. Contact your administrator.", frappe.ValidationError)
    if binding and (not existing or existing.name != binding["name"]):
        frappe.throw("FCM Device Employee mapping changed. Contact your administrator.", frappe.ValidationError)
    values = {"user": user, HASH_FIELD: device_hash, SESSION_FIELD: sid}
    # Use the validated platform reported by this login. This also repairs
    # previously blank or incorrect values before FCM registration runs.
    if platform is not None:
        values["platform"] = platform
    elif not existing or not existing.platform:
        # Compatibility for older Android builds that omit this new parameter.
        values["platform"] = "android"
    if not binding or not binding["device_hash"]:
        # Old notification tokens must not be active for a newly claimed phone.
        # Registration restores the current token and is_active after login.
        values["is_active"] = 0
    if existing:
        # Preserve notification token and version metadata.
        frappe.db.set_value(DOCTYPE, existing.name, values)
    else:
        frappe.get_doc({"doctype": DOCTYPE, "employee": employee, **values}).insert(
            ignore_permissions=True,
        )


def _device_hash(device_key):
    if not isinstance(device_key, str) or not DEVICE_PATTERN.fullmatch(device_key):
        frappe.throw("Update the Genie app before signing in.", frappe.ValidationError)
    return hashlib.sha256(device_key.encode()).hexdigest()


@contextmanager
def _binding_lock(identity, namespace="genie"):
    # Connection-scoped MariaDB mutex: unlike SELECT FOR UPDATE it survives
    # the commits in Session.start(), session cleanup, and CSRF initialization.
    name = hashlib.sha256((frappe.local.site + ":" + namespace + ":" + identity).encode()).hexdigest()
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


def _user_lock(user):
    # Preserve the established user-lock name for existing deployments.
    return _binding_lock(user)


def _device_lock(device_hash):
    # Two different users claiming one installation must also serialize.
    return _binding_lock(device_hash, namespace="genie-device")


def _error(message, code):
    frappe.local.response["http_status_code"] = code
    frappe.local.response["message"] = {"key": 0, "message": message}


def _revoke_session(sid, user):
    if sid and sid != "Guest":
        delete_session(sid, user=user, reason="Genie mobile sign out")


def login(usr, pwd, device_key=None, platform=None):
    """Called only through api.login. Passwords are checked before lock details."""
    device_hash = _device_hash(device_key)
    if platform is not None:
        if not isinstance(platform, str):
            frappe.throw("Invalid mobile platform.", frappe.ValidationError)
        platform = platform.strip().lower()
        if platform not in ("android", "ios"):
            frappe.throw("Platform must be android or ios.", frappe.ValidationError)
    manager = LoginManager()
    manager.authenticate(usr, pwd)
    user = manager.user  # Canonical ID, including logins using Employee/User aliases.
    if not _setup_ready():
        return _error("Mobile login setup is incomplete. Contact your administrator.", 503)
    # Always take the device lock first. Logout/reset take only the user lock;
    # neither waits on a device lock while holding a user lock.
    with _device_lock(device_hash), _user_lock(user):
        # Read after mutex acquisition; don't use a stale cached document.
        binding = _binding(user)
        if binding and binding["device_hash"] and not hmac.compare_digest(binding["device_hash"], device_hash):
            return _error("Wrong User", 409)
        other_device = frappe.get_all(
            DOCTYPE,
            filters={HASH_FIELD: device_hash, "user": ["!=", user]},
            fields=["name"], limit_page_length=1,
        )
        if other_device:
            return _error("Wrong User", 409)
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
            if not binding or not binding["device_hash"] or not account.api_key or not secret:
                if not account.api_key:
                    account.api_key = frappe.generate_hash(length=15)
                # Keep the generated value separately: Frappe masks Password
                # fields on the document during save (e.g. "********").
                secret = frappe.generate_hash(length=32)
                account.api_secret = secret
                account.save(ignore_permissions=True)
            _save_binding(user, employee.name, device_hash, sid, binding, platform=platform)
            frappe.db.commit()
        except Exception:
            frappe.db.rollback()
            _revoke_session(sid, user)
            raise
        if binding and binding["session_id"] != sid:
            _revoke_session(binding["session_id"], user)
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
    the bearer credential. A different phone cannot sign this account out.
    Logout revokes the session/token but retains permanent device ownership.
    A repeated logout with no active SID is idempotent.
    """
    device_hash = _device_hash(device_key)
    if not isinstance(user, str) or not user or len(user) > 140:
        frappe.throw("Invalid user.", frappe.ValidationError)
    if not _setup_ready():
        return _error("Mobile login setup is incomplete. Contact your administrator.", 503)
    with _user_lock(user):
        binding = _binding(user)
        if binding and binding["device_hash"]:
            if not hmac.compare_digest(binding["device_hash"], device_hash):
                return _error("This phone cannot sign out that account.", 403)
            _release(user, binding)
    frappe.local.response["message"] = {"status": "success"}


def _release(user, binding, clear_binding=False):
    if not binding["session_id"] and not clear_binding:
        return
    # Revoke the token too: merely deleting an SID leaves API-token calls valid.
    account = frappe.get_doc("User", user)
    account.api_secret = frappe.generate_hash(length=32)
    account.save(ignore_permissions=True)
    _revoke_session(binding["session_id"], user)
    # Normal logout keeps ownership. Only the administrator reset clears it.
    values = {SESSION_FIELD: None, "is_active": 0}
    if clear_binding:
        values[HASH_FIELD] = None
        # Permit the approved replacement's first notification registration.
        # Keep the FCM token/version metadata, with delivery disabled above.
        values["device_id"] = None
    frappe.db.set_value(DOCTYPE, binding["name"], values)
    frappe.db.commit()


def reset_device(user):
    """Administrator console recovery for a lost/reinstalled phone; never whitelist."""
    frappe.only_for("System Manager")
    with _user_lock(user):
        binding = _binding(user)
        if binding and binding["device_hash"]:
            _release(user, binding, clear_binding=True)
