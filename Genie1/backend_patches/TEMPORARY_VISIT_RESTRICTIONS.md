# Temporarily disabled visit geofencing and mandatory photos

The canonical settings are now in `frappe_server_scripts/mobile_business_policy.py`:

```python
# Under policies["visit"]:
"rules": {
    # ... other unchanged visit rules ...
    "requires_saved_location": False,
    "visit_geofencing_enabled": False,
},
"uploads": {"min_count": 0, "max_count": 0, "max_bytes": 0, "extensions": []},
```

`event_visit_report` derives its legacy response flags from these settings.
The custom-app visit methods also read the same policy. Do not reintroduce
separate `requires_checkout_photo` constants in custom-app code.

Deploy the shared API, updated adapters, custom-app visit methods and File hook
following [MOBILE_BUSINESS_POLICY.md](MOBILE_BUSINESS_POLICY.md). Rebuild/install
the app once. Later supported policy changes only require the API settings and
refreshing/reopening the page.

`visit_geofencing_enabled=False` disables both the pre-check-in distance guard and
native visit-zone monitoring, including stopping existing monitoring when the
policy is loaded. Radius/category settings remain available. `min_count=0`
makes visit checkout photos optional; capture, upload, retry and saved attachment
viewing remain. Expense bill requirements are independent and remain enabled.
Attendance GPS, face verification, tracking eligibility and report/OTP data remain.

To restore visit geofencing set `visit_geofencing_enabled=True`; to restore the
saved-location prerequisite set `requires_saved_location=True`; to require a photo
set visit `uploads.min_count=1`. These changes then come from the shared API.
