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
- Logout checks the installation credential, revokes the mobile SID and API
  secret, then releases the binding. Retry is safe if the response was lost.
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

The existing deployment notes identify the module as
`ts_homegenie.ts_homegenie.utils.api`. Confirm that this is the module configured
in the deployed app's `URL` before using these commands. MariaDB is required;
the code uses connection-scoped advisory locks that survive Frappe's internal
login commits. Redis cache eviction does not remove the durable device binding.

1. Back up the **current live** API module. Put `mobile_auth.py` beside that
   module, e.g. `apps/ts_homegenie/ts_homegenie/ts_homegenie/utils/mobile_auth.py`.
2. From the bench directory, install the private DocType once:

   ```sh
   bench --site YOUR_SITE execute ts_homegenie.ts_homegenie.utils.mobile_auth.install
   ```

   This creates `Genie Mobile Session`. Ordinary users have no read/write access;
   System Managers can read it. No existing DocTypes/fields are renamed.

3. Prepare a separate API copy using `prepare_mobile_login.py`:

   ```sh
   python3 prepare_mobile_login.py /path/to/live/utils/api.py /tmp/api.mobile-login.py
   diff -u /path/to/live/utils/api.py /tmp/api.mobile-login.py
   ```

   The generator replaces only `login` and adds/replaces `mobile_logout`.
   Review the diff, install the generated copy at the original path, and run
   `bench restart`. Keep every other live function and hook. The repository's
   full `api.py` has the same wrappers, but do not overwrite newer live business
   logic with an old full-module backup.

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
from ts_homegenie.ts_homegenie.utils.mobile_auth import reset_device
reset_device("employee@example.com")
```

This is not a public endpoint. It revokes the old credentials and releases the
binding. The next phone can then log in. Avoid manually deleting the row: that
would skip credential revocation.

The API secret is the existing User-level Frappe secret, as in the prior mobile
login implementation. New claims and logout rotate it; integrations sharing
that same User's API secret must use a dedicated integration account. They were
already vulnerable to the old rotation on every mobile login.

## Local checks

```sh
python -m unittest discover -s test -p mobile_login_backend_test.py
flutter test test/single_device_login_test.dart
```

These use mocked ERP/storage/HTTP. A staging two-phone test remains required
to validate the installed Frappe version, database locking and site hooks.
