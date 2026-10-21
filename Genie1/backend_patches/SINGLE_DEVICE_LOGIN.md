# Single-phone mobile login rollout

This is **unrestricted custom Frappe application Python**, not a restricted
Server Script. Install both backend and Flutter changes. The app deliberately
refuses login if the backend does not confirm `single_device_login: true`.
Nothing has been installed on the live ERP by the local code changes.

## Behavior

- A successful mobile login binds the user to a random 256-bit installation
  credential held in Flutter Secure Storage. No hardware ID is collected.
- A different installation receives HTTP 409 before session creation or API
  secret rotation. The first phone's credentials continue working.
- A same-installation retry still requires the user's password and uses the
  same API token. Its old mobile SID is replaced so lost responses are recoverable.
- Login stores the installation hash and SID in the employee-keyed `FCM Device`.
  Logout checks the installation credential, revokes the mobile SID and API
  secret, then clears the login fields while retaining the notification row. Retry is safe if the response was lost.
- The binding does not expire with inactivity or an expired browser session.
  This implements the requested restriction **until explicit logout**.
- The app keeps a pending logout in secure storage through emergency local
  cleanup and completes it before another login. Normal logout retains local
  credentials and shows an error if ERP cannot confirm release.
- Existing Employee/office mapping validations, Frappe password/IP/hour/2FA
  policies, visit APIs, attendance, face verification and location flows remain.
  The Flutter login UI still does not implement interactive Frappe 2FA; such
  accounts cannot complete mobile login until that separate flow is implemented.

## Deploy backend first

The public mobile API module is `itgenie.api_utils`. MariaDB is required;
the code uses connection-scoped advisory locks that survive Frappe's internal
login commits. Redis cache eviction does not remove the durable device binding.

1. Back up any existing destination files and deploy the complete API and helper:

   ```text
   backend_patches/api.py         -> apps/itgenie/itgenie/api_utils.py
   backend_patches/mobile_auth.py -> apps/itgenie/itgenie/mobile_auth.py
   ```

   The `itgenie` app must be available in this bench and installed on the target site.
   Compare the API against the current live version and preserve any newer live
   business logic. All app calls using `URL` will now use this complete module.
2. From the bench directory, add the two fields to the existing `FCM Device`:

   ```sh
   bench --site YOUR_SITE execute itgenie.mobile_auth.install
   ```

   This creates only Custom Field records on `FCM Device`:
   `custom_mobile_device_hash` and `custom_mobile_session_id`. Both are optional,
   hidden, read-only, and permission level 1. No new DocType is created; existing
   `user` and `employee` fields are reused. No permission level 1 grants are added.
   Installation stops if level 1 permissions already exist, to prevent exposing
   session IDs to existing FCM readers such as Trainee.

   Old `Genie Mobile Session` records are not copied, read, or deleted. The old
   DocType may remain unused. Log out existing mobile users before switching
   backend versions, then sign in again to establish new FCM bindings. Skipping
   migration does not revoke the old sessions automatically.

   Login reuses the Employee's FCM row, or inserts an inactive row without an FCM
   token if none exists. A new phone claim disables old push delivery until the
   app registers its current notification token. Same-phone retries preserve
   notification activation. Logout clears the binding and disables push delivery,
   without deleting the FCM row, token, platform or version metadata.

   Ensure the deployed `itgenie.fcm.devices.register_device` updates an existing
   Employee row and preserves the custom login fields. The compatible function
   is in `backend_patches/fcm_device_registration.py`; replace only that function
   in `apps/itgenie/itgenie/fcm/devices.py` if it is not already deployed.

3. Run `bench restart` after deploying the files. Configure Flutter `.env`:

   ```env
   URL=https://erp.homegeniegroup.in/api/method/itgenie.api_utils
   SITE_URL=https://erp.homegeniegroup.in/
   ```

   This direct deployment does not use `prepare_mobile_login.py`.
   Rebuild and reinstall the Flutter app so it includes the updated `.env` asset.

4. Distribute the updated Flutter build to all employees. **Old builds cannot
   sign in through the updated login method** because they have no installation
   credential. Existing installations must log out and sign in with the updated
   build to register their phone. Coordinate this rollout: historical tokens
   alone cannot tell the server which physical phone should own a new binding.
5. Test Phone A login, Phone B rejection for the same user, continued visits on
   A, logout on A, then successful login on B. Also test a separate employee on
   another phone, normal attendance, leads, and temporary network loss at logout.

This restriction covers the Genie mobile login endpoint. Standard ERP desktop
login is left available. Do not configure an additional policy that evicts the
mobile SID on every desktop login if employees need both sessions concurrently.
Direct administrative API-secret changes still invalidate token authentication.

## Lost phone / cleared app data

Clearing app data or losing the secure-storage key does **not** unlock the user.
After verifying the employee's identity, a System Manager can run the following
in `bench --site YOUR_SITE console`:

```python
from itgenie.mobile_auth import reset_device
reset_device("employee@example.com")
```

This is not a public endpoint. It revokes the old credentials and releases the
binding. The next phone can then log in. Avoid manually deleting the row: that
would skip credential revocation.

The API secret is the existing User-level Frappe secret, as in the prior mobile
login implementation. New claims and logout rotate it; integrations sharing
that same User's API secret must use a dedicated integration account. They were
already vulnerable to the old rotation on every mobile login.

## Platform passed during login

The updated Flutter login sends `platform: android` or `platform: ios`.
Deploy the updated `mobile_auth.py` together with this login wrapper in the
current live `apps/itgenie/itgenie/api_utils.py`; preserve every other live method:

```python
@frappe.whitelist(allow_guest=True, methods=["POST"])
def login(usr, pwd, device_key=None, platform=None):
    from itgenie.mobile_auth import login as mobile_login
    return mobile_login(usr, pwd, device_key, platform=platform)
```

The backend validates the supplied platform and sets it on the FCM Device row
before notification registration. This repairs blank or outdated platform values
without deleting device/session records. For old clients that omit the optional
parameter, an existing platform is retained; a missing platform defaults to
Android for legacy compatibility. Platform metadata is not a device credential.
No changes to `itgenie.lead_calling.mobile_api.register_device` are required.
After deploying the backend, run `bench restart`, rebuild/reinstall Flutter,
and sign in again. No new fields or installer rerun are needed for this update.

## Local checks

```sh
python -m unittest discover -s test -p mobile_login_backend_test.py
python -m unittest discover -s test -p fcm_device_registration_test.py
flutter test test/single_device_login_test.dart
```

These use mocked ERP/storage/HTTP. A staging two-phone test remains required
to validate the installed Frappe version, database locking and site hooks.
