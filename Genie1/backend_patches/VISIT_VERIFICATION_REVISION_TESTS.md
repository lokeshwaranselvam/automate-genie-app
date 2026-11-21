> Current deployment revision: delivery now uses `action=send_checkout_otp`
> inside the existing `event_visit_report` API. The After Save sender queues
> that existing API; no additional worker Server Script is required. Retain
> your policy list values and configure WHAPI_TOKEN in event_visit_report.
> Older references below to a separate worker API describe the superseded plan.

> Superseded verification-state detail: the latest revision uses only
> `custom_validate` as stored state. Wrong OTPs are not saved. The API/UI
> `is_verified` flag is derived; no checkbox field is required. The historical
> comparisons below describe the preceding checkbox implementation.

Latest performance revision: 51 Flutter tests (50 regression/performance tests
plus the embedded-policy reuse test), 109 Python tests and 7 Client Script tests
passed. The queue integration checks no WHAPI I/O occurs during checkout,
after-commit scheduling, preserved user identity, denied cross-user tickets,
queue failure without synchronous fallback, and no repeated send after timeout.
The Flutter tests cover visible scheduled rows while history/policy remain
pending, bounded three-request state concurrency, and embedded policy reuse.
Targeted Dart analysis is clean; broader Event details analysis still reports
legacy informational lints outside the changed policy-loading block.

Deployment now needs the new `event_checkout_otp_worker` API Server Script,
the updated After Save queue script, a private token in the worker, Redis and
an active short worker. Existing check-in/checkout API bodies and Flutter action
bodies are unchanged. Server/device speed and real queue delivery were not
measured; all jobs and external provider calls in tests use local adapters.

Latest custom_validate-only revision: 26 focused Flutter tests, 102 Python tests
(including local integration/functional coverage), and 7 Client Script component
tests passed. Wrong OTPs do not call Event.save or change custom_validate;
correct OTPs save it, API list/report state derives from its presence, and later
incorrect attempts preserve an existing verified value. No live ERP data or
permissions were changed. Review previously stored wrong-attempt values before
using nonempty custom_validate as the verification state on an existing site.

# Verification revision validation

Compared on 18 November 2026:

- GitHub branch `update_app_(18/11)`, remote/local commit
  `68daba5aba40116b72b220192c2622fffe729500` (remote ref checked again).
- Previous local verification implementation, copied into an isolated worktree
  before editing, including its untracked scripts and tests.
- Revised implementation using `is_verifired` and API OTP generation.

## Results

| Check | GitHub branch | Previous local code | Revised code |
| --- | --- | --- | --- |
| Four existing Flutter regression suites | 33 passed | Included in 44 passed | Included in 44 passed |
| Existing + verification Flutter unit/component suites | Not present | 44 passed | 44 passed |
| Python verification + site-visit suites | Verification suite not present | 96 passed | 101 passed, including 4 new integration/functional tests |
| Event Client Script component tests | Not present | 5 passed | 6 passed |
| Older Python checkout/report suite | 18 passed, 1 failed | 18 passed, 1 failed | 18 passed, 1 failed |
| Dart analysis of affected app code and Dart tests | Not repeated | Prior result recorded separately | No issues |

The unchanged Python failure is
`EventVisitReportWithoutOtpTest.test_report_flag_matches_each_event_category`.
It expects Collection checkout photos to be required, but the existing business
policy returns false. No production photo policy or test expectation was changed.

## What was exercised

- Exact `is_verifired` response/storage/UI field spelling.
- User/role/company OR rules, category gate, global disable and boolean modes.
- API authentication/assignment checks; unauthorized or unlisted users excluded.
- New OTP generation inside `event_visit_report` (`ensure_otp`), existing OTP
  preservation, reuse/linking of Number Log, and no code in API responses.
- No client-side writes to protected fields or direct Number Log access.
- Completed checkout invoking the actual After Save sender, invoking the actual
  API script, generating/storing a missing OTP and sending that same value.
- Wrong OTP persists input without verification; correct OTP sets the checkbox;
  completed status stays unchanged; five-attempt limit is enforced.
- No duplicate sends/generation on later verification or ordinary saves.
- Generator/provider failures do not undo checkout.
- API-controlled app section visibility and movement into Verified.
- Existing report editing, navigation, checkout attachment and loading behavior.

Both `event_checkin` and `event_checkout` in `api_utils.py` and
`api_single_device_updated.py` have identical Python ASTs across all three
snapshots. The custom-app OTP response filtering from the earlier local version
was preserved. No new Flutter dependency was added.

## Reproduction

From the Genie1 folder:

```powershell
python -m unittest test.visit_verification_test test.visit_verification_integration_test test.site_visit_api_test
node --test test/event_verification_client_test.cjs
flutter test --no-pub test/event_checkout_otp_api_test.dart test/site_visit_navigation_test.dart test/visit_report_policy_ui_test.dart test/event_details_loading_test.dart test/visit_verification_api_test.dart test/visit_verification_ui_test.dart
dart analyze lib/Screen/visit_verification_page.dart lib/Screen/site_visits_page.dart lib/utils/api/visit_verification_api.dart test/visit_verification_api_test.dart test/visit_verification_ui_test.dart
```

## Boundaries

Integration tests execute the real Python checkout, sender and API source with
an in-memory Frappe/database adapter and mocked WHAPI I/O. They are local
integration/functional tests, not live ERP or physical-device tests. They cannot
prove production field permissions, database RANDOM_BYTES support, hook order,
provider acceptance/delivery or a released APK/PWA.

Before deployment, configure server-enforced Event/Number Log field permissions
as documented in `EVENT_POST_CHECKOUT_VERIFICATION.md`. With the guard removed,
permissions must deny FE direct OTP/checkbox edits and expected-code reads.
No live permission changes, ERP deployment, Git commit/push or app release were
performed as part of this revision.
