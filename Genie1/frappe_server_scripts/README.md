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

Users without an HR User, HR Manager, or Expense Approver role only receive
their own Active Employee record. Configure Expense Approvers on employees or
departments (or assign the Expense Approver role) and add Expense Claim Types
before opening the page in the app.

# Employee Checkin selfie (custom app change)

The mobile app now takes a mandatory selfie before Employee Check-in and
Check-out. It uploads the GPS-stamped JPEG as a **private, unattached File**
and then calls the custom app's `checkin` / `checkout` methods with an extra
parameter `photo_url` (the File's `file_url`).

Frappe ignores parameters a whitelisted method does not declare, so the app
works before this change; the photo just stays unattached. To link it to the
Employee Checkin, add `photo_url=None` to both method signatures and call this
helper after the Employee Checkin document is inserted:

```python
REQUIRE_CHECKIN_PHOTO = False  # set True once every user has the new app


def attach_checkin_photo(checkin_doc, photo_url):
    """Attach the selfie uploaded by the app to the new Employee Checkin."""
    if not photo_url:
        if REQUIRE_CHECKIN_PHOTO:
            frappe.throw("A selfie is required for Employee Check-in/Check-out.")
        return

    # Only accept a File this user uploaded that is not attached elsewhere.
    file_name = frappe.db.get_value(
        "File",
        {
            "file_url": photo_url,
            "owner": frappe.session.user,
            "attached_to_name": ["is", "not set"],
        },
        "name",
    )
    if not file_name:
        frappe.throw("The check-in photo was not found. Please retake it.")

    file_doc = frappe.get_doc("File", file_name)
    file_doc.attached_to_doctype = "Employee Checkin"
    file_doc.attached_to_name = checkin_doc.name
    file_doc.save(ignore_permissions=True)

    # Optional: show it on the form with an Attach Image custom field.
    if frappe.get_meta("Employee Checkin").has_field("custom_checkin_photo"):
        frappe.db.set_value(
            "Employee Checkin", checkin_doc.name, "custom_checkin_photo", photo_url
        )
```

To enforce the photo on the server as well, validate `photo_url` **before**
inserting the Employee Checkin (so no record is created without a photo) and
set `REQUIRE_CHECKIN_PHOTO = True` after all users have updated the app.
