# Genie1 PWA build and deployment

This checkout now has conditional browser adapters. Existing Flutter screens,
API contracts, roles, document permissions, attendance face thresholds and
Android services remain in the shared/native code. Local implementation and
builds do not deploy anything to ERP.

## Build

### Local Chrome login testing

Plain `flutter run -d chrome` uses a different origin from ERP. Signing into
ERP in another tab does not make its cookie available to cross-site requests.
Use the local same-origin server instead, from this `Genie1` directory:

```powershell
python tool/serve_pwa_local.py --build
```

Open `http://localhost:8765/genie/` and sign in there. Keep the terminal running;
Ctrl+C stops it. After code changes, stop it and run the same command again.
To reuse the existing build, omit `--build`. Choose `--port 8767` if 8765 is busy.

The server binds only to loopback and serves the built app under `/genie/`.
It supplies an in-memory browser environment with local `URL` and `SITE_URL`,
and proxies other paths to the configured HTTPS ERP origin. Production `.env`,
build files, deployment ZIP, and server configuration are unchanged by the
proxy. `--build` runs the normal production build first. The login module
remains `itgenie.api_utils`.

Cookies belong to localhost during this test. Cookie Domain attributes are
removed for localhost; Secure, HttpOnly and SameSite attributes are preserved.
Chrome supports Secure cookies on localhost. Authentication and CSRF tokens
are still checked by ERP. The proxy does not keep a shared cookie jar or log
credentials. Local shell caching is disabled. Use this only for local Chrome
testing, and sign out in the local app when finished; transactions still affect
the configured ERP, and the existing single-device policy applies.

Production hosting remains the same ERP HTTPS origin, as described below.

From this `Genie1` directory:

```powershell
python tool/build_pwa.py
```

The default base path is `/genie/`. To choose another directory on the same ERP
origin, run `python tool/build_pwa.py --base-href /employee/`.

- Deployable files: `build/web/`
- ZIP package: `dist/automate-genie-pwa.zip` (files are at the ZIP root)
- JavaScript release build; WebAssembly compilation is not required.
- The script bundles the renderer locally, validates public environment keys,
  hashes the shell cache version and creates the release ZIP.
- Use this script for releases. Plain `flutter build web` does not regenerate
  the full offline asset list or Firebase worker configuration.

The existing `.env` URLs are preserved. Host the PWA under the HTTPS origin in
`SITE_URL`, for example `https://YOUR_ERP_HOST/genie/`. The browser owns the ERP
session cookie; it is never read from `Set-Cookie`, copied into a URL, or
injected into an iframe. Locally stored `browser-...` values are form/session
generation markers, not authentication credentials. API requests still use
real Frappe session cookies or the existing authenticated API token.

## Backend prerequisite: web installation platform

### Home role visibility and CRM updates

The web app now uses the mobile app's current Home role decisions: Sales
Managers see visit creation, Sales Users/Managers see lead actions, and the
production roles can see Pending. The task summary and CRM filters/details
also follow the mobile changes. The Home content is constrained for desktop
screens; Opportunity writes use browser cookies, CSRF-protected PUT requests,
and the local same-origin proxy when testing on localhost.

The ERP API Server Script `mobile_site_visit` must include the `can_create_lead`
and `can_view_pending` fields in its `action=can_create` response. The local
source is `frappe_server_scripts/mobile_site_visit_api.py`; see its README for
installation. If these role fields are already deployed from the mobile app,
no additional server change is required. This port does not deploy the script.
Frappe continues to enforce document and workflow permissions for updates.

My Performance now shares the reference app's Home role check through
`mobile_site_visit?action=can_create`. Its Sales tab is available when the
authenticated response grants `can_create_lead` (Sales User) or `can_create`
(Sales Manager). Other users, failed role checks and invalid/account-mismatched
responses retain Attendance only. Sales figures still come from the existing
permission-checked performance API/resource flow. The web app's embedded
Attendance page and app navigation are retained. This focused port passed
17 API/UI tests and analysis without findings; the reference files were not
modified. Live account roles and server deployment remain separate checks.

These are **unrestricted custom Frappe application Python files**, not Safe
Exec Server Scripts. If the existing single-device backend is already installed,
back up the live helper and update it with:

```text
backend_patches/mobile_auth.py -> apps/itgenie/itgenie/mobile_auth.py
```

The narrow change accepts `web` alongside `android` and `ios`, and normalizes
the `pwa` alias to `web`; existing binding,
password, employee, locking, logout and token rules remain. Compare the helper
with the live version first and preserve any newer server changes. Do not
replace the entire live `api_utils.py` for this PWA update. Its existing guarded login
and logout delegates remain.

If login still says `Platform must be android or ios.`, the receiving ERP
process is using the older backend helper. Deploy this updated helper to that
bench and restart it. The PWA already sends `platform=web`; this backend-only
correction does not require a Flutter rebuild.

In `apps/itgenie/itgenie/fcm/devices.py`, update only the existing
`register_device()` function from `backend_patches/fcm_device_registration.py`,
keeping the module's other imports/functions. This permits `platform=web` for
push registration through the existing facade.

From the bench directory, as Administrator/System Manager:

```sh
bench --site YOUR_SITE execute itgenie.mobile_auth.configure_web_platform
bench restart
```

The configuration command checks the existing `FCM Device.platform` metadata.
If it is a Select, it retains all options and appends `web` through a Property
Setter. It does not create a DocType or migrate/delete existing device records.
If the original single-device setup is absent, follow
`backend_patches/SINGLE_DEVICE_LOGIN.md` first.

The PWA remains one installation under the current single-device policy.
Employees must explicitly sign out of a different bound phone before signing
in from a browser. Clearing browser site data does not release the server
binding; sign out first.

Browser logout retains the existing installation-credential release protocol.
Because browsers automatically attach their ERP cookie, a POST rejected with
an explicit `CSRFTokenError` now loads a fresh token from the same-origin
`/app` page and retries once with the token in the header and JSON body. A
guest/expired session can still release its binding without that bootstrap
when ERP accepts the installation credential directly. Timeouts, permission
errors and server errors are not automatically retried. Saved credentials and
pending recovery remain until ERP confirms success. Web errors report a safe
HTTP status or CSRF explanation rather than assuming every failure is offline.
This frontend correction does not require disabling CSRF or replacing backend
modules. Nine Chrome logout tests and ten native login/logout tests passed;
the screenshot's actual failed ERP response was not captured.

## Serve beside ERP

Extract the ZIP into `/var/www/automate-genie-pwa/genie/` on the ERP web host.
Add this location inside the **existing HTTPS server block for the same ERP
hostname**, retaining all existing Frappe locations/proxies:

```nginx
location ^~ /genie/ {
    root /var/www/automate-genie-pwa;
    index index.html;
    try_files $uri $uri/ =404;
    add_header Cache-Control "no-cache" always;
    add_header X-Content-Type-Options "nosniff" always;
}
```

Ensure the existing MIME configuration serves `.js` as JavaScript, `.wasm` as
`application/wasm`, and `.json` as JSON. Run `nginx -t` before a normal nginx
reload. Keep HTTPS and all Frappe authentication/CSRF checks enabled. Hosting
on another origin needs deliberate Frappe CORS and cookie configuration and
browser testing; allowing all origins is not a replacement for this setup.

The `^~` location serves only this built directory, including its explicitly
public `assets/.env` configuration. Never place source `.env` files containing
secrets, Python modules, bench configuration or signing keys in this directory.
The release script refuses unknown environment keys and copies only public
URLs and browser registration values.

## Web push configuration

Firebase Android app IDs cannot be reused as Firebase web app IDs. Add the
actual public configuration from the Firebase project's registered WEB app to
`.env`, then rebuild:

```dotenv
FIREBASE_WEB_API_KEY=YOUR_WEB_API_KEY
FIREBASE_WEB_APP_ID=YOUR_WEB_APP_ID
FIREBASE_WEB_PROJECT_ID=YOUR_PROJECT_ID
FIREBASE_WEB_MESSAGING_SENDER_ID=YOUR_SENDER_ID
FIREBASE_WEB_AUTH_DOMAIN=YOUR_AUTH_DOMAIN
FIREBASE_WEB_STORAGE_BUCKET=YOUR_STORAGE_BUCKET
FIREBASE_WEB_VAPID_KEY=YOUR_PUBLIC_WEB_PUSH_KEY
```

No Firebase web values were invented. Without these settings the PWA starts
and its ERP notification inbox remains available; Firebase browser push is
not enabled. Background push uses `push/firebase-messaging-sw.js`, with a
separate scope from the application shell worker. Browser/OS settings govern
notification delivery and sound. Desktop-style Android alarm behavior and
phone call-state access are unavailable on the web.

## Embedded ERP pages and app navigation

Web page shortcuts remain inside an iframe. Standalone page screens keep the
Home/Tasks/More navigation and permitted Visits/Leads entries; embedded Tasks
and Attendance keep their parent screen navigation. Reload/Retry stays inside
the app. The Flutter page wrapper no longer offers an external-tab button.
The webpage itself can still contain its own links or popup actions.

The web app's My Tasks and New Task entries use the requested
`https://erp.homegeniegroup.in/TG`. Native builds retain their existing TGC URL.
Other requested URLs are retained, including `https://16.itgenie.online/SVR`.
Anonymous header checks on the previously configured TGC page, SVR,
GOAD and Canteen returned `X-Frame-Options: SAMEORIGIN`. Therefore:

- On the live ERP origin, GOAD and Canteen can use the ERP session in a
  same-origin iframe, subject to their own page/redirect permissions.
- For local development, restart `tool/serve_pwa_local.py`. It publishes its
  configured upstream ERP origin in memory; iframe URLs on that exact ERP
  origin are routed through localhost, preserving their path/query/fragment.
  It does not rewrite the `16.itgenie.online` URLs or strip framing headers.
- The administrator of `16.itgenie.online` must allow the live parent origin
  for the intended embedded pages. Scope this to the approved pages and any
  login/redirect pages they need. An appropriate response policy is:

  ```http
  Content-Security-Policy: frame-ancestors 'self' https://erp.homegeniegroup.in;
  ```

  Ensure those approved responses do not also send a conflicting
  `X-Frame-Options: SAMEORIGIN` or a second, more restrictive `frame-ancestors`
  policy. Keep other sites/pages protected and preserve authentication, CSRF,
  roles and document permissions. The exact server edit depends on whether
  Frappe or Nginx currently sets those headers; it has not been deployed here.
- Authentication on `16.itgenie.online` remains separate from the ERP-host
  session. Verify its own sign-in and cookie behavior in a framed browser;
  browsers may block third-party cookies even when framing is permitted.
  Do not copy a SID into a URL or disable authentication/CSRF checks.

The frontend cannot override browser framing restrictions. Cross-origin
iframe load events do not reliably expose a blocked page, so a blank/refused
frame still needs a browser-console and response-header check on the server.
Do not allow localhost in production framing policy just to test these pages.

Embedding changes passed 24 focused Flutter checks, five local-proxy tests,
and two Chrome widget tests. The Chrome widget tests use mocked ERP sessions
and the Flutter platform-view registry to check frame configuration and app
navigation; they do not prove authenticated live-page rendering. The Windows
SDK renderer workaround described below was used for the Chrome test session.

## Maps configuration

Set `GOOGLE_MAPS_WEB_API_KEY` to a browser key with the deployed HTTPS referrer
allowed and Maps JavaScript/Places/Geocoding and existing route services enabled.
The current Maps key is retained as the compatibility default; its current
cloud restrictions and billing were not changed or verified. Browser reverse
geocoding and address searches use the Maps JavaScript SDK rather than blocked
Geocoding REST fetches. Short map links without coordinates must be expanded
by the user before pasting. GPS photo stamps retain time, coordinates and text;
the optional Static Maps image thumbnail is omitted in browser stamps.

## Feature boundaries

| Feature | Browser behavior |
| --- | --- |
| Login, dashboards, CRM, tasks, leave, expenses, approvals | Existing screens and ERP APIs retained; live account validation still required |
| Bills, event images, GPS photo stamps | Browser camera/blob previews and byte uploads; original native file streaming retained |
| Visit audio | Browser microphone recording, pause/resume and upload while the PWA runs; no phone-call detection |
| GPS and event geofence | Existing radii and installation exception retained; monitors while the browser executes; may stop/suspend when hidden, locked or closed |
| Face enrollment and face-protected attendance | Mobile app required; browser ML Kit/blink verification is not available. No selfie-only bypass or reduced thresholds |
| Employees without an enrolled face | Original enrollment gate remains; complete enrollment in the mobile app before accessing the dashboard through the PWA |
| ERP web pages | Embedded iframe with app navigation; retry stays inside the app; server framing policy still applies |
| Push | Requires web Firebase/VAPID and backend platform update; browser permissions and OS limits apply |
| Offline | Public app shell can load after the first complete installation. ERP reads/writes require connectivity; no offline attendance or queued submissions |

The current face detector is Android/iOS ML Kit. Its browser replacement would
require separate landmark/blink implementation and equivalence validation.
The existing SFace model, thresholds and native face pipeline are preserved.

## Validation

```powershell
flutter test --platform chrome test/pwa_browser_test.dart test/opportunity_web_test.dart
node tool/test_pwa.mjs
python -m unittest discover -s test -p "test_pwa_build.py"
```

Browser tests cover login without visible Set-Cookie, account mismatch cleanup,
GPS JPEG stamping, multipart bytes and face verification refusal. Service-worker
tests prove API/private-file/authorized requests are not cached and only this
app's obsolete shell caches are removed.

The final focused Flutter regression suite passed all 136 tests. The backend
login and FCM suites passed all 33 tests; the two build-script tests and
service-worker privacy/fallback tests also passed. Project analysis reported
no errors or warnings, with existing/style information-level findings.

For the role/CRM port, 40 focused Flutter tests passed across Home layout,
role visibility, lead/opportunity filters, CRM details and editing. This
includes a 1440 px desktop layout check. All 23 site-visit backend tests passed.
Analysis of the ported code reported no errors or warnings and 21 existing
information-level findings.

All eight Chrome browser tests passed with mocked ERP responses, covering
login/session cleanup, role flags, Opportunity writes with CSRF, final-origin
validation, localhost transport, uploads and the face-verification boundary.
The Windows Flutter test server returned 404 for its CanvasKit URLs. For this
run only, the browser test session received those renderer files from the
installed Flutter SDK; no SDK or mobile source files were changed. An SDK
with a working CanvasKit test route can run the command above directly.
These browser assertions do not establish live ERP account/transaction results.

An earlier focused run including the unchanged native tracking test passed
102 of 103 tests. The existing
`live_location_service_test.dart` case named `checked-out attendance never
restores tracking` expects no method-channel calls, whereas the unchanged
native implementation deliberately sends `stopLocationTracking`. The native
service file is byte-for-byte preserved from this checkout's original version;
this discrepancy is not repaired as part of the browser migration.

Before distribution, validate a real employee on the deployed HTTPS origin:
login/logout/single-device binding, every assigned menu, bills and uploads,
CSRF-protected writes, maps, camera/microphone permission denial, iframe pages,
GPS radius checks, push after granting permission, installation on Android and
iOS, updates with an in-progress form, and an offline restart. Authentication,
ERP transactions, Firebase delivery and physical-phone behavior have not been
claimed as live-tested by a local build.

The shell service worker uses an explicit static-asset list. `/api`, `/app`,
private files, uploaded bills, biometric images, and requests with Authorization
are network-only. New workers wait for existing tabs to close so updates do
not discard open forms. Close all PWA tabs and reopen after deployment.
