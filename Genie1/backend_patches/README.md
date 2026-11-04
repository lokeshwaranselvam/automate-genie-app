# Attendance API update

## Security fixes: deployment checklist

These changes only take effect once deployed. Back up the live files first.

1. **Google Maps key in site config.** The server no longer contains the key.
   Before deploying `api_utils.py` / `attendance_api.py`, run
   `bench --site YOUR_SITE set-config google_maps_api_key <SERVER_KEY>`.
   Without it, checkout and event checkout return "Google Maps is not
   configured on the server". The old key is in git history: create new keys
   in Google Cloud Console and delete the old one. Use a server key restricted
   by server IP, and a separate app key restricted to Android app
   `ai.automategenie.app` plus your release signing SHA-1 (the app now sends
   `X-Android-Package` / `X-Android-Cert`). Limit each key to the APIs it uses
   and set quotas. Ship a new APK with the new app key in `location_api.dart`
   and `AndroidManifest.xml`.
2. **Per-user API checks** (`api_utils.py`). Methods that take `user` now
   require it to be the signed-in user; HR Manager and System Manager may read
   other users' data but never check in or out for them. `event_details`
   requires the event owner, an assignee (non-cancelled ToDo) or those roles.
   `generate_keys` is System Manager only.
3. **Bound phone session** (`mobile_auth.py` + `hooks.py` `auth_hooks`), see
   [SINGLE_DEVICE_LOGIN.md](SINGLE_DEVICE_LOGIN.md) step 4.
4. **Tsg task board** (`frappe_server_scripts/tsg_task_api.py`). Editing an
   existing task requires being its creator, a current assignee, or Task write
   permission. The board's task list is unchanged.

For the subsequent single-phone login changes, see
[SINGLE_DEVICE_LOGIN.md](SINGLE_DEVICE_LOGIN.md). Install that backend update
before distributing the new Flutter login flow.

## Complete file for restoring the supplied backup

`api.py` is the **complete server module** originally rebuilt from the supplied
`api.py.bak` paste. The attendance restoration retained the other business
functions. The later single-phone update replaces `login()` with a guarded
delegate and adds `mobile_logout()`; see the rollout guide linked above.

Use this complete `api.py` when replacing the whole server file. Back up the
current server file first and restart bench after installation. Keep the
Employee Checkin face guard and attachment Server Scripts enabled.

Checkout eliminates a redundant office-type read and shares identical Google
route requests within one checkout, with bounded network waits. Check-in keeps
its original logic, adds optional stage timings, and accepts the face fields sent by the app. Live latency
still depends on database saves, existing hooks, storage and Google requests.

## Two-function replacement snippet

`attendance_api.py` contains replacement `checkin()` and `checkout()` functions
generated from the pasted `ts_homegenie` API. Replace both existing functions
in `~/frappe-bench/apps/ts_homegenie/ts_homegenie/ts_homegenie/utils/api.py`
with these functions, including their `@frappe.whitelist` decorators. Keep the
rest of the existing API module. Its existing imports already provide `json`,
`requests`, `frappe`, `getdate`, `nowdate`, and `now_datetime`.

These functions belong in the Python app module, rather than an API Server
Script. Back up the live file before editing and restart the bench web
processes after installation (`bench restart` for a production bench).

The updated signatures accept `photo_url`, `face_verification`, and
`include_timings` sent by the mobile app. The Employee Checkin Before Insert
guard and After Insert attachment Server Scripts must remain installed:
they validate, consume, and attach the receipt using `frappe.form_dict`.
Accepting the arguments alone does not validate a face receipt.

Checkout reuses the office type from its latest IN query, selects only the
previous Visit fields it needs, and shares identical Google distance responses
within the request. It retains the original route/distance rules and normal
document saves. Google requests have a 3.05-second connection timeout and a
10-second read timeout; these are network phase limits, not a total checkout
deadline. A timeout returns an error and rolls back the attendance transaction.
No distance data is shared across requests or employees.

Optional `include_timings=1` reports database, Google distance, document save,
and commit durations in `attendance_timings_ms`. Use these with the app's
profile logs to measure the remaining delay on a physical phone. This update
does not change the face model, matching threshold, or blink checks.

To regenerate the replacements against the same original API structure:

```sh
python3 prepare_attendance_api.py /path/to/utils/api.py /tmp/attendance_api.py
```

The generator leaves its input untouched and rejects an unexpected checkout
structure. Keep `checkout_performance.py` and `checkin_performance.py` beside the generator. The generated
file preserves the supplied API's existing Google Maps configuration.

Local verification:

```sh
python -m unittest discover -s test -p attendance_api_performance_test.py
python -m unittest discover -s test -p mobile_face_auth_test.py
```

Before rollout, test both ordinary and event-related checkout on the ERP site
with the face hooks installed. Local tests use a mocked ERP and cannot measure
live database, storage, hook, or network latency.

## Investigating the reported 29-second delay

The local code identifies waits, but cannot establish which one consumed the
29 seconds without a phone trace. Check-in has no route request. Both actions
wait for fresh GPS/address, evidence JPEG preparation/upload and receipt,
Employee Checkin hooks, Visit save, commit, and native tracking start/stop.
Head Office requests fresh GPS after face matching; other office types overlap
GPS with matching. GPS has a 15-second limit; address lookup adds up to four
seconds. Checkout can additionally wait for Google distance. Limits are not
measurements of the reported request.

Install the updated backend functions and use a debug/profile phone run, or
opt in for a release diagnostic build:

```sh
flutter run --release --dart-define=ATTENDANCE_TIMINGS=true
```

Capture lines beginning `[Attendance timing]` during one check-in and checkout.
The default release build keeps diagnostics off. Logs contain stage labels and
durations only. The opt-in also requests existing face-hook/receipt timings.

- `fresh GPS fix` versus `reverse geocoding` separates the two location waits.
- `evidence upload and receipt` includes network and server work; its server
  File/receipt durations help separate storage from transport or queue delay.
- `checkin_checkin_save` / `checkout_checkin_save` includes document hooks;
  receipt lock and attachment timings can expose work inside that save.
- Google distance, Visit save and commit are separate server stages.
- Request response headers include connection, upload, server queue, work and
  commit; they are not pure upload timings. A long request with short server
  stage totals points to unmeasured server work, queueing or transport.
- `live tracking start/stop` occurs after attendance has saved.
- `battery guidance (includes user wait)` measures the check-in guidance dialog;
  the success popup currently waits for this dialog to close.

Stage totals can overlap or nest; do not add all values together. These changes
add diagnosis and do not claim a measured latency reduction. No live ERP
installation or physical-phone measurement was performed locally.
