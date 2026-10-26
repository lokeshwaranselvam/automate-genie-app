# Mobile business policy controlled by APIs

These are local changes. Deploy the Server Scripts before installing the updated
app, then rebuild/reinstall Flutter once. Later supported policy changes only
require editing the server settings and refreshing/reopening the relevant page.
No custom fields or DocTypes are introduced. Existing database records are not
migrated. The custom-app visit check-in/checkout methods now consult the same policy before writing. Apply only these method changes to the deployed module; do not replace unrelated custom-app functions.

## 1. mobile_site_visit (existing restricted API Server Script)

Replace the script with `frappe_server_scripts/mobile_site_visit_api.py`.
Retain API Method `mobile_site_visit`, Allow Guest disabled, and rate limiting.

The scheduling settings near the top preserve the current behavior:

```python
schedule_interval_minutes = 15
schedule_allow_past = False
schedule_earliest_booking_date = ""
```

An interval must be an integer between 1 and 60 that divides 60. The earliest
date is empty or `YYYY-MM-DD`. An empty value adds no extra minimum; disabling
past booking still requires today or later and prevents elapsed start times.
End must remain after start. `action=get` returns `schedule_policy`, and
`create_event` enforces the same configuration. Flutter uses it for the calendar,
slot list, interval hint, and validation. Older responses retain the legacy
15-minute/no-past-date defaults.

Tracking settings:

```python
tracking_allowed_roles = ["Sales User", "Designer"]
tracking_user_overrides = {}
```

`action=can_create` returns authenticated `current_user` and boolean `can_track`.
An optional `tracking_user_overrides` entry for an exact username overrides the
role decision. Flutter no longer chooses tracking roles. It still verifies the
session, requires attendance check-in for tracking, checks account changes, and
uses the existing one-minute eligibility cache. Native GPS, attendance, and
background service behavior are unchanged. Missing/failed/mismatched decisions
deny tracking, so deploy this API before the app update.

Visibility settings:

```python
feature_visibility_overrides = {}
feature_visibility_by_user = {}
```

`action=can_create` returns `feature_visibility`. Supported keys are `visits`,
`leads`, `schedule`, `opportunities`, `pending`, `add_lead`, `new_visit`, `tasks`,
`attendance`, `new_task`, `performance`, `dashboards`, `leave`, `expenses`, and
`canteen`. All existing defaults are retained, including Visits for everyone.

For example, to hide the expense menu for one account:

```python
feature_visibility_by_user = {
    "employee@example.com": {"expenses": False},
}
```

Visibility is separate from create/edit permissions. `can_create`,
`can_create_lead`, normal document permissions, and creation category restrictions
are unchanged. Home and sign-out remain available. Existing ERP-assigned external
web links retain their own permissions and configuration. A flag controls this
app's supported entry points, not access to ERP URLs outside the app.

## 2. event_visit_report (existing restricted API Server Script)

Replace the script with `frappe_server_scripts/event_visit_report_api.py` and
retain API Method `event_visit_report`, Allow Guest disabled, and rate limiting.

Report outcomes, form fields and editing rules are now defined in
`mobile_business_policy.py` under `visit_report`. Visit location, geofence,
photo and attendance settings are under `visit`. This endpoint reads those
settings and preserves its existing response keys, assignment checks, historical
OTP values, report storage and Event attachments. A retired outcome remains
visible on a saved report and does not unlock editing.

GET includes `business_policy.actions.edit` and `.submit`, each with `allowed`
and `reason`, alongside `is_submitted` and `can_edit_report`. The save path
checks the same decision. Native Event permissions and existing assignment
requirements remain in force.

## 3. mobile_opportunity_policy (new restricted API Server Script)

Create an API Server Script from `frappe_server_scripts/mobile_opportunity_policy.py`:
API Method `mobile_opportunity_policy`, Allow Guest disabled, rate limiting enabled.
GET `action=get` supplies policy; optional `name` checks the Opportunity Owner and
document read permission. POST `action=save` accepts `name`, `modified`, `changes`
(object or JSON), and session CSRF token.

Settings near the top:

```python
editable_statuses = [
    "Open", "Follow-up", "Demo", "VC", "Duplicate Lead", "Junk",
    "Not Interested", "Hot Followup", "RNR", "B2B Database",
]
status_transitions = {}
allow_past_followup = False
earliest_followup_date = ""
opportunity_policy_by_user = {}
```

Statuses are intersected with actual ERP Opportunity status options. A transition
map entry restricts the target statuses for that source status; an absent entry
retains the existing transitions among allowed statuses. User-specific policy
entries can override these four settings for the authenticated username:

```python
opportunity_policy_by_user = {
    "sales@example.com": {
        "editable_statuses": ["Open", "Follow-up"],
        "status_transitions": {"Open": ["Follow-up"]},
        "allow_past_followup": False,
        "earliest_followup_date": "",
    },
}
```

The earliest date is empty or `YYYY-MM-DD`; without past-date allowance the server
uses at least today's date. Existing requirements to select a valid date when
editing a document containing a follow-up date are retained.

Flutter still loads field metadata, owner-filtered/paginated list data, and
document details through the existing Frappe endpoints. Editable status choices,
status filters, allowed transitions, and the date picker come from policy.
Saving now uses this endpoint so the same rules are enforced server-side.
It preserves normal document write permissions, field-level filtering, document
hooks/workflows, stale-version rejection, unchanged sales stage for notes/date
edits, sales-stage synchronization on a status change, and note history payloads.
It accepts only status, notes, and the metadata-discovered follow-up Date field.
It never accepts an owner change or bypasses permissions.

The script has no imports or custom functions. It uses Safe Exec's `json.loads`
and permission-checked document methods (see the official
[Frappe Safe Exec globals](https://github.com/frappe/frappe/blob/v15.80.0/frappe/utils/safe_exec.py)
and [document permission methods](https://github.com/frappe/frappe/blob/v15.80.0/frappe/model/document.py)).
Session CSRF validation is explicit even on versions whose Safe Exec request
wrapper does not expose the HTTP method. The app always sends POST for saves.

These policies apply to the mobile endpoint. ERP's other interfaces retain
their normal permissions, workflows, and configured validations.

## 4. Shared mobile_business_policy (new restricted API Server Script)

Create an API Server Script using `frappe_server_scripts/mobile_business_policy.py`,
with API Method **mobile_business_policy**, Guest disabled. Configure a rate limit
appropriate for normal use: each form/save/upload can make several internal
policy calls. Frappe's default rate-limit count is too low for this shared endpoint.
The script has no imports or custom functions. It returns `message.policy` to an
HTTP caller and `{"policy": ...}` to another restricted script via `frappe.call`.
Nested calls explicitly specify `action` and clear irrelevant `event_id` values,
because Frappe merges parent form parameters into internal calls.

Change the `policies` dictionary to configure the supported fields and rules.
For an exact authenticated user, use `policy_by_user`; nested field settings merge
with defaults. No credentials, user-selected account or client-supplied permissions
are trusted.

| Feature | Configuration |
| --- | --- |
| `opportunity` | `note_on_status_change`, `note_on_followup_change`, `preserve_note_history`, `dependencies`; note/status/follow-up field metadata |
| `visit` | `location_types`, attendance requirement/exempt roles, event-day and concurrent-visit rules, check-in/checkout enabled and reasons, existing geofence/radius/destination rules, upload requirements |
| `visit_report` | observation/outcome metadata and choices, `allow_edit_after_submit`, `submit_enabled`, disabled reason |
| `lead` | existing Lead form required/visible/read-only/max-length/choice metadata |
| `expense` | description/type/amount/date metadata, numeric bounds, `max_expense_rows`, bill min/max count, extensions and byte size |
| `leave` | form metadata, `earliest_date`, `latest_date`, `max_days`, `half_day_allowed` |
| `general_upload` | formats, maximum bytes/count for other authenticated uploads |

Field names match existing endpoint parameters. Supported metadata keys are
`required`, `visible`, `read_only`, `max_length`, `options`, `default`.
A read-only create field needs a matching default. Existing Opportunity status/date values are locked against the persisted document. For fixed/hideable fields,
configure a valid default that the form can send. Options for Link/Select fields
must also exist and be permitted in ERP. This configuration cannot bypass native
ERP mandatory fields, document permissions, leave allocation rules or accounting
validations. Numeric fields also support `type="number"`, `min_exclusive` and
`max_value`.

Leave bounds are inclusive `YYYY-MM-DD`. Empty bounds preserve the previous
calendar window: January 1 five years before the server year through December 31
five years after it. `max_days=0` adds no custom duration cap; a positive value
limits the inclusive calendar span. HRMS still calculates leave consumption and
holidays. `half_day_allowed` changes availability without changing that calculation.

Example: allow expense claims without bills or descriptions for one user:

```python
policy_by_user = {
    "employee@example.com": {
        "expense": {
            "fields": {"description": {"required": False}},
            "uploads": {"min_count": 0},
        },
    },
}
```

Upload `min_count` is checked when finalizing the applicable feature (expense
submission / visit checkout); it is not required before the first individual file
can be uploaded. `max_count=0`, `max_bytes=0`, `extensions=[]` add no extra mobile
limits. Frappe's native upload limits still apply. Formats use suffixes including
the dot, e.g. `[".jpg", ".jpeg", ".png", ".pdf"]`. The existing camera/gallery
controls remain; this change does not add a new document picker. Existing files
are retained. New format limits validate the filename suffix; native Frappe file
validation still runs.

Opportunity dependencies can use an existing `Link` field pointing to Opportunity:

```python
{"statuses": ["Demo"], "doctype": "Your Existing DocType",
 "link_field": "actual_opportunity_link_field", "message": "Create the related document first."}
```

Alternatively use the default Event child-table reference rule. Field existence,
Link target and actual relationship are checked server-side. No new DocType or
field is assumed. `dependencies=[]` removes the additional mobile dependency.
Normal ERP hooks may impose further rules.

## 5. Endpoint adapters and visit actions

Deploy updated API Server Scripts together with the shared policy:

- `mobile_site_visit` -> `mobile_site_visit_api.py`
- `event_visit_report` -> `event_visit_report_api.py`
- `mobile_opportunity_policy` -> `mobile_opportunity_policy.py`
- `create_lead_from_mobile` -> `create_lead_from_mobile.py`
- `create_expense_claim_from_mobile` -> `create_expense_claim_from_mobile.py`
- `create_leave_application_from_mobile` -> `create_leave_application_from_mobile.py`

These return form metadata and validate writes against current policy. Existing
employee/approver resolution, ownership, assignment, pagination, accounting,
leave eligibility, CSRF/session and status transitions are preserved.

For scoped visit decisions use:
`GET /api/method/mobile_business_policy?feature=visit&event_id=EVENT-ID`.
The response contains `actions.check_in` and `.check_out`, each with `allowed` and
`reason`. Decisions use the authenticated user, Event assignment/phase/date,
Employee attendance, exemptions and any other active visit. Flutter refreshes the
decision before collecting GPS; the backend checks again before writing.
The buttons expose denial reasons through tooltips. When only attachments are missing, `can_prepare` allows the app to upload pending files; `allowed` remains false until the required files exist on the server. The write endpoint always requires `allowed`.

The deployed unrestricted custom-app module must contain the updated
`event_checkin` and `event_checkout` bodies from the matching local backend
variant (`backend_patches/api_utils.py` or `api_single_device_updated.py`). They
use `frappe.utils.safe_exec.call_whitelisted_function` to invoke this restricted
API. This import belongs only in the unrestricted custom app. Preserve all other
functions in that module. Restart/reload the deployment as normally required.

Geofencing, saved-location prerequisites and mandatory visit photos remain
**temporarily disabled** in `policies["visit"]`; expense bills remain mandatory.
Restoring visit photo requirements now means changing only
`policies["visit"]["uploads"]["min_count"]`. Existing photo upload/retry behavior,
attendance face verification and employee live tracking remain unchanged.

## 6. File upload enforcement (new Document Event Server Script)

Install `frappe_server_scripts/mobile_file_policy_guard.py` as **DocType Event**,
Reference DocType **File**, Event **Before Save**. It covers File inserts and
reattachment/edits through the normal document lifecycle. Event files use `visit`,
Expense Claim files use `expense`, other authenticated uploads use `general_upload`.
Guest flows and folders are left unchanged. Maximum counts are per attached
document and exclude the current File; unlinked uploads are checked again when
attached. Actual local content bytes enforce size limits rather than a caller's
claimed size. Remote file links retain native Frappe handling.

Install the shared API first, then adapters/custom-app methods, then the File
hook, and finally rebuild/install Flutter once. Refresh/reopen forms after future
API policy changes. Legacy responses without metadata keep migration fallbacks;
the newly deployed endpoints always return the API policy. Adding a completely
new control or workflow still requires frontend support; changing these supported
rules does not.

## Validation boundary

Focused tests use mocked HTTP/Frappe/native channels and execute the real shared
policy source. They cover current defaults and changed settings, action denial,
assignment/session identity, CSRF, ownership, stale saves, history preservation,
optional bills/descriptions, formats/count/actual byte size and leave windows.
They do not install scripts, run real ERP hooks, validate site-specific mandatory
fields/workflows, or verify a phone/release APK. Complete staging UAT after deploying.

Frappe implementation references:
[internal Server Script calls and restricted globals](https://github.com/frappe/frappe/blob/v15.80.0/frappe/utils/safe_exec.py),
[API Server Script return values](https://github.com/frappe/frappe/blob/v15.80.0/frappe/core/doctype/server_script/server_script.py),
[File lifecycle](https://github.com/frappe/frappe/blob/v15.80.0/frappe/core/doctype/file/file.py).
