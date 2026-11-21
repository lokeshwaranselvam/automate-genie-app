> Current provider: WATI. Read WATI_BIOSTP_OTP_SETUP.md before deployment.
> Credentials now come from Webhook BioSTP; no hardcoded WHAPI token is used.
> The approved OTP template name and parameter are still required. Historical
> WHAPI-specific descriptions below are superseded by the WATI setup document.

# Post-checkout customer verification

Prepared against `update_app_(18/11)` at commit `68daba5`.
These are local source changes; ERP deployment and APK/PWA release are separate.

## Flow and policy

Checkout remains unchanged. Eligible completed Events move from the app's
Completed list into Verification, with Not Verified and Verified sections.
The API checks assignment before returning states or accepting customer OTPs.
The Event remains Completed after either a correct or wrong OTP attempt.

All selection settings live at the top of
`frappe_server_scripts/event_visit_report_api.py`:

```python
VERIFICATION_ENABLED = True
VERIFICATION_TO_ALL = 0
VERIFICATION_CATEGORIES = ["Site Visit"]
VERIFICATION_COMPANIES = ["Bioman Sewage Solutions Private Limited", "Homegenie Building Products Private Limited"]
VERIFICATION_USERS = []
VERIFICATION_ROLES = []
```

Eligibility is enabled AND listed category AND (listed user OR listed role OR
(TO_ALL=1 AND active Employee belongs to a listed company)). An empty list grants
nobody through that condition. A user or role match overrides company exclusion.
TO_ALL=1 never includes an unlisted company without a separate user/role match.

Initial user IDs/roles and boolean have not been supplied. With the safe defaults
above, **nobody sees Verification**. Set TO_ALL=1 to include all employees of the
two supplied companies, or add exact User IDs/roles while keeping TO_ALL=0.
Future policy edits require only saving this Server Script and refreshing the app.

## ERP deployment order

1. Back up the existing scripts. In Customize Form for Event, confirm:
   - `custom_otp`: Data, six numeric characters; keep existing field data.
   - `custom_validate`: Data, hidden; receives the entered OTP.
   - No verification checkbox is needed. Empty `custom_validate` means Not
     Verified; a value saved after a correct OTP match means Verified.
   - Preserve the Number Log fields `otp`, `event_name`. The Event `number_log`
     link is optional: it is populated only when that field exists in metadata.
   - Existing Desk timestamps (`custom_in`, `custom_out`) and mobile timestamps
     (`custom_check_in`, `custom_check_out`) are both supported by the scripts.
   Do not change existing field types without checking existing data first.
2. Replace the existing API Server Script `event_visit_report` with the complete
   `frappe_server_scripts/event_visit_report_api.py`. Allow Guest: disabled;
   enable API rate limiting (for example, 60 requests per minute).
   Preserve the existing `mobile_business_policy` API; report, location and
   upload rules still come from it.
3. Disable/remove the previously proposed `Event Verification Before Save`
   Document Event Server Script if you installed it. Its source file is removed.
   Generation and verification now live in `event_visit_report`; no new Before
   Save hook is needed. Complete the field permissions in the next section
   before removing the guard on a live site.
4. Replace the Event Client Script with the complete
   `frappe_server_scripts/event_verification_client.js`.
   Disable the original OTP-blocking Client Script. The revised script retains
   the check-in/out completion requirement, calls `ensure_otp` after a Desk save,
   and uses `verify` for OTP submissions. It never writes protected validation,
   OTP or Number Log directly. For Flutter-created Events, the checkout sender
   calls `ensure_otp` before sending, so an ERP browser form need not be open.
5. No new Server Script is required. Update ONLY these two existing scripts:
   - Existing API Script `event_visit_report`: paste the updated
     `frappe_server_scripts/event_visit_report_api.py`. Retain your existing
     verification lists/boolean values. Configure the approved WATI OTP
     template fields at its top; credentials are loaded from BioSTP. The new `action=send_checkout_otp` performs background delivery.
   - Existing `Event Checkout Customer OTP Sender` (Event / After Save): paste
     `frappe_server_scripts/event_checkout_send_otp.py`. It queues the existing
     `event_visit_report` API with `action=send_checkout_otp` after commit.
   No `event_checkout_otp_worker` API Script needs to be created. If the earlier
   proposal was installed, disable it after replacing the queue hook; the revised
   code does not use it. No credentials, OTP or phone are passed as job arguments.
   The queued action preserves the checkout user, rechecks policy/assignment,
   generates/reuses the OTP, normalizes the linked Opportunity mobile, sends
   WhatsApp and records errors. Redis and a running `short` worker are required.
   Disable older synchronous/insertion senders. Existing failed Events are not
   automatically retried. The app does not wait for the external WHAPI request.
6. In your installed custom app's existing API Python module, replace only
   `event_details`, `history_list`, and `event_list_date` from the corresponding
   `backend_patches/api_utils.py` (or `api_single_device_updated.py` variant).
   These narrow changes omit `custom_otp`, `custom_validate`, `custom_whats_app`
   from mobile responses. Do not replace the entire installed module or alter
   its module path. Restart the site's processes using your normal deployment.
   Restrict direct REST/Desk read access to OTP fields for FE roles using field
   permission levels as appropriate; API filtering alone cannot change those
   independent Frappe permissions.
7. Build/release the changed Flutter app or PWA once using the existing release
   workflow. No checkout API change is required. Do not deploy the old
   update17(1) OTP-gated checkout methods.

## Required server field permissions (replacement for the guard)

Use Customize Form to assign separate permission levels, then configure Role
Permission Manager for Event. Field `read_only`/`hidden` settings alone are not
an authorization boundary. The following levels are examples; use unused
levels on your site and preserve existing unrelated permissions:

| Fields | Example level | FE Read | FE Write |
| --- | --- | --- | --- |
| custom_otp, custom_validate, number_log | 1 | No | No |

Give the designated administrator role the needed rights at these levels.
Review **all** roles held by FE users, including shared roles, because another
role granting Write at that level would defeat the restriction. Keep ordinary
Event permissions at their existing levels. Deny FE users direct Number Log
access; it contains the expected OTP too. Remove OTPs from applicable print,
report and export access. Never grant FE write access to the protected fields.

The API writes protected fields only after authentication, policy and assignment
checks; its intentional ignore_permissions applies to those checked operations.
Do not set the fields through other permission-bypassing endpoints. Validate
with an FE account that REST writes to the three protected fields fail and that
REST reads cannot retrieve custom_otp/Number Log. Local stubs cannot prove your
live Role Permission Manager settings; those must be checked before release.

## API generation contract

POST `event_visit_report` with `action=ensure_otp`, `event_id=...`:

- Applies the existing user/role/company OR policy and category list.
- Locks the Event, preserves existing six-digit OTPs/Number Logs, and generates
  only when no OTP exists. An existing Number Log code is reused when possible.
- Stores the code and links Number Log via direct DB updates, without an Event
  save, so no recursive After Save call or duplicate message is triggered.
- Returns only `otp_generation` readiness flags; never returns the actual code.
- Does not overwrite checkout's response when called internally by the sender.

The `verify` action compares the entered OTP with custom_otp. It saves the
entered value into `custom_validate` only on a match. Wrong/missing OTPs are
never stored, and later wrong attempts cannot clear an existing verified value.
The API derives its `is_verified` response flag from nonempty custom_validate;
that flag is not a DocType field and is never stored. The Event stays Completed.

Before switching an already-deployed earlier version, review existing values:
that version saved wrong attempts too. Have an administrator clear any
custom_validate values that do not match custom_otp after reviewing the records.
No production data cleanup is performed automatically by these files.

## Delivery and verification limits

The background worker records provider acceptance without putting the OTP in Comments.
Provider acceptance does not prove customer delivery. Delivery failures are
logged without blocking checkout, with no automatic resend on later saves.
Do not manually clear a sent marker as a retry mechanism without first checking
the provider. The worker commits a one-shot attempt marker and OTP before external I/O,
releasing the Event lock. Replaying a ticket, even after a timeout, cannot send
twice. This favors avoiding duplicates: a worker crash after committing the
attempt but before sending needs manual reconciliation. No automatic HTTP retry
is performed. Check provider logs before any administrator-controlled resend.
The queue captures the checkout session user; no API credentials, OTP or phone
are included in job arguments. Background service-account checkout is not assumed to represent the FE; normal
authenticated app checkout is the supported sender trigger.

Verification accepts exactly six ASCII digits (including leading zeroes), stores
the entered value in custom_validate only when correct. The API limits
attempts to five per Event in 15 minutes and locks the Event while checking.
Do not run an existing hook that overwrites these fields; audit other Event
scripts before enabling this flow. Generation uses MariaDB RANDOM_BYTES, which
requires MariaDB 10.10 or later. Verify support before deployment; the sender
logs generation failure without undoing checkout. No insecure RAND fallback
is used. Existing OTPs and Number Logs are preserved rather than regenerated. No bulk backfill or messages are sent to
historical completed Events by installing these scripts.

## Checks and live acceptance

Run from the Genie1 folder:

```powershell
python -m unittest test.visit_verification_test test.visit_verification_integration_test test.site_visit_api_test
node --test test/event_verification_client_test.cjs
flutter test --no-pub test/visit_verification_api_test.dart test/visit_verification_ui_test.dart
flutter test --no-pub test/event_checkout_otp_api_test.dart test/site_visit_navigation_test.dart test/visit_report_policy_ui_test.dart test/event_details_loading_test.dart
```

The four existing Flutter suites pass 33 tests on both the isolated baseline
and updated checkout. The old Python event_checkout_otp_test.py has the same
pre-existing Collection-photo expectation failure on both snapshots; the
existing checkout photo business policy was not changed to satisfy that test.
Local tests use stubs rather than a live Frappe site or WHAPI account.

Revision validation compares both the prior local implementation and the GitHub
branch `update_app_(18/11)` in isolated snapshots. See
`VISIT_VERIFICATION_REVISION_TESTS.md` for the recorded results and boundaries.

On a test Event, verify generation and Number Log, normal checkout/completion,
one customer message, wrong OTP leaving custom_validate empty, correct OTP filling
it, no resend on report saves, and unchanged report/location/upload behavior.
Test included and excluded users/roles/companies, both boolean values, unlisted
categories, expired/rate-limited attempts, and unauthorized Event IDs.

## Loading-performance revision

The WHAPI POST now matches the supplied working sender's request settings:
Authorization, Content-Type and Accept headers, JSON payload, and no explicit
15-second timeout argument. A framework/session default timeout may still apply;
this change does not establish a live provider speedup. Delivery remains queued.
New delivery errors identify `Source: event_visit_report / send_checkout_otp`,
so logs from an older saved sender can be distinguished from this revision.

For this performance update, replace the existing `event_visit_report` API and
After Save sender only. Retain your configured user/role/company/category lists
and boolean when copying the API. No additional Server Script is required.
Rebuild/release the app for the loading changes described below.

Scheduled visits are rendered as soon as that request completes. History and
verification policy requests start concurrently; complete history and date
filters are preserved. Completed/Verification lists keep a loading state until
verification classification finishes. State requests remain capped at 50 IDs,
with at most three requests in flight. Request-generation guards still reject
stale refresh results.

Event details reuse the visit policy embedded in the authenticated report only
when it belongs to the same user/session/token. Older policy responses fall back
to the existing fresh API lookup. Check-in/out action permission checks and real
GPS requirements remain unchanged. This revision does not assert a measured
speedup for device GPS, ERP database queries or external provider processing.

Frappe v15 source checked for enqueue behavior and user restoration:
https://github.com/frappe/frappe/blob/version-15/frappe/utils/safe_exec.py
https://github.com/frappe/frappe/blob/version-15/frappe/utils/background_jobs.py
