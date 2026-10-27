# Permanent single-device mobile login

This is **unrestricted custom Frappe application Python**, not a restricted
Server Script. The current app already sends the required login credential;
this permanent-binding update requires no Flutter changes or APK rebuild.
The app refuses login if the backend does not confirm `single_device_login: true`.
Nothing has been installed on the live ERP by the local code changes.

## Behavior

- A successful mobile login binds the user to a random 256-bit installation
  credential held in Flutter Secure Storage. No hardware ID is collected.
- A different installation receives HTTP 409 before session creation or API
  secret rotation, with `Wrong User`. The first phone's credentials continue working.
- The same installation cannot be bound to a second user, including after
  logout. Device and user advisory locks prevent concurrent first-claim races.
- A same-installation retry still requires the user's password and uses the
  same API token. Its old mobile SID is replaced so lost responses are recoverable.
- Login stores the installation hash and SID in the employee-keyed `FCM Device`.
  Logout checks the installation credential, revokes the mobile SID and API
  secret, then clears the SID and disables delivery while retaining the device
  hash and notification row. Retry is safe if the response was lost.
- The binding does not expire with inactivity or an expired browser session.
  The binding is **permanent until a System Manager explicitly resets it**.
- The app keeps a pending logout in secure storage through emergency local
  cleanup and completes it before another login. Normal logout retains local
  credentials and shows an error if ERP cannot confirm sign-out.
- Existing Employee/office mapping validations, Frappe password/IP/hour/2FA
  policies, visit APIs, attendance, face verification and location flows remain.
  The Flutter login UI still does not implement interactive Frappe 2FA; such
  accounts cannot complete mobile login until that separate flow is implemented.

## Update the existing deployment

1. Back up the deployed helper and replace only:

   ```text
   backend_patches/mobile_auth.py -> apps/itgenie/itgenie/mobile_auth.py
   ```

   Keep the existing `itgenie.api.login` and `mobile_logout` delegates, their
   response formats, and all other API methods. The delegate code is shown below.
2. Run `bench restart` so the new login guard is active.
3. Replace the supplied **FCM Device / Before Save** script's code with
   `frappe_server_scripts/fcm_device_validation.py`. Keep that hook enabled.
   The revised restricted script permits the initial inactive row without a
   notification `device_id`, preserves the user/Employee mapping, allows the
   first notification ID assignment, and prevents later ID changes or sharing.
   The permanent login check is in the custom app helper, not this save hook.
   The original hook would reject the first inactive login row, so deploy both
   files in the same rollout. Keep unrelated document hooks enabled.
4. No new fields or installer rerun are needed if
   `custom_mobile_device_hash` and `custom_mobile_session_id` already exist.
   The app still sends its private `device_key` during login. Its separate
   notification `device_id` and rotating FCM token remain metadata.
5. Verify Phone A first login and same-phone retry, Phone B rejection, logout
   on A followed by continued B rejection, and successful A login again.
   Verify a second employee cannot claim installation A. Then perform the
   administrator reset below and verify an explicitly approved replacement.

Existing nonempty device hashes remain the permanent owners. A row whose hash
was cleared under the old logout policy is bound on its next successful login.
The old notification `device_id` cannot reconstruct the private installation
credential; do not claim these historical rows have already been permanently
verified. Coordinate the first login for those employees. If legacy rows have
the same nonempty hash under different users, verify ownership and use the
administrator reset for the incorrect rows; do not silently reassign them.

This binds an **app installation**, not an unchangeable hardware serial number.
Reinstallation or secure-storage loss can change its credential and requires
an administrator reset for the previously bound user.

## First installation, if the earlier login guard is absent

The public mobile API module is `itgenie.api`. MariaDB is required;
the code uses connection-scoped advisory locks that survive Frappe's internal
login commits. Redis cache eviction does not remove the durable device binding.

1. Back up the deployed files, add the login/logout delegates shown below to
   the existing API module, and deploy the helper:

   ```text
   backend_patches/mobile_auth.py -> apps/itgenie/itgenie/mobile_auth.py
   ```

   The `itgenie` app must be available in this bench and installed on the target site.
   Preserve every other live API function. Do not replace a complete API module
   merely to install this device check.
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
   notification activation. Logout retains the binding and disables push delivery,
   without deleting the FCM row, token, platform or version metadata.

   Ensure the deployed `itgenie.fcm.devices.register_device` updates an existing
   Employee row and preserves the custom login fields. The compatible function
   is in `backend_patches/fcm_device_registration.py`; replace only that function
   in `apps/itgenie/itgenie/fcm/devices.py` if it is not already deployed.

3. Run `bench restart` after deploying the files. Configure Flutter `.env`:

   ```env
   URL=https://erp.homegeniegroup.in/api/method/itgenie.api
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
   A, logout on A, then continued rejection on B. After an administrator reset,
   the replacement phone can bind. Also test a separate employee on
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
binding, clearing the old notification `device_id` while retaining the FCM row
and its token/version metadata with delivery disabled. The next approved phone
can then log in and set its notification ID. Avoid manually deleting the row: that
would skip credential revocation.

The API secret is the existing User-level Frappe secret, as in the prior mobile
login implementation. New claims and logout rotate it; integrations sharing
that same User's API secret must use a dedicated integration account. They were
already vulnerable to the old rotation on every mobile login.

## Platform passed during login

The updated Flutter login sends `platform: android` or `platform: ios`.
Deploy the updated `mobile_auth.py` together with this login wrapper in the
current live `apps/itgenie/itgenie/api.py`; preserve every other live method:

```python
@frappe.whitelist(allow_guest=True, methods=["POST"])
def login(usr, pwd, device_key=None, platform=None):
    from itgenie.mobile_auth import login as mobile_login
    return mobile_login(usr, pwd, device_key, platform=platform)

@frappe.whitelist(allow_guest=True, methods=["POST"])
def mobile_logout(user, device_key):
    from itgenie.mobile_auth import logout as release_mobile_session
    return release_mobile_session(user, device_key)
```

The backend validates the supplied platform and sets it on the FCM Device row
before notification registration. This repairs blank or outdated platform values
without deleting device/session records. For old clients that omit the optional
parameter, an existing platform is retained; a missing platform defaults to
Android for legacy compatibility. Platform metadata is not a device credential.
No changes to `itgenie.lead_calling.mobile_api.register_device` are required.
For the current app, deploy the helper and run `bench restart`; rebuilding or
reinstalling Flutter is unnecessary. The first-installation steps above apply
only to older builds that do not already send an installation credential.

## Local checks

```sh
python -m unittest discover -s test -p mobile_login_backend_test.py
python -m unittest discover -s test -p fcm_device_registration_test.py
python -m unittest discover -s test -p fcm_device_validation_test.py
flutter test test/single_device_login_test.dart
```

These use mocked ERP/storage/HTTP. A staging two-phone test remains required
to validate the installed Frappe version, database locking and site hooks.
