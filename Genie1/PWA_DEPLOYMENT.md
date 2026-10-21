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

## Maps

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
| ERP web pages | Same-origin iframe session; open-page fallback when a page prohibits framing |
| Push | Requires web Firebase/VAPID and backend platform update; browser permissions and OS limits apply |
| Offline | Public app shell can load after the first complete installation. ERP reads/writes require connectivity; no offline attendance or queued submissions |

The current face detector is Android/iOS ML Kit. Its browser replacement would
require separate landmark/blink implementation and equivalence validation.
The existing SFace model, thresholds and native face pipeline are preserved.

## Validation

```powershell
flutter test --platform chrome test/pwa_browser_test.dart
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

Chrome browser tests compiled but the runner could not load the suite and
reported `Connection closed before test suite loaded`. Browser assertions
are therefore unverified. No browser surface was connected for visual QA.

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
