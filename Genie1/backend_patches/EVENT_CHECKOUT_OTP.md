# Required Event checkout OTP

The entered code must equal the same Event's `custom_whats_app` value after
trimming surrounding whitespace. The comparison runs on the server in the
existing `save_otp` request, before writing anything. A mismatch returns
`Wrong OTP` and the app does not submit checkout. An empty expected value
blocks saving with a configuration message. The expected field is never
included in the report API response or fetched by the app to compare locally.
Optional OTP writes through report `save` use the same validation; ordinary
report submissions that omit OTP remain unchanged. The custom-app
`event_checkout()` artifacts also check the expected value to protect direct
checkout calls. Install that function update as well as the Server Script for
server-side enforcement on both endpoints; restart bench after Python changes.

OTP must contain exactly four ASCII digits (`0000` through `9999`), with
leading zeroes preserved as text. The screen limits input to four digits,
and API validation rejects shorter, longer, or nonnumeric values before writes.
Update the `event_visit_report` Server Script on ERPNext for this validation.
For installations using the existing generated-code verification flow, also
update `send_otp()` and `verify_otp()` from the backend artifact: generation now
uses four digits instead of six. Restart bench after custom-app Python changes.

The active Event screen has an `OTP` field. An empty or whitespace-only entry
blocks checkout before GPS, photo uploads, or the checkout request. The value
is saved through `event_visit_report` with `action=save_otp`. That authenticated
API writes `Event.custom_otp`, reads the stored field back, and returns an
explicit `otp_saved` confirmation. Only then does the app call `event_checkout`.
This adds one bounded POST request at checkout, with no polling or retries.
It also works when the deployed checkout method ignores the OTP argument.

The existing conditional Send OTP / Verify OTP dialog remains in place. When
that flow is enabled, it must still succeed; it does not overwrite the code
entered in the Event form, which is compared against `custom_whats_app`.
The new field itself requires an entry; it does not introduce OTP delivery or
verification for events that did not already require verification.

## Install the backend before distributing the updated app

1. Confirm `Event.custom_otp` exists and stores text if leading zeroes matter.
2. Back up the live `ts_homegenie/ts_homegenie/utils/api.py` module.
3. Update only `event_checkout()` using its version in `backend_patches/api.py`.
   Its signature now accepts `custom_otp=None`, and the OTP validation/assignment
   occurs after the existing check-in/completed checks and before any Visit
   writes or route calls. Preserve every other function in the live module.
   The alternate full-module artifact `api_single_device_updated.py` includes
   the same change; it is not an additional module to install.
4. Restart the production bench web processes to load the updated function.
5. Replace the body of the existing API Server Script `event_visit_report`
   with `frappe_server_scripts/event_visit_report_api.py`. Retain its existing
   API Method, authentication, and rate-limit settings. This is restricted
   Server Script code; `event_checkout()` is unrestricted custom-app Python.
   The `save_otp` action is required by the app even if the custom-app checkout
   method has already been updated. A failed or unconfirmed OTP save blocks
   the checkout request; install the Server Script before using the app.

The report API returns `custom_otp` on get/save and accepts it optionally on
report save. Omission preserves the saved OTP so existing report submissions
continue working. The separate `save_otp` action does not change description,
observation, outcome, or the submitted-report lock. It uses the same assignment
and authentication checks as the report API.

An old backend rejects the new checkout argument. Local files do not deploy
these changes to ERPNext automatically.

## Verify on the ERP and a phone

- An active event with blank OTP cannot check out; check-in remains unchanged.
- Fill OTP, capture the required photo(s), and check out normally. Confirm
  `custom_otp`, checkout time, status, and the existing Visit data are saved.
- Confirm whitespace is trimmed and a value such as `0123` is preserved.
- If the existing OTP verification dialog is enabled, verify its correct,
  incorrect, cancelled, and resend behavior.
- Submit an ordinary visit report and confirm observation/outcome and its
  submitted lock still work. Attendance and production workflows are untouched.

Local tests cover missing OTP before side effects, OTP persistence, unchanged
check-in/completion checks, report permissions/locking, and save confirmation
before the checkout payload. A failed save or a different stored value blocks
checkout. They do not establish live ERP or device behavior.
