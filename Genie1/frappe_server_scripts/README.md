# Mobile Lead creation API

Create a Frappe **Server Script** with these settings:

- **Script Type:** API
- **API Method:** `create_lead_from_mobile`
- **Allow Guest:** disabled
- **Enable Rate Limit:** enabled (10 calls per minute is a reasonable starting limit)

Paste the contents of `create_lead_from_mobile.py` into the Server Script and
save it. Set **API Method** to exactly `create_lead_from_mobile`. The app calls
`GET /api/method/create_lead_from_mobile` to load the signed-in Lead Owner and
the configured options from Lead.`custom_source` and
Lead.`custom_product_category`; it submits new leads with `POST` to that same
endpoint. If Frappe returns `KeyError: 'create_lead_from_mobile'`, the API
Server Script is not registered under that exact method name or Server Scripts
are disabled on the site.
The Home screen's **My Leads** card requests
`GET /api/method/create_lead_from_mobile?view=list`; the endpoint returns the
500 newest Leads owned by the authenticated session user.
Both dropdown fields must be configured as either **Select** fields with one
option per line, or **Link** fields whose target DocType contains records. The
GET response includes `source_options` and `product_category_options`; if the
field type or configuration is wrong, the API returns an error naming the
affected Lead field. After changing this local file, paste its full contents
into the Frappe Server Script and save it there as well; the app calls the
server-side script, not this repository file directly.
The POST maps `first_name` and `mobile_no` to their Lead fields, and maps
`custom_requirement`, `custom_source`, `custom_product_category`, and
`custom_address` to the corresponding Lead custom fields. Status and WhatsApp
are not sent by the mobile form.

The endpoint assigns `lead_owner` from `frappe.session.user`; it never accepts a
Lead Owner supplied by the client. It inserts the Lead with
`ignore_permissions=True` and `lead.flags.ignore_mandatory = True`; the API
validates the fields required by the mobile form before inserting.

On Frappe v15, Server Scripts are disabled by default. An administrator must
enable them in the bench/site configuration before this endpoint can run.

# TGC Task API

Create a Frappe **Server Script** with these settings:

- **Script Type:** API
- **API Method:** `Tsg`
- **Allow Guest:** disabled
- **Enable Rate Limit:** enabled

Paste `tsg_task_api.py` into the API Server Script used by the TGC web
dashboard. The mobile task page uses the separate `my_assigned_tasks` method
documented below.

The save action trims the selected assignee and checks that it exists as a
Frappe User before assigning the Task and ToDo, avoiding whitespace-related
`Allocated To` link errors.

# Mobile Assigned Tasks API

Create a separate Frappe **Server Script** with these settings:

- **Script Type:** API
- **API Method:** `my_assigned_tasks`
- **Allow Guest:** disabled
- **Enable Rate Limit:** enabled

Paste `my_assigned_tasks_api.py` into the new script. The app calls
`GET /api/method/my_assigned_tasks?action=get` to receive tasks assigned to
`frappe.session.user`. It submits checked tasks with
`POST /api/method/my_assigned_tasks?action=complete&task_id=...`. The endpoint
checks assignment again before setting Task status to `Completed` and closing
the current user's linked ToDo. The Flutter task API client is configured to
call this separate method.

# Mobile Event Visit Report API

Create a Frappe **Server Script** with these settings:

- **Script Type:** API
- **API Method:** `event_visit_report`
- **Allow Guest:** disabled
- **Enable Rate Limit:** enabled

Paste `event_visit_report_api.py` into the Server Script. The Visit Report page
loads saved observations and outcomes with `GET /api/method/event_visit_report`
and submits them with `POST` to the same method. The API verifies that the
logged-in user owns or is assigned to the Event, then writes the description in
this format:

```text
observation : <entered observation>
Outcome: <selected outcome>
```

The allowed outcomes are `Interested`, `Not Interested`, and `Follow-up Required`.

# Mobile New Site Visit API

Create a Frappe **Server Script** with these settings:

- **Script Type:** API
- **API Method:** `mobile_site_visit`
- **Allow Guest:** disabled
- **Enable Rate Limit:** enabled

Paste `mobile_site_visit_api.py` into the Server Script. The app calls
`GET /api/method/mobile_site_visit?action=can_create` for a session-bound
Sales Manager role check. Only Sales Managers see New Visit. The creation
endpoint also enforces this role for form options, mobile search, location
saving, and event creation. Visit lists, check-in/out, and visit reports keep
their existing permissions. Deploy this updated Server Script before the app.

The app calls
`GET /api/method/mobile_site_visit?action=get` to load Opportunities owned by
`frappe.session.user` and enabled ERP users. Opportunity is searchable in the
form, and Location Type is restricted to `Site`, `Home`, and `Others`. If the
child field is a Select, configure those three options in Frappe; if it is a
Link, create records with those names. The API finds the
Opportunity Table field by checking for a child DocType with the exact fields
`location`, `latitude`, `longitude`, and `location_type`, then stores the map
link and coordinates in that row. The second step creates an Installation
Event linked to that Opportunity and exact saved location, then creates a
Frappe ToDo assignment for the selected user. When available, the Event's
`custom_validate` field receives the map URL, and a coordinate Comment is
created for compatibility with the existing Event location report.

On Frappe v15, Server Scripts are disabled by default. An administrator must
enable Server Scripts and create this API script before the mobile New Visit
flow can load its options.

# Mobile Expense Claim API

Create a Frappe **Server Script** with these settings:

- **Script Type:** API
- **API Method:** `create_expense_claim_from_mobile`
- **Allow Guest:** disabled
- **Enable Rate Limit:** enabled

Paste `create_expense_claim_from_mobile.py` into the Server Script and save it.
The mobile Expense Claim page calls `GET /api/method/create_expense_claim_from_mobile`
to load searchable Employee, assigned Expense Approver, company currency, and
Expense Claim Type options. A GET request can include `employee=<Employee.name>`
to refresh the approver suggestions for a selected employee. `POST` requires
both `employee` and `expense_approver`, validates the selected employee against
the signed-in user's role scope, and validates the approver against the selected
employee's configured approvers. The app submits the claim fields and bill image
together in one multipart `POST`. The Server Script creates the draft Expense
Claim, then saves a private File linked to that claim before returning its name
and file URL. This avoids a separate upload request that could be skipped when
the claim response is delayed, and avoids the generic `upload_file` endpoint's
Expense Claim write-permission check.

After changing `create_expense_claim_from_mobile.py`, replace the contents of
the existing Frappe Server Script with the updated file and save it. The mobile
app and live Server Script must both use the multipart version for the bill to
be attached during claim creation.

The form supports multiple expense rows in one draft claim. Each row has its
own expense date, type, description, and positive amount. The multipart POST
sends an `expenses` JSON array containing those four fields (`expense_date`,
`expense_type`, `description`, `amount`), and one or more repeated `file` parts
for bill photos. Bills are private attachments on the claim; they are not
assigned to individual rows. At least one bill is required for the claim.
Every row and uploaded bill is checked before inserting the claim, and each
row's sanctioned amount initially matches its claimed amount.

The updated GET response includes `supports_multiple_expenses: true`. Install
the updated Server Script before using multiple rows or bills in the app. If
the flag is absent, the app keeps the existing single-expense submission flow
and blocks multiple rows/bills, so an older server cannot silently save only
the first expense. The updated API continues accepting the original scalar
fields with one bill. Its POST response includes `expenses` and `bill_files`
arrays while keeping the original first-row and first-bill response fields.

Users without an HR User, HR Manager, or Expense Approver role only receive
their own Active Employee record. Configure Expense Approvers on employees or
departments (or assign the Expense Approver role) and add Expense Claim Types
before opening the page in the app.

# Mobile face enrollment and verification

This flow uses the Android/iOS camera, ML Kit face detection/blink checks, and
the bundled OpenCV Zoo SFace ONNX model for local 1:1 face matching. It does
not call a paid recognition API. The first live selfie is stored as a private
Frappe File attached to the signed-in **User**; the app will not overwrite it.
Face verification applies only to Employee attendance check-in and check-out.
Only the enrollment image is stored. Each attendance selfie is matched locally,
then deleted from temporary storage; the server receives metadata only. Event check-in and
check-out do not require or create face-verification receipts.

The mobile attendance flow prepares the model and version-bound reference
template when Attendance opens, and opens the camera while a cold reference
loads. Final-photo brightness, pose, eye-open, size, blur, landmark, and matching
checks share the upright-photo pipeline. The camera still processes the full
live blink challenge; resolution, model, and matching thresholds are unchanged.
Outside Head Office, GPS/address acquisition overlaps local matching after the
photo is captured. Head Office retains its original GPS checks before capture
and after matching, using the configured `allowd_distance_meters`; only the
redundant address lookup before capture is removed. A one-time metadata receipt
is requested only after face verification and location validation succeed.

Debug/profile builds emit `[Attendance timing]` durations for matching,
GPS/address, receipt creation and attendance save. Release diagnostics are
optional with `--dart-define=ATTENDANCE_TIMINGS=true`. Logs contain only fixed
stage names and numeric durations. Server scripts return optional
`attendance_timings_ms`; nested stages are included in their totals.

## Attendance without saving selfies

Update all three scripts below together, then run the updated mobile app.
The face status advertises `verification_receipt_version=2`; the new app
requires this version before capturing attendance. Older server scripts must
be replaced, otherwise the app displays an upgrade message. During rollout,
old clients cannot parse the new receipt response and must be updated too.

Enrollment still stores its private User reference JPEG. For attendance,
`record_verification` creates only a system-owned Comment receipt with the
user, reference version, action, model, score, blink assertion and GPS values.
No attendance image is sent, decoded, stamped, inserted or attached. Even an
old client's supplied image is not stored by the new server script.

The Before Insert guard keeps its ownership, action, current reference,
120-second expiry, row lock and one-time consumption checks. It accepts only
version 2 receipts. The After Insert script retains its existing filename
but now links the consumed receipt to the Employee Checkin name without any
File read/save or photo field update. Keep both hooks enabled. Existing
attendance photos are not deleted.

No changes to `backend_patches/api.py`, event APIs, enrollment matching,
blink thresholds, geofence rules, tracking or Employee Checkin document saves
are needed for this storage change. It removes the measured 15.39-second
attendance File insertion; it does not establish a fix for the separate
14.97-second Employee Checkin save. Confirm the remaining latency on a phone.

Install all of the following scripts on the ERPNext site:

1. Create an **API Server Script** with API Method `mobile_face_auth`, Guest
   access disabled, and rate limiting enabled. Paste
   `mobile_face_auth.py`.
2. Create a **DocType Event Server Script** for **Employee Checkin** /
   **Before Insert**. Paste `mobile_face_employee_checkin_guard.py`.
3. Create a **DocType Event Server Script** for **Employee Checkin** /
   **After Insert**. Paste `mobile_face_employee_checkin_attach.py`.

The existing mobile `checkin` and `checkout` methods must create Employee
Checkin documents with normal `insert()` calls. Direct database writes bypass
DocType Event scripts; if those methods use `db_set`, `db_update`, or
`frappe.db.set_value`, add the equivalent receipt validation and consumption
to those methods before enabling this flow. Event check-in and check-out remain
on their existing non-face-verification flow.

On Frappe v15, Server Scripts are disabled by default. An administrator must
enable them and install these scripts before updating the mobile app for
production. Test the hooks on a staging site and verify that an Employee
Checkin uses the normal document lifecycle.

The initial cosine threshold (`0.5`) is a pilot setting, not a confidence
percentage or production accuracy guarantee. Blink detection is a basic live
capture check, not complete anti-spoofing. Matching and blink measurement run
on the device; a modified client can forge the reported score or blink flag,
so this Server Script architecture does not provide independent server-side
biometric verification. Calibrate thresholds and complete spoofing, privacy,
and real-device UAT before broad rollout. Preserve the SFace Apache-2.0
license included with the model asset.
