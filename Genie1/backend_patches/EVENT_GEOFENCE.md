# Event category geofence and saved-location exceptions

Temporary override: see `TEMPORARY_VISIT_RESTRICTIONS.md`. The report API now
returns `visit_geofencing_enabled=False`, which overrides the existing geofence
decision until restored, and `requires_checkout_photo=False`. The historical
category policy and distance settings below are retained.

This patch is for the custom Frappe application, **not a restricted Server Script**.

In the existing server file
`~/frappe-bench/apps/ts_homegenie/ts_homegenie/ts_homegenie/utils/api.py`,
change only the start of `event_details` to:

```python
@frappe.whitelist(allow_guest = False)
def event_details(id):
    doc = frappe.get_doc("Event",id)
    response = {
    "event": doc.as_dict(),
    "requires_geofence": (doc.get("event_category") or "").strip().lower() not in (
        "installation", "measurement", "other", "others", "bank",
        "head office ch", "timbe / bioman office ch", "collection",
    ),
    "reference_details": []
    }
```

Keep the rest of this function and all other functions exactly as they are.
Do not replace the entire server `api.py` with a local copy: the server may
contain other changes. Both local API variants include this same one-line change.
No change to `event_checkin` or `mobile_auth.py` is required.

Back up the server file before editing. From `~/frappe-bench`, check syntax and
reload the production Python processes using the deployment's normal procedure:

```bash
python -m py_compile apps/ts_homegenie/ts_homegenie/ts_homegenie/utils/api.py
bench restart
```

Deploy this custom-app API change and update the restricted `mobile_site_visit`
Server Script from `frappe_server_scripts/mobile_site_visit_api.py`.
Rebuild/reinstall the app with the updated `new_site_visit_page.dart`,
`event_details.dart`, and `utils/event_category_policy.dart`.

Other/Others, Bank, Head Office CH, Timbe / Bioman Office CH, and Collection
skip location selection during creation, saved-destination checks at check-in,
and geofencing. New Events in these categories have no destination fields or
coordinate Comment; assignee and ToDo assignment behavior is preserved. Existing
Event locations are not cleared or migrated.

Installation and Measurement retain their existing geofence exceptions.
The saved-location requirements described above are the legacy defaults;
the API switch below temporarily overrides the saved-location requirement.
The mobile helper also recognizes the five location-free categories when an
older server still returns `requires_geofence: true`; for other categories,
missing flags retain geofence enforcement.

GPS permissions/recording, live tracking, employee attendance prerequisites,
reports, OTPs, checkout photos, and checkout recording remain unchanged.

## Temporary API control of the saved-location requirement

The restricted API Server Script `event_visit_report` now returns the boolean
`requires_saved_location` in its `get` and `save` responses. Replace that script
with `frappe_server_scripts/event_visit_report_api.py`, retaining API Method
`event_visit_report`, Allow Guest disabled, and the existing rate-limit settings.
The setting near the top of the script is temporarily:

```python
requires_saved_location = False
```

The custom-app `api_utils.py` and `api_single_device_updated.py` have been
restored by removing only the flag added in the previous change. If that flag
was already deployed in server `api.py`, remove only that response field there.
No change to the `mobile_site_visit` creation endpoint is needed for this switch.

Rebuild/reinstall the app once with the updated `event_category_policy.dart` and
`event_details.dart`. Afterwards the server controls this requirement:

- `False`: missing saved destination/type/coordinates do not block visit actions.
- `True`: require a valid saved destination at check-in and retain the existing
  New Site Visit/Installation/Complaint Visit checkout destination validation.
- Missing or invalid flag: retain the previous category-based requirement.

To restore the previous category policy from the API, remove the temporary
assignment near the top and put this assignment after the Event assignment
check, where `event` has been loaded:

```python
requires_saved_location = (event.get("event_category") or event.get("custom_event_category") or "").strip().lower() not in (
    "other", "others", "bank", "head office ch", "timbe / bioman office ch", "collection",
)
```

This flag does not change Event creation requirements or stored location data.
Flutter loads it from `event_visit_report` before enabling visit actions. If that
API is unavailable or returns no boolean flag, the original category rules apply.
The custom-app `event_details` response is no longer used for this switch.
Existing location maps/loading and checkout location-saving remain unchanged.
When a valid saved destination exists, the existing 100 m check still follows
`requires_geofence`; without a valid destination it cannot measure that distance
and is skipped when the saved-location requirement is disabled. The existing
200 m monitoring after check-in continues under its original geofence flag.
The switch controls client validation, not server-side permission enforcement.

## Visit distance settings in event_visit_report

The same restricted Server Script now supplies these settings in both `get`
and `save` responses:

```python
visit_checkin_radius_meters = 100
visit_monitoring_enabled = True
visit_monitoring_radius_meters = 200
```

Edit these variables near the top of `event_visit_report_api.py` and deploy the
Server Script. Rebuild/reinstall Flutter once to consume them; subsequent numeric
changes take effect when the Task Details page loads its visit policy again.
Radius values must be finite positive JSON numbers. Missing/invalid radii retain
100 m for check-in and 200 m for monitoring. Only boolean `False` disables zone
monitoring; the check-in distance rule remains independent.

Existing `requires_geofence` category exemptions, saved-location behavior,
monitoring centre (the check-in GPS position), and other workflows are preserved.
These settings configure client distance checks and native monitoring; this change
does not add server-side distance validation. `api_utils.py` is unchanged.

## Checkout destination categories and visit types

`event_visit_report` also supplies these lists in both `get` and `save`:

```python
checkout_location_categories = ["Site Visit", "Installation", "Complaint Visit"]
checkout_location_visit_types = ["New"]
```

The category and visit type must both match for checkout destination validation.
Change these lists in the Server Script to choose the existing visit types and
categories that require a destination. An empty list disables this requirement.
The existing `requires_saved_location` switch must also be `True`; it remains
temporarily `False`, so this change does not re-enable the disabled requirement.
Missing/malformed lists retain the previous client rule for older servers.

Flutter uses the same participant visit type it previously loaded. The existing
checkout location-saving operation keeps its original New Visit/category rule;
changing these validation lists does not change that write operation. Photo,
report, GPS, tracking, assignment, and OTP behavior are unchanged. This configures
the client prerequisite; no new checkout endpoint enforcement is added.

Verify on a phone that each location-free category can be created without a map
and checked in away from any saved destination. With the saved-location flag
enabled, verify Site Visit requires a saved destination, blocks check-in outside
100 m, and starts 200 m monitoring. With the flag disabled, verify missing
destinations do not block check-in and valid destinations retain the 100 m check.
Measurement and Installation must still use their own document selectors and map
pickers. The custom-app API does not add server-side distance enforcement.
