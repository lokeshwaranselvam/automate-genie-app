# WATI credentials from BioSTP

The existing `event_visit_report` API is now the WATI sender. The existing
Event After Save queue hook continues to call `action=send_checkout_otp`.
No additional Server Script or Flutter change is required for this provider switch.

Credentials are read at runtime from:

- DocType: `Webhook`; name: `BioSTP`.
- URL field: `request_url`.
- Header table: `webhook_headers` (child DocType `Webhook Header`).
- Row `key`: `Authorization` (case insensitive).
- Row `value`: the complete `Bearer ...` header, used once as stored.

The allowed URL is the supplied tenant endpoint:
`https://live-mt-server.wati.io/423524/api/v1/sendTemplateMessages`.
The script does not edit BioSTP or execute its ordinary webhook trigger.
Do not grant FE roles access to the Webhook credentials.

## Confirmed OTP configuration

The supplied BioSTP body uses `remarketing_rnr` and has no `customParams`.
That request cannot carry the generated OTP as supplied. Do not assume the
template's parameter names or replace a customer OTP with a remarketing message.

The user confirmed template `happy_code` with `{{1}}` as its verification-code
variable. The API now uses this configuration:

```python
WATI_WEBHOOK_NAME = "BioSTP"
WATI_TEMPLATE_NAME = "happy_code"  # Template name supplied by the user.
WATI_OTP_PARAMETER_NAME = "1"  # User confirmed {{1}} is the verification code.
WATI_CHANNEL_NUMBER = ""      # Configure if required for this WATI account.
WATI_EXTRA_PARAMETER_SOURCES = {}
```

Optional additional parameter mapping uses actual template names as keys and
`customer_name` or `event_id` as values. No production template name has been
invented. Empty configuration and the supplied unparameterized remarketing
template are rejected before a request is sent.

The request uses template_name, broadcast_name, and one receivers entry with
the normalized customer whatsappNumber and customParams containing the OTP.
It no longer uses WHAPI's free-text `to`/`body` schema. The actual legacy WATI v1
batch response is accepted when result is true and errors.error,
errors.invalidWhatsappNumbers and errors.invalidCustomParameters are all empty.
That response does not contain per-recipient message IDs. The detailed receiver
format remains supported; validation errors in either format are rejected.
Acceptance is not customer delivery confirmation.

## Deployment and verification

Retain the existing verification lists/boolean when copying the updated API.
The provider's token stays in BioSTP, not in the Server Script or job arguments.
Keep the existing short queue worker running. Errors redact the full bearer
header, raw token, OTP and customer number. Old failed Events are not resent
automatically by changing providers.

114 Python unit/integration/regression tests passed with fake WATI fixtures.
These tests confirm stored bearer handling, approved-template validation,
recipient/OTP mapping, error redaction, and unchanged checkout/verification.
The ERP connector returned USER_NOT_LOGGED_IN, so the live BioSTP record and
actual WATI template were not inspected. No live message was sent.

References:
https://docs.wati.io/v2.2/reference/post_api-v1-sendtemplatemessages
https://raw.githubusercontent.com/frappe/frappe/version-15/frappe/integrations/doctype/webhook/webhook.json
https://raw.githubusercontent.com/frappe/frappe/version-15/frappe/integrations/doctype/webhook_header/webhook_header.json
