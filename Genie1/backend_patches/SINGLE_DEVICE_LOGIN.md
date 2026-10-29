# Mobile binding and Android reinstall recovery

This helper is **unrestricted custom Frappe application Python**, not a
restricted Server Script. Flutter and backend changes deploy separately.
Preserve all unrelated API functions, document hooks, and app behavior.

## Binding rules

The existing random 43-character `device_key` remains private in secure storage.
ERP stores its hash in `custom_mobile_device_hash`. Normal logout proves this
private key, revokes the mobile SID/API secret, disables push delivery, and keeps
ownership. Expired browser sessions do not remove the binding. Pending logout
and network failure recovery remain unchanged.

On Android 8+ Flutter reads `Settings.Secure.ANDROID_ID` through a dedicated
native method and sends `android_id` during password login. ERP stores SHA-256
of `genie-android-v1:` plus the normalized ID in the new protected field
`custom_mobile_android_id_hash`. Raw Android IDs are not stored in FCM Device.
Do not log login bodies: they contain passwords and private keys.

After reinstall or clear-data, the Android ID normally remains the same while
the private key changes. Only complete authentication plus a matching enrolled
Android ID permits recovery: rotate the API secret, revoke the old mobile SID,
replace the private-key hash, clear the old notification `device_id`, and disable
delivery until the app registers its new Firebase token and notification ID.
The private random key remains the logout credential; an Android ID alone cannot
authorize logout. Same-installation retries preserve the API secret and FCM
metadata. Either hash belonging to another user causes `Wrong User` (409).

Existing-user migration requires the **original matching private key** before
enrolling an Android ID. If it is already lost, a System Manager must verify and
reset/delete that binding once. Password alone cannot replace a legacy binding.
Notification-only rows without a private-key hash are new claims; their old
notification ID is cleared on login. Coordinate these first claims. No legacy
Genie Mobile Session records are queried, copied, or deleted.

Older clients can retry only their original matching private key. Omitting the
Android ID or reporting iOS cannot recover a changed key. A supplied different
Android ID is rejected even with a matching key. iOS and Android below 8 keep
installation-only behavior. On Android 8+ missing/invalid native IDs fail login;
there is no silent fallback to a weaker replacement binding.

Android ID is client-reported identification, **not a secret or hardware
attestation**; hashing does not prevent modified-client spoofing. A factory
reset, different Android profile, signing-key change, or some older OS upgrade
cases can change the ID. Retain administrator recovery and the release signing
key. Debug/release and Play/sideload signing may differ.

## Backend deployment

Back up the live files and confirm the actual site/bench/version first. The
deletion transaction callbacks require Frappe v15+. Nothing here deploys itself.

1. Copy `backend_patches/mobile_auth.py` to
   `apps/itgenie/itgenie/mobile_auth.py`.
2. Replace **only** the login delegate in the existing public module
   (`itgenie.api` here), preserving all other functions:

   ```python
   @frappe.whitelist(allow_guest=True, methods=["POST"])
   def login(usr, pwd, device_key=None, platform=None, android_id=None):
       from itgenie.mobile_auth import login as mobile_login
       return mobile_login(usr, pwd, device_key, platform=platform, android_id=android_id)
   ```

   Keep the existing `mobile_logout(user, device_key)` delegate to
   `itgenie.mobile_auth.logout`. `api_utils.py` and `api_single_device_updated.py`
   are alternative local sources, not whole-module deployment instructions.
3. Run the installer, **including existing sites**:

   ```sh
   bench --site YOUR_SITE execute itgenie.mobile_auth.install
   ```

   It adds/retains three optional, hidden, read-only, permission-level-1 Data
   fields on the existing employee-keyed FCM Device: `custom_mobile_device_hash`,
   `custom_mobile_android_id_hash` (indexed), and `custom_mobile_session_id`.
   No DocType or level-1 role grants are created. The installer stops if existing
   level-1 permissions require review. Hidden alone is not access control.
   Login returns a setup error until all required fields exist.
4. **Required for administrator deletion:** merge the following entry into the
   EXISTING `doc_events` dictionary in `apps/itgenie/itgenie/hooks.py`:

   ```python
   "FCM Device": {
       "on_trash": "itgenie.mobile_auth.on_device_trash",
   },
   ```

   Preserve all other events/handlers. If `on_trash` already has handlers, append
   this path to their list. Do not replace them or add another `doc_events`
   assignment. Managed binding deletion requires System Manager; unbound
   notification-only deletion retains existing permissions/behavior.

   The handler rotates the API secret and removes the mobile SID within the
   deletion transaction, without calling committing `delete_session()`. Session
   cache invalidation occurs after commit; advisory locks release on commit or
   rollback. A failed deletion does not intentionally commit partial cleanup.

   **Required for the phone binding to cover attendance:** add the session
   check to `auth_hooks` in the same `hooks.py` (append if the list exists):

   ```python
   auth_hooks = ["itgenie.mobile_auth.validate_bound_session"]
   ```

   For a user with a bound phone, `checkin`, `checkout`, `event_checkin` and
   `event_checkout` in `itgenie.api_utils` then accept only the phone's API
   token or the SID recorded by the guarded mobile login. A SID from the
   standard `/api/method/login` (another phone, a script, a browser) is
   rejected with 401. Other methods and unbound users are unchanged. If the
   public module is not `itgenie.api_utils`, update `BOUND_SESSION_METHODS`.
5. Keep the existing restricted FCM Device **Before Save** guard enabled with
   `frappe_server_scripts/fcm_device_validation.py`. No loosening is needed:
   verified login clears the old notification ID before fresh registration.
   Keep `itgenie.lead_calling.mobile_api.register_device`; it must reuse the
   Employee row and preserve the custom fields. If needed, replace only the
   delegated `register_device` function using `fcm_device_registration.py`.
6. Apply hooks and restart:

   ```sh
   bench --site YOUR_SITE clear-cache
   bench restart
   ```

7. Rebuild/distribute the updated APK using the same release signing key. Its
   configured `URL` must point to the updated login delegate. No `.env` changes
   are included. New Android clients require `android_device_binding: true`
   when supplying an Android ID. Existing cookie/token/Employee response fields
   and `single_device_login` remain. Standard desktop ERP login is unchanged.

## Administrator-approved phone replacement

After verifying the employee, a System Manager can delete the employee's FCM
Device through **normal ERP document deletion with the hook installed**. This
revokes old mobile access and removes both hashes with the record. Coordinate
the next login on the intended replacement: the next successful claim wins.

Direct SQL, `frappe.db.delete`, and hook-bypassing deletion skip cleanup and are
not approved replacement procedures. Revocation cannot undo already executing
requests. The new login still requires active Employee, office mapping, and
Frappe password/IP/hour/2FA checks. Flutter's interactive 2FA UI is not added by
this patch, and those checks are not bypassed.

Alternatively retain the row and use the existing non-public admin console reset:

```python
from itgenie.mobile_auth import reset_device
reset_device("employee@example.com")
```

Reset clears both hashes and notification ID, revokes access, and disables
delivery while retaining FCM token/version metadata. The User-level API secret
is shared as in the existing design; integrations need dedicated User accounts
to avoid interruption from mobile credential rotation.

## Validation

```sh
python -m unittest test.mobile_login_backend_test test.fcm_device_registration_test test.fcm_device_validation_test
flutter test test/single_device_login_test.dart test/fcm_device_api_test.dart test/face_performance_test.dart
```

Local tests mock ERP/storage/HTTP. Staging/physical-device checks must cover
legacy enrollment, signed-APK reinstall/clear-data recovery, rejection of old
logout credentials, new notification registration, wrong-phone/user rejection,
admin deletion followed by replacement login, rollback, and concurrent
login/deletion with real MariaDB/Frappe. Verify attendance, face capture,
tracking, visits, and desktop ERP sessions separately. Local tests do not prove
deployed or physical-device behavior.
