"""Role guard for Frappe-served pages (custom app Python, NOT Server Script).

Deploy as apps/itgenie/itgenie/pwa_page_access.py and register both hooks.
Edit PROTECTED_PAGES and ALLOWED_ROLES before enabling the hooks.
This policy applies to every browser, including PWA and Android WebViews.
Static files served by Nginx and unlisted API endpoints are outside its scope.
"""

import posixpath
from urllib.parse import urlsplit

import frappe


SITE_HOST = "erp.homegeniegroup.in"  # Change to your site host (no scheme, no port, no trailing slash).

# Add actual page paths OR full URLs on SITE_HOST. Examples:
PROTECTED_PAGES = [
      "https://erp.homegeniegroup.in/AGpwa/",
    # "https://erp.homegeniegroup.in/expense-claim",
]

# Exact, case-sensitive Frappe Role names. ANY one role grants access.
ALLOWED_ROLES = [
    "IOS User",
]

ACCESS_DENIED_MESSAGE = (
    "Access denied. You do not have permission to access this page. "
    "Please contact your administrator for help."
)


def _normalise_path(path):
    # request.path is already URL-decoded by Werkzeug. Ignore trailing slashes.
    return "/" + posixpath.normpath("/" + path.lstrip("/")).lstrip("/")


def _protected_paths():
    paths = set()
    for entry in PROTECTED_PAGES:
        if not isinstance(entry, str) or not entry.strip():
            raise ValueError("PROTECTED_PAGES must contain nonempty paths or URLs.")
        entry = entry.strip()
        parsed = urlsplit(entry)
        if parsed.scheme or parsed.netloc:
            if (
                parsed.scheme not in ("http", "https")
                or parsed.hostname != SITE_HOST
                or parsed.username is not None
                or parsed.password is not None
                or parsed.port not in (None, 80, 443)
            ):
                raise ValueError("Protected URLs must belong to " + SITE_HOST)
        elif not entry.startswith("/") or entry.startswith("//"):
            raise ValueError("Protected page paths must start with a single '/'.")
        if parsed.query or parsed.fragment:
            raise ValueError("Use the page URL without a query string or fragment.")
        paths.add(_normalise_path(parsed.path))
    return paths


def before_request():
    """Deny protected requests before Frappe renders even a cached page."""
    request = getattr(frappe.local, "request", None)
    if request is None or request.method == "OPTIONS" or not PROTECTED_PAGES:
        return

    if _normalise_path(request.path) not in _protected_paths():
        return

    # Also mark denied responses so after_request prevents HTTP caching.
    frappe.local.pwa_page_access_protected = True
    user = frappe.session.user
    if not user or user == "Guest":
        frappe.throw(ACCESS_DENIED_MESSAGE, frappe.PermissionError)

    if not set(ALLOWED_ROLES).intersection(frappe.get_roles(user)):
        frappe.throw(ACCESS_DENIED_MESSAGE, frappe.PermissionError)


def after_request(response):
    """Keep role-dependent page responses out of browser/proxy HTTP caches."""
    if response is not None and getattr(
        frappe.local, "pwa_page_access_protected", False
    ):
        response.headers["Cache-Control"] = "private, no-store, max-age=0"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
