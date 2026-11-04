# API-controlled Event category creation behavior

Deploy `frappe_server_scripts/mobile_site_visit_api.py` to the existing
`mobile_site_visit` API Server Script, keeping authentication and rate limits.
Rebuild/reinstall the app once with `new_site_visit_page.dart` and
`utils/site_visit_category_rule.dart`.

`action=get` now returns `event_category_rules` keyed by the exact configured
category label. Each rule contains `reference_mode`, `reference_doctype`, and
`required_fields`. Flutter chooses its existing form workflow from this response
and checks the supplied required fields before creation.

Edit `CATEGORY_REFERENCE_TYPES` in the Server Script to change category behavior:

- `"Opportunity"`: existing Opportunity selector and saved customer location.
- `"Measurement"`: Measurement reference selector and Event map/location fields.
- `"Installation Note"`: Installation Note selector and Event map/location fields.
- `""`: no reference, Opportunity, or destination fields.

Unlisted categories retain the Opportunity workflow. Mapping keys are trimmed,
lowercase category labels. The existing role/company category allowlist still
determines which categories the user may select or submit.

`get_category_rule` derives the required fields for each supported workflow.
All workflows retain category, summary, start/end times and assignee. Opportunity
also requires Opportunity and its location row; document workflows also require
the selected reference, map link and coordinates; location type is optional by
default. Existing server
validations continue to enforce these structural requirements.

The same mapping is used by `get_references` and `create_event`. Existing
permission-filtered reference reads, cancelled-document checks, assignment/ToDo,
notification, coordinate Comment and attachment behavior are preserved.

New reference DocTypes or entirely new fields require matching backend support;
`REFERENCE_DOCUMENT_FIELDS` currently supports only Measurement and Installation
Note. The API does not trust a caller-supplied DocType to select a route.

Older servers without `event_category_rules` retain the prior app behavior.
If a server supplies malformed or incomplete rules, the form shows an error
instead of silently using a conflicting workflow. Refresh form options to load
API changes. Existing saved Events are not migrated by this change.

## Optional Location Type

Location Type is optional for all users by default. The shared
`mobile_business_policy.py` visit field `location_type` has `required: False`.
Deploy that API and the updated `mobile_site_visit_api.py` together, then rebuild
the app with the updated form and category-rule fallback. Blank values are
accepted for Opportunity location saves and document-referenced Events; supplied
values must still be valid. Map links, coordinates, reference documents, and
creation permissions retain their existing requirements. Existing saved types
are retained.

If ERP Customize Form marks Location Type mandatory on Customer Location or the
applicable Event field, an administrator must make that specific field optional
as well. This change does not bypass ERP mandatory-field validation or modify
the live DocType schema.
