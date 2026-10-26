# Event assignment alarms

Option 1 uses the restricted mobile API Server Script. Option 2 uses a custom
Frappe app hook, **not a restricted Server Script**.
No change to `api.py`, existing Lead/Opportunity hooks,
FCM Device schema, or the existing FCM sender is required for this feature.

## Option 1: mobile_site_visit only, without hooks.py (recommended for mobile creation)

Update the restricted API Server Script `mobile_site_visit` using the complete
`frappe_server_scripts/mobile_site_visit_api.py` file. After creating the Event
and assignee's ToDo, it calls the existing whitelisted sender directly with
`frappe.call("itgenie.lead_calling.fcm_utils.send_fcm_to_user", ...)` while the
HTTP request is still present. No hook change or new Python module is needed.

The earlier safe_enqueue approach is incompatible with this site's Frappe build:
`call_whitelisted_function -> execute_cmd -> is_valid_http_method` accesses
`frappe.local.request`, which is absent in a worker. The observed failure was
`AttributeError: request`, before FCM sending began. Do not use that queued
whitelisted call on this site or replay those old failed jobs unchanged.

The existing FCM sender must be installed at the method path above, with working
Firebase credentials and an active device token. This direct mobile path does
not need a background worker. It adds no imports or alarm helper definitions to
the Server Script, and does not bypass HTTP method or permission checks.

Creation returns `alarm_sent: true` only when the existing sender returns
`status: sent` (Firebase acceptance, not proof of audible phone playback).
`alarm_queued` remains false for compatibility; no job is queued. Failures log
`Mobile Event assignment alarm failed` and creation still succeeds with
`alarm_sent: false`. Existing sender logs such as `FCM Token Missing` or
`FCM Push Failed` provide further detail.

The call runs during the API request and can add the sender's network latency to
creation. Event/ToDo validation and insertion happen first; transaction commit
still follows the normal API request lifecycle. This direct path cannot provide
the hook worker's after-commit recheck. Do not add an explicit commit or fabricate
a worker HTTP request to work around the error.

This option covers Events created through `mobile_site_visit` only. Assignments
created or changed directly in ERPNext need Option 2. Do not install Option 2
solely for mobile creation; if both are used, the app suppresses duplicate recent
assignment IDs.

Frappe v15's restricted enqueue wrapper supports whitelisted methods; see
[the official Safe Exec implementation](https://github.com/frappe/frappe/blob/version-15/frappe/utils/safe_exec.py)
and [background job documentation](https://docs.frappe.io/framework/user/en/api/background_jobs).

## Option 2: all ERP Event assignments, using a ToDo hook

Copy `backend_patches/event_assignment_notifications.py` into:

`~/frappe-bench/apps/itgenie/itgenie/lead_calling/event_assignment_notifications.py`

The existing sender `itgenie.lead_calling.fcm_utils.send_fcm_to_user` must already
work. This is the sender imported by the supplied `fcm_trigger.py`; the new module
reuses it without replacing either file or altering device registration.

In `~/frappe-bench/apps/itgenie/itgenie/hooks.py`, merge this handler into the
existing `doc_events` dictionary. Preserve every existing handler. If ToDo already
has an `after_insert` handler, keep it and append the new path to that hook list.

```python
# Entry within the existing doc_events dictionary:
"ToDo": {
    "after_insert": [
        # Keep any existing ToDo after_insert handler paths here as well.
        "itgenie.lead_calling.event_assignment_notifications.on_event_assignment",
    ],
},
```

Do not replace the entire hooks.py or create a second doc_events assignment.
The hook queues after transaction commit and only handles an Open ToDo linked to
an Event. Standard ERP assignment and mobile Event creation both insert these
ToDos. Each assignee receives their own message. Setting Event.assigned_to alone
without a ToDo does not run this hook (the existing visit list also uses ToDos).

From the bench directory, syntax-check the new module and hooks.py, clear the
site cache, and restart processes using the deployment's usual procedure:

```bash
python -m py_compile apps/itgenie/itgenie/lead_calling/event_assignment_notifications.py apps/itgenie/itgenie/hooks.py
bench --site YOUR_SITE clear-cache
bench restart
```

The short queue worker and existing Firebase credentials must be available.
No historical assignments are replayed. The worker rechecks the ToDo, recipient,
and Event before sending and skips cancelled assignments, disabled recipients,
and completed/cancelled Events. Queue failure is logged without rolling back
Event creation.

## App installation and behavior

### Diagnosed Firebase project mismatch

The checked-in Android `google-services.json` and Dart `firebase_options.dart`
both use project `pending-work-app-dc16c`, sender ID `25309148229`.
The reported live sender instead attempted to send through project
`test-call-34bde` and Firebase returned HTTP 403 `SenderIdMismatchError`.
That push was rejected before delivery to the phone; sound/channel changes
cannot correct this rejection.

For this app's existing Firebase configuration, the server administrator should
configure the sender with a service account for `pending-work-app-dc16c`.
The supplied `fcm_utils.py` loads the credential from
`<bench>/private/firebase/firebase-service-account.json` and reuses an already
initialized default Firebase app. Check the deployed sender before replacing a
shared credential: other apps may rely on the existing Firebase project. If the
sender is shared across different projects, configure a separate named Firebase
app/sender for this app rather than globally switching other apps' sender.

Restart the serving processes after correcting credentials/configuration so
they do not keep the old initialized Firebase app. Reopen/sign in to the app to
refresh its existing FCM Device registration, then create a new assignment.
Confirm `FCM Push Response` and `alarm_sent: true`, followed by notification and
sound on the assigned phone. Do not paste service-account private keys or device
tokens into logs or chat. This configuration correction does not require edits
to `api.py`, `hooks.py`, or the mobile Server Script.

Firebase documents the rejection in its
[FCM error codes](https://firebase.google.com/docs/cloud-messaging/error-codes).

Build/install the updated Android app. New `EVENT_ASSIGNED` data-only pushes
include Event ID, ToDo assignment ID, and `for_user`. They must not add an FCM
`notification` block; the app displays the notification itself so it can check
the signed-in recipient and suppress duplicates first.

On Android, verified Event assignments start a five-second native playback
only when the recipient has Sales User or Designer (either role). The dedicated
`itgenie.fcm.fcm_utils` sender checks the recipient's current Has Role records and
adds `alarm_enabled: "1"` or `"0"`. It ignores caller-supplied flags. Everyone
still receives the push, but missing/unknown/disabled flags do not start audio
or the sound fallback. Deploy both the updated sender and APK for this policy.
Eligible alerts use the native playback
service using `AudioAttributes.USAGE_ALARM`, in both foreground and background.
The local `event_assignment_alarm` plugin is registered in Firebase's background
engine as well as the main engine. Its `mediaPlayback` foreground service keeps
audio independent of the ringer/media streams while locked, shows a Stop action,
and releases the player, audio focus, and wake lock when playback ends.
The service does not change volume, ringer mode, or Do Not Disturb settings.
Alarm volume must be audible and DND must permit alarms. Exact-alarm scheduling
permissions are not needed for immediate FCM-triggered playback.

Events use separate visual/alarm fallback channels; if Android refuses a service
start, a notification with alarm audio attributes provides a fallback. High-
priority data-only FCM is still required for timely locked/background delivery;
Android may reject service starts for downgraded messages. No full-screen UI or
boot-time playback was added. Existing Lead/Opportunity and pending-work paths
remain unchanged. A bounded receipt list is scoped to site and signed-in user, so
repeated delivery of a recent assignment ID does not ring again. A newly created
assignment ToDo can ring even when the Event was assigned previously.

## Verify on phones after deployment

1. Sign in as user B and allow notifications. From user A, create an Event
   assigned to B. Confirm B gets the alert and A does not.
2. Repeat with B in the background, the phone locked and ringer mode silent,
   with audible alarm volume. Verify the five-second playback and Stop action.
   Also confirm DND with alarms disabled is respected. Confirm the sound and
   notification. FCM delivery and audible phone settings require device testing;
   force-stopped apps are not a reliable background-delivery test.
3. Confirm another user C does not get B's alert; resend the same assignment
   payload to B and confirm it does not ring again.
4. Confirm normal Lead/Opportunity alerts and existing pending-work alarms still
   behave as before. No Event reminder is scheduled for the start time: this
   feature alerts on assignment.

Local tests do not prove live hook installation, worker delivery, Firebase token
validity, notification permission/channel sound, or physical-device playback.
