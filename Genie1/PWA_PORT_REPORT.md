# PWA feature and UI port - 4 November 2026

Target: `automate-genie-webapp/Genie1`.
Reference: `automate-genie-app/Genie1`, read only. No ERP deployment was performed.

## Features brought across

- Updated dashboard, feature visibility, quick actions, opportunities counts, navigation and startup retry states.
- Attendance status, API-selected shift/location, request timeouts, retry reconciliation and session-expiry notices.
- CRM details, Opportunity Owner rules, owner editing, follow-up fields and permission-aware document actions.
- Visit category/business policies, creation/search, scheduling, saved report state and completed-visit attachments.
- Notification inbox retention, independent seen/dismissed state, explicit clear, assignment/document pushes and Sales Summary routing.
- Lead, Leave, Expense Claim, Opportunities, Pending Work and Sales Summary pages, packaged inside the PWA.
- Source backend and Server Script companions copied locally for review. They are not automatically installed by a PWA rebuild.

## Browser adaptations

`erp_webview.dart` selects the native WebView on native targets and a same-origin iframe adapter on web.
The six HTML pages are packaged as `build/web/pages/*.html`; separate ERP Web Page publication is not required for these PWA destinations.
Their normal authenticated ERP APIs and permissions are still required. Browser-owned HttpOnly cookies are never replaced with the local `browser-*` generation marker.
`erp_page_bridge.js` installs the channel before page scripts start. Incoming messages require the exact iframe source, app origin and per-frame token. Cross-origin loads are rejected.
Browser file inputs handle bill selection; browser microphone/codec handling and in-memory multipart uploads are retained.
Iframe refresh uses a dedicated touch bridge that ignores form controls, busy forms, nested scrolled content and multiple touches.
The PWA continues to require the same ERP origin or the existing local proxy; this port does not add cross-site Netlify authentication.
Android-only phone monitoring, foreground services, the APK update gate and native alarm playback are kept off the browser path. The existing PWA/service-worker update mechanism is retained. Browser GPS can be suspended when hidden.

## Working face flow preserved

All 31 protected face/auth files matched the pre-port SHA-256 snapshot. Face models also matched.
This includes browser camera capture, MediaPipe/SFace assets and runtime, the working browser blink cutoff, face enrollment gate,
face embedding/alignment, template handling, matching thresholds, verification receipts, session login and fixed test identifiers.
The biometric Server Scripts were not replaced by the reference versions.
The reference source files also matched their pre-port hashes.

## Verification

- Release PWA build succeeded.
- 698 Flutter tests passed; 1 existing test skipped. The empty, fully commented `widget_test.dart` placeholder was excluded, as were browser-only tests from this native run.
- 90 webpage/JavaScript tests passed, including real-browser Expense Claim checks.
- Real Chrome iframe integration passed: channel available before the page script, round-trip messaging, blocked cross-origin load and iframe pull-to-refresh.
- 94 focused refresh/Opportunity/face tests passed again after the final browser gesture adaptation.
- 7 PWA build/proxy tests passed.
- Analysis reported no errors and one inherited unused-field warning (`_mobileSearchFailed`).
- The Flutter Chrome test runner stalled during loading; the separate compiled real-Chrome bridge probe was used for browser integration verification.
- Backend discovery: 422 tests, 3 failures and 7 errors. All 10 failing names also fail in the unchanged reference checkout.

## Backend issues already present in the reference

The copied FCM companion lacks `send_daily_sales_summary` and `deliver_sales_summary_reminder`, although the Sales Summary tests expect them.
The scheduler currently targets `send_document_notification`; its test expects the dedicated daily-summary sender.
A generic-notification whitelist assertion predates the current diagnostic endpoint, and the Collection checkout-photo assertion disagrees with the current category policy.
These were not silently changed during the UI port. Do not infer successful scheduler/push deployment from the frontend build.

## Deployment and device boundary

Run locally with `python tool/serve_pwa_local.py` from `Genie1`; the server serves the rebuilt files at `/genie/`.
For production, deploy `build/web/` (or the ZIP under `dist/`) on the ERP HTTPS origin, retaining `/genie/` and the directory structure.
Use the existing ERP API routes. New/updated business-policy and form APIs need separate server deployment only where the server does not already have them.
The new UI has local/mock coverage; real ERP role/session behavior, submissions, browser push delivery and phone integration still require deployment/device verification.
Firebase Web configuration/VAPID settings remain necessary for browser push, as before.
The current shared mock Android/device identifiers are retained for the agreed test build.

## Notification registration deployment status

The PWA sends the browser session CSRF token even when API authorization is present.
The release build includes locally supplied Firebase Web/VAPID configuration; `.env` and release ZIPs are excluded from this source publication.
A compiled Chrome probe verified registration headers, one CSRF-only retry, and no retry after validation errors or timeouts.
The phone sent the CSRF header/body and FCM token successfully, but the deployed registration endpoint returned HTTP 409 DuplicateEntryError.
`backend_patches/fcm_device_registration.py` is the notification-only replacement for `register_device` in `itgenie/lead_calling/mobile_api.py`; it updates the employee-keyed record, serializes first registrations, and preserves the deployed parameter order and response fields. Its 10 focused tests pass.
This server replacement has not been deployed, and end-to-end push delivery remains unverified.
The Leave form is bundled from `web_pages/leave-application.html`; ERP Web Page edits do not automatically change the PWA copy.

## Changed and added files for this port

- `PWA_DEPLOYMENT.md`
- `PWA_PORT_REPORT.md`
- `backend_patches/EVENT_ASSIGNMENT_ALARMS.md`
- `backend_patches/EVENT_CATEGORY_CREATION_RULES.md`
- `backend_patches/EVENT_CHECKOUT_OTP.md`
- `backend_patches/EVENT_GEOFENCE.md`
- `backend_patches/MOBILE_BUSINESS_POLICY.md`
- `backend_patches/README.md`
- `backend_patches/SINGLE_DEVICE_LOGIN.md`
- `backend_patches/TEMPORARY_VISIT_RESTRICTIONS.md`
- `backend_patches/api_single_device_updated.py`
- `backend_patches/api_utils.py`
- `backend_patches/attendance_api.py`
- `backend_patches/automategenie_fcm/INSTALL_NOTIFICATION_FCM.txt`
- `backend_patches/automategenie_fcm/__init__.py`
- `backend_patches/automategenie_fcm/fcm_utils.py`
- `backend_patches/automategenie_fcm/notification_hooks.py`
- `backend_patches/event_assignment_notifications.py`
- `backend_patches/fcm_device_registration.py`
- `backend_patches/repair_mobile_site_visit_api.py`
- `frappe_server_scripts/README.md`
- `frappe_server_scripts/bioman_confirmed_quotation_checkout_restriction.py`
- `frappe_server_scripts/create_expense_claim_from_mobile.py`
- `frappe_server_scripts/create_lead_from_mobile.py`
- `frappe_server_scripts/create_leave_application_from_mobile.py`
- `frappe_server_scripts/event_visit_report_api.py`
- `frappe_server_scripts/fcm_device_validation.py`
- `frappe_server_scripts/mobile_business_policy.py`
- `frappe_server_scripts/mobile_fcm_notification.py`
- `frappe_server_scripts/mobile_file_policy_guard.py`
- `frappe_server_scripts/mobile_opportunity_policy.py`
- `frappe_server_scripts/mobile_pending_work_api.py`
- `frappe_server_scripts/mobile_sales_summary.py`
- `frappe_server_scripts/mobile_site_visit_api.py`
- `frappe_server_scripts/my_assigned_tasks_api.py`
- `frappe_server_scripts/sales_summary_daily_scheduler.py`
- `frappe_server_scripts/skip_call_log_linking_for_mobile_leads.py`
- `frappe_server_scripts/tsg_task_api.py`
- `frappe_server_scripts/unprocessed_mr_checkout_restriction.py`
- `lib/Screen/app_update_gate.dart`
- `lib/Screen/attendance_page.dart`
- `lib/Screen/event_details.dart`
- `lib/Screen/event_list.dart`
- `lib/Screen/expense_claim_webview_page.dart`
- `lib/Screen/history_list.dart`
- `lib/Screen/history_overview.dart`
- `lib/Screen/home_dashboard_view.dart`
- `lib/Screen/homescreen.dart`
- `lib/Screen/lead_creation_page.dart`
- `lib/Screen/lead_details_page.dart`
- `lib/Screen/leave_application_page.dart`
- `lib/Screen/leave_application_webview_page.dart`
- `lib/Screen/login.dart`
- `lib/Screen/my_leads_page.dart`
- `lib/Screen/my_opportunities_page.dart`
- `lib/Screen/my_performance_page.dart`
- `lib/Screen/new_site_visit_page.dart`
- `lib/Screen/notifications_page.dart`
- `lib/Screen/opportunities_webview_page.dart`
- `lib/Screen/opportunity_details_page.dart`
- `lib/Screen/pending_section_page.dart`
- `lib/Screen/pending_work_overview_page.dart`
- `lib/Screen/pending_work_page.dart`
- `lib/Screen/pending_work_webview_page.dart`
- `lib/Screen/sales_summary_webview_page.dart`
- `lib/Screen/session_webview_native.dart`
- `lib/Screen/site_visit_report_page.dart`
- `lib/Screen/site_visits_page.dart`
- `lib/utils/api/app_update_api.dart`
- `lib/utils/api/check_in_out.dart`
- `lib/utils/api/document_notification.dart`
- `lib/utils/api/event.dart`
- `lib/utils/api/event_assignment_notification.dart`
- `lib/utils/api/expense_claim_api.dart`
- `lib/utils/api/fcm_notification_service.dart`
- `lib/utils/api/image_upload_api.dart`
- `lib/utils/api/lead_api.dart`
- `lib/utils/api/leave_application_api.dart`
- `lib/utils/api/notification_inbox.dart`
- `lib/utils/api/notification_inbox_taps.dart`
- `lib/utils/api/opportunity_api.dart`
- `lib/utils/api/performance_api.dart`
- `lib/utils/api/sales_summary_notification.dart`
- `lib/utils/api/site_visit_creation_api.dart`
- `lib/utils/api_business_policy.dart`
- `lib/utils/canteen_payment_webview.dart`
- `lib/utils/event_category_policy.dart`
- `lib/utils/live_tracking_access.dart`
- `lib/utils/mock_location_guard.dart`
- `lib/utils/platform/erp_web_page_uri.dart`
- `lib/utils/platform/erp_webview.dart`
- `lib/utils/platform/erp_webview_android.dart`
- `lib/utils/platform/erp_webview_android_web.dart`
- `lib/utils/platform/erp_webview_refresh_native.dart`
- `lib/utils/platform/erp_webview_refresh_web.dart`
- `lib/utils/platform/erp_webview_web.dart`
- `lib/utils/short_visit_checkout_notice.dart`
- `lib/utils/site_visit_category_rule.dart`
- `lib/utils/site_visit_schedule.dart`
- `lib/utils/storage_diagnostics.dart`
- `lib/utils/widget/action_bottom.dart`
- `lib/utils/widget/attendance_session_notice.dart`
- `lib/utils/widget/audio_recording_service.dart`
- `lib/utils/widget/battery_optimization_helper.dart`
- `lib/utils/widget/camera_service_native.dart`
- `lib/utils/widget/completed_visit_attachments.dart`
- `lib/utils/widget/crm_document_details.dart`
- `lib/utils/widget/geofence_manager_native.dart`
- `lib/utils/widget/gps_photo_stamper.dart`
- `lib/utils/widget/live_location_service_native.dart`
- `lib/utils/widget/live_location_service_web.dart`
- `lib/utils/widget/load_failed_view.dart`
- `lib/utils/widget/location_permission_helper.dart`
- `lib/utils/widget/notification_bell.dart`
- `lib/utils/widget/opportunity_edit_dialog.dart`
- `lib/utils/widget/opportunity_owner_dialog.dart`
- `lib/utils/widget/warning.dart`
- `lib/utils/widget/webview_pull_to_refresh.dart`
- `packages/event_assignment_alarm/android/build.gradle`
- `packages/event_assignment_alarm/android/src/main/AndroidManifest.xml`
- `packages/event_assignment_alarm/android/src/main/java/ai/automategenie/eventalarm/EventAlarmService.java`
- `packages/event_assignment_alarm/android/src/main/java/ai/automategenie/eventalarm/EventAssignmentAlarmPlugin.java`
- `packages/event_assignment_alarm/lib/event_assignment_alarm.dart`
- `packages/event_assignment_alarm/pubspec.lock`
- `packages/event_assignment_alarm/pubspec.yaml`
- `pubspec.lock`
- `pubspec.yaml`
- `test/api_access_guard_test.py`
- `test/api_business_policy_test.dart`
- `test/app_update_gate_test.dart`
- `test/attendance_business_policy_test.dart`
- `test/attendance_default_shift_test.dart`
- `test/attendance_location_chooser_test.dart`
- `test/attendance_retry_guard_test.py`
- `test/attendance_selected_location_test.dart`
- `test/attendance_session_expiry_test.dart`
- `test/attendance_shift_policy_test.py`
- `test/attendance_status_ui_test.dart`
- `test/automategenie_fcm_sender_test.py`
- `test/business_policy_stub.py`
- `test/canteen_payment_webview_test.dart`
- `test/canteen_razorpay_bridge_test.js`
- `test/check_in_out_test.dart`
- `test/checkout_restriction_queries_test.py`
- `test/completed_visit_attachments_test.dart`
- `test/crm_document_details_test.dart`
- `test/document_notification_test.dart`
- `test/erp_page_bridge_test.cjs`
- `test/erp_webview_browser_test.dart`
- `test/event_assignment_alarm_test.dart`
- `test/event_assignment_notifications_test.py`
- `test/event_category_policy_test.dart`
- `test/event_checkout_otp_api_test.dart`
- `test/event_checkout_otp_test.py`
- `test/event_details_loading_test.dart`
- `test/event_geofence_policy_test.py`
- `test/event_location_selection_test.dart`
- `test/expense_claim_api_test.py`
- `test/expense_claim_submission_test.dart`
- `test/expense_claim_webpage_test.cjs`
- `test/fake_lead_webview_platform.dart`
- `test/fcm_device_registration_test.py`
- `test/fcm_device_validation_test.py`
- `test/generic_fcm_notification_test.py`
- `test/home_dashboard_view_test.dart`
- `test/lead_api_test.dart`
- `test/lead_call_notification_test.dart`
- `test/lead_creation_api_test.py`
- `test/lead_creation_page_test.dart`
- `test/lead_creation_webpage_test.cjs`
- `test/lead_opportunity_navigation_test.dart`
- `test/leave_application_form_test.dart`
- `test/leave_application_server_script_test.py`
- `test/leave_application_webpage_test.cjs`
- `test/leave_application_webview_page_test.dart`
- `test/live_location_attendance_test.dart`
- `test/live_location_service_test.dart`
- `test/live_tracking_access_test.dart`
- `test/mobile_business_policy_test.py`
- `test/mobile_opportunity_policy_test.py`
- `test/mobile_opportunity_visibility_test.py`
- `test/mobile_pending_opportunity_visibility_test.py`
- `test/my_leads_page_test.dart`
- `test/my_opportunities_page_test.dart`
- `test/my_performance_page_test.dart`
- `test/new_site_visit_form_test.dart`
- `test/notification_inbox_taps_test.dart`
- `test/notification_inbox_test.dart`
- `test/notification_version_compat_test.py`
- `test/opportunities_destination_test.dart`
- `test/opportunities_webpage_test.cjs`
- `test/opportunities_webview_page_test.dart`
- `test/opportunity_api_test.dart`
- `test/opportunity_edit_test.dart`
- `test/opportunity_owner_test.dart`
- `test/pending_work_page_test.dart`
- `test/pending_work_webpage_test.cjs`
- `test/pending_work_webview_page_test.dart`
- `test/performance_api_test.dart`
- `test/repair_mobile_site_visit_api_test.py`
- `test/sales_summary_notification_test.dart`
- `test/sales_summary_test.py`
- `test/sales_summary_webpage_test.cjs`
- `test/short_visit_checkout_warning_test.dart`
- `test/site_visit_api_test.py`
- `test/site_visit_category_rule_test.dart`
- `test/site_visit_creation_api_test.dart`
- `test/site_visit_creation_permission_test.dart`
- `test/site_visit_distance_test.dart`
- `test/site_visit_navigation_test.dart`
- `test/site_visit_schedule_test.dart`
- `test/tsg_task_api_test.py`
- `test/visit_report_policy_ui_test.dart`
- `test/webview_back_navigation_test.dart`
- `test/webview_pull_to_refresh_test.dart`
- `test/webview_refresh_probe_test.cjs`
- `tool/build_pwa.py`
- `tool/erp_bridge_probe.dart`
- `tool/test_erp_bridge.mjs`
- `web/erp_page_bridge.js`
- `web_pages/expense-claim.html`
- `web_pages/lead-creation-setup.txt`
- `web_pages/lead-creation.html`
- `web_pages/leave-application-setup.txt`
- `web_pages/leave-application.html`
- `web_pages/opportunities-setup.txt`
- `web_pages/opportunities.html`
- `web_pages/pending-work-setup.txt`
- `web_pages/pending-work.html`
- `web_pages/sales-summary-setup.txt`
- `web_pages/sales-summary.html`
