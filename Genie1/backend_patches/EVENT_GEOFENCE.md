# Installation and Measurement event geofence exceptions

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
    "requires_geofence": (doc.get("event_category") or "").strip().lower() not in ("installation", "measurement"),
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

Deploy this API change. If the installed app already supports the Installation
exception through `requires_geofence`, no APK rebuild is needed for Measurement.
Otherwise, install a build containing the updated
`lib/Screen/event_details.dart`. The app reads `requires_geofence` from the
existing event details response, so there is no extra API request. Missing flags
retain the existing restrictions for compatibility with an older server.

Installation and Measurement events skip the existing 100 m check-in distance check and the
200 m monitoring after check-in. All other categories retain those existing
radii. Saved-location requirements, GPS permissions/recording, live tracking,
attendance prerequisites, reports, OTPs, photos and checkout are unchanged.

Verify on a phone with assigned Installation and Measurement events outside the saved-location
radius, then verify Site Visit and Client Visit still block check-in outside 100 m
and starts 200 m monitoring after a successful check-in. Confirm that employee
attendance prerequisites still apply and that the Event/Visit records are saved.
The API still has the original check-in behavior; this change does not add
server-side distance enforcement to direct API requests.
