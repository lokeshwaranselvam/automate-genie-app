# Event checkout: attachment required, OTP removed

The app no longer collects, requests, saves, or verifies OTP during Event checkout.
The photo capture/upload gate remains. Checkout is submitted only after the
photo upload succeeds; failed uploads retain their existing retry behavior.
The custom-app checkout endpoint now requires a saved non-folder File with a
nonempty URL attached to the exact Event before it updates Event or Visit.
Existing check-in/completed guards, route calculations, location logs, distance,
working hours, status updates and other API methods remain unchanged.

## Deploy

1. Replace the existing API Server Script `event_visit_report` body with
   `frappe_server_scripts/event_visit_report_api.py`. Keep authentication and
   rate limits enabled. This is restricted Server Script Python. Report
   assignment checks, observation/outcome validation and submitted-report lock
   remain. OTP-only `save_otp` is retired; report saves ignore old OTP input and
   preserve historical Event OTP fields and the existing report response keys.
2. Replace only `event_checkout()` (including its decorator) in the current live
   `apps/itgenie/itgenie/api_utils.py` with the function from `backend_patches/api.py`.
   This is unrestricted custom-app Python, not a restricted Server Script.
   Keep every other live method and import. The optional `custom_otp` argument
   is retained for older callers but is not checked or stored.
3. Run `bench restart` after the custom-app update.
4. Rebuild/install Flutter and test checkout on the correct ERP site.

The supplied `mobile_site_visit` Server Script contains no OTP logic and needs
no update. Its Sales Manager gate, permissions, search, locations, scheduling,
participants and assignments remain untouched. Existing standalone OTP APIs
are not changed; this rollout removes OTP only from the report/checkout flow.
No DocTypes, Custom Fields, migrations or installer reruns are needed.

## Verify

- The checkout screen has no OTP field or confirmation dialog.
- No photo: checkout is blocked; no checkout request is sent.
- Upload failure: checkout is blocked and retry still works.
- Saved attachment: checkout succeeds without configured or entered OTP.
- A direct checkout request without an Event attachment is rejected before writes.
- Existing check-in/date/location/geofence, Visit calculations, audio and report
  submission behavior continues to work.

Local mocked regression checks:

```sh
python -m unittest discover -s test -p event_checkout_otp_test.py
python -m unittest discover -s test -p site_visit_api_test.py
python -m unittest discover -s test -p event_geofence_policy_test.py
flutter test test/event_checkout_otp_api_test.dart test/event_location_selection_test.dart test/site_visit_creation_api_test.dart
```

Local checks do not establish physical-phone or live ERP behavior. Event hooks
installed separately on the live site must also be checked if they impose OTP.
