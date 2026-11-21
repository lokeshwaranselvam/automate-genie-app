"""Policy, assignment, post-checkout verification and sender contract tests."""
import ast
import textwrap
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock
from test.business_policy_stub import install

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'frappe_server_scripts/event_visit_report_api.py').read_text()


class Row(dict):
    __getattr__ = dict.get
    __setattr__ = dict.__setitem__


class VerificationTest(unittest.TestCase):
    def run_api(self, action='verification_policy', users=None, roles=None, companies=None,
                all_users=0, enabled=True, role_match=False, company_match=False,
                category='Site Visit', owner='fe@test', completed=True,
                entered='123456', expected='123456', attempts=0, verified=0, existing_log=None, generation_error=False,
                has_number_log_field=True):
        source = SOURCE.replace('VERIFICATION_USERS = []', 'VERIFICATION_USERS = ' + repr(users or []))
        source = source.replace('VERIFICATION_ROLES = []', 'VERIFICATION_ROLES = ' + repr(roles or []))
        source = source.replace('VERIFICATION_COMPANIES = ["Bioman Sewage Solutions Private Limited", "Homegenie Building Products Private Limited"]', 'VERIFICATION_COMPANIES = ' + repr(companies or ['Company A']))
        source = source.replace('VERIFICATION_TO_ALL = 0', 'VERIFICATION_TO_ALL = ' + repr(all_users))
        source = source.replace('VERIFICATION_ENABLED = True', 'VERIFICATION_ENABLED = ' + repr(enabled))
        event = Row(name='EVENT-1', owner=owner, status='Completed' if completed else 'Open',
                    custom_check_out='2026-11-18 12:00:00' if completed else None,
                    custom_otp=expected, custom_validate=expected if verified else '',
                    event_category=category, description='')
        event.save = Mock()
        self.event = event
        comment = Row(name='LOG-NEW', insert=Mock())
        def get_doc(*args, **kwargs):
            return comment if isinstance(args[0], dict) else event
        def get_all(doctype, **kwargs):
            if doctype == 'Event': return [event]
            if doctype == 'Comment': return [Row(name='ATTEMPT')] * attempts
            return []
        f = SimpleNamespace(session=Row(user='fe@test'), flags=Row(), response={},
            form_dict=Row(action=action, event_id='EVENT-1', custom_validate=entered, event_ids='["EVENT-1"]'),
            db=SimpleNamespace(exists=Mock(side_effect=lambda dt, *args: role_match if dt == 'Has Role' else company_match), get_value=Mock(return_value=existing_log), sql=Mock(return_value=[{'otp': '123456'}], side_effect=RuntimeError('generator unavailable') if generation_error else None), set_value=Mock()),
            get_doc=Mock(side_effect=get_doc), get_all=Mock(side_effect=get_all),
            get_meta=Mock(return_value=SimpleNamespace(get_field=lambda field: has_number_log_field)),
            utils=SimpleNamespace(now_datetime=lambda: '2026-11-18 12:00:00', add_to_date=lambda *args, **kwargs: '2026-11-18 11:45:00'),
            throw=Mock(side_effect=lambda msg: (_ for _ in ()).throw(ValueError(msg))))
        self.frappe = f
        install(f)
        exec(compile(source, 'event_visit_report_api.py', 'exec'), {'frappe': f, 'json': json})
        return f.flags.get('verification_policy') if action == 'verification_policy' else f.flags.get('otp_generation') if action == 'ensure_otp' else f.response['message']

    def test_selection_matrix_or_rules_and_global_disable(self):
        cases = [
            ({}, False),
            ({'users': ['fe@test']}, True),
            ({'users': ['other@test']}, False),
            ({'roles': ['FE'], 'role_match': True}, True),
            ({'roles': ['FE'], 'role_match': False}, False),
            ({'company_match': True}, False),
            ({'all_users': 1, 'company_match': True}, True),
            ({'all_users': 1, 'company_match': False}, False),
            ({'all_users': 1, 'users': ['fe@test']}, True),
            ({'users': ['fe@test'], 'roles': ['FE'], 'role_match': False}, True),
            ({'users': ['fe@test'], 'enabled': False}, False),
        ]
        for config, visible in cases:
            with self.subTest(config=config):
                self.assertIs(self.run_api(**config)['visible'], visible)

    def test_policy_does_not_override_internal_caller_response(self):
        self.run_api(users=['fe@test'])
        self.assertEqual(self.frappe.response, {})

    def test_category_and_completion_are_required_in_batch(self):
        for category, completed, required in [('Site Visit', True, True), ('Installation', True, False), ('Site Visit', False, False)]:
            result = self.run_api('verification_states', users=['fe@test'], category=category, completed=completed)
            self.assertIs(result['events'][0]['verification_required'], required)
            self.assertNotIn('custom_otp', str(result))
            self.assertNotIn('custom_validate', str(result))
        self.assertEqual(self.run_api('verification_states', users=['fe@test'], owner='someone@test')['events'], [])

    def test_batch_has_bounded_validation(self):
        source = SOURCE.replace('VERIFICATION_USERS = []', 'VERIFICATION_USERS = ["fe@test"]')
        self.run_api(users=['fe@test'])
        self.frappe.form_dict = Row(action='verification_states', event_ids=json.dumps(['EVENT-1'] * 51))
        with self.assertRaisesRegex(ValueError, 'at most 50'):
            exec(source, {'frappe': self.frappe, 'json': json})

    def test_correct_code_saves_validation_without_changing_completion(self):
        result = self.run_api('verify', users=['fe@test'])
        self.assertEqual(result['status'], 'success')
        self.assertTrue(result['is_verified'])
        self.assertEqual(self.event.custom_validate, '123456')
        self.assertEqual(self.event.custom_otp, '123456')
        self.assertEqual(self.event.status, 'Completed')
        self.event.save.assert_called_once_with(ignore_permissions=True)
        self.assertNotIn('custom_otp', result)

    def test_wrong_code_is_not_saved_or_verified(self):
        result = self.run_api('verify', users=['fe@test'], entered='654321')
        self.assertEqual(result['status'], 'error')
        self.assertEqual(self.event.custom_validate, '')
        self.event.save.assert_not_called()
        self.assertEqual(self.event.status, 'Completed')

    def test_list_and_report_derive_state_from_saved_validation_only(self):
        for saved, expected_state in [(False, False), (True, True)]:
            with self.subTest(saved=saved):
                states = self.run_api('verification_states', users=['fe@test'], verified=saved)
                self.assertIs(states['events'][0]['is_verified'], expected_state)
                report = self.run_api('get', users=['fe@test'], verified=saved)
                self.assertIs(report['is_verified'], expected_state)
                self.assertNotIn('custom_validate', report)
                self.assertNotIn('is_verified', self.event)

    def test_missing_wrong_length_unauthorized_and_incomplete_are_rejected(self):
        cases = [({'entered': ''}, '6-digit'), ({'entered': '1234'}, '6-digit'),
                 ({'entered': '12a456'}, '6-digit'), ({'completed': False}, 'checkout'),
                 ({'category': 'Installation'}, 'not enabled'), ({'owner': 'other@test'}, 'not assigned')]
        for config, error in cases:
            with self.subTest(config=config), self.assertRaisesRegex(ValueError, error):
                self.run_api('verify', users=['fe@test'], **config)
        with self.assertRaisesRegex(ValueError, 'not enabled'):
            self.run_api('verify')

    def test_attempt_limit_and_already_verified_does_not_get_unchecked(self):
        with self.assertRaisesRegex(ValueError, 'Too many'):
            self.run_api('verify', users=['fe@test'], attempts=5)
        result = self.run_api('verify', users=['fe@test'], verified=1, entered='654321')
        self.assertTrue(result['is_verified'])
        self.assertEqual(self.event.custom_validate, '123456')
        self.event.save.assert_not_called()

    def test_report_fields_and_otp_secrecy_are_preserved(self):
        result = self.run_api('get', users=['fe@test'])
        self.assertIn('business_policy', result)
        self.assertIn('visit_policy', result)
        self.assertNotIn('custom_otp', result)
        self.assertTrue(result['verification_required'])

    def test_api_generation_stores_code_without_returning_it(self):
        result = self.run_api('ensure_otp', users=['fe@test'], expected='', completed=False)
        self.assertTrue(result['otp_ready'])
        self.assertNotIn('custom_otp', str(result))
        self.assertNotIn('123456', str(result))
        self.frappe.db.set_value.assert_any_call('Event', 'EVENT-1', 'custom_otp', '123456', update_modified=False)
        self.frappe.db.set_value.assert_any_call('Event', 'EVENT-1', 'number_log', 'LOG-NEW', update_modified=False)
        self.assertEqual(self.frappe.response, {})
        self.event.save.assert_not_called()  # No recursive Event After Save.

    def test_existing_otp_or_number_log_is_preserved_without_regeneration(self):
        for existing, log in [('012345', None), ('', Row(name='LOG-OLD', otp='012345'))]:
            with self.subTest(existing=existing):
                result = self.run_api('ensure_otp', users=['fe@test'], expected=existing, existing_log=log)
                self.assertTrue(result['otp_ready'])
                self.frappe.db.sql.assert_not_called()
                if existing:
                    self.assertFalse(any(c.args[2] == 'custom_otp' for c in self.frappe.db.set_value.call_args_list))
                else:
                    self.frappe.db.set_value.assert_any_call('Event', 'EVENT-1', 'custom_otp', '012345', update_modified=False)

    def test_generation_without_optional_event_number_log_field(self):
        result = self.run_api('ensure_otp', users=['fe@test'], expected='', has_number_log_field=False)
        self.assertTrue(result['otp_ready'])
        self.frappe.db.set_value.assert_called_once_with('Event', 'EVENT-1', 'custom_otp', '123456', update_modified=False)
        log_doc = self.frappe.get_doc.call_args.args[0]
        self.assertEqual(log_doc['doctype'], 'Number Log')

    def test_generation_enforces_policy_and_assignment(self):
        for config in [{}, {'users': ['fe@test'], 'category': 'Installation'}]:
            with self.subTest(config=config):
                self.assertFalse(self.run_api('ensure_otp', **config)['otp_ready'])
                self.frappe.db.sql.assert_not_called()
                self.frappe.db.set_value.assert_not_called()
        with self.assertRaisesRegex(ValueError, 'not assigned'):
            self.run_api('ensure_otp', users=['fe@test'], owner='other@test')

    def test_generation_failure_and_invalid_existing_codes_are_not_replaced(self):
        with self.assertRaisesRegex(RuntimeError, 'generator unavailable'):
            self.run_api('ensure_otp', users=['fe@test'], expected='', generation_error=True)
        for expected in ['1234', 'abcdef']:
            with self.subTest(expected=expected), self.assertRaisesRegex(ValueError, 'existing customer OTP'):
                self.run_api('ensure_otp', users=['fe@test'], expected=expected)
            self.frappe.db.set_value.assert_not_called()


class SenderTest(unittest.TestCase):
    def send(self, *, completed=True, previous_checkout=None, previous_status='Open', eligible=True,
             accepted=True, duplicate=False, otp='123456', token='test-token', mobile='9876543210',
             provider_error=None, provider_response=None, template_name='test_otp', otp_parameter='otp_code',
             webhook_url='https://live-mt-server.wati.io/423524/api/v1/sendTemplateMessages'):
        api = (ROOT / 'frappe_server_scripts/event_visit_report_api.py').read_text(encoding='utf-8')
        source = 'WATI_WEBHOOK_NAME = "BioSTP"\nWATI_TEMPLATE_NAME = "test_otp"\nWATI_OTP_PARAMETER_NAME = "otp_code"\nWATI_EXTRA_PARAMETER_SOURCES = {}\nWATI_CHANNEL_NUMBER = ""\n' + textwrap.dedent(api.split('# BEGIN CHECKOUT DELIVERY\n', 1)[1].split('    # END CHECKOUT DELIVERY', 1)[0])
        source = source.replace('WATI_TEMPLATE_NAME = "test_otp"', 'WATI_TEMPLATE_NAME = ' + repr(template_name))
        source = source.replace('WATI_OTP_PARAMETER_NAME = "otp_code"', 'WATI_OTP_PARAMETER_NAME = ' + repr(otp_parameter))
        previous = Row(status=previous_status, custom_check_out=previous_checkout)
        event = Row(name='EVENT-1', status='Completed' if completed else 'Open',
            custom_check_out='2026-11-18 12:00:00' if completed else None, custom_otp=otp,
            event_category='Site Visit', event_participants=[Row(reference_doctype='Opportunity', reference_docname='OPP-1')])
        event.get_doc_before_save = lambda: previous
        comment = Row(insert=Mock())
        ticket = Row(name='TICKET-1', owner='fe@test', comment_type='Info', subject='Genie OTP queued delivery',
            reference_doctype='Event', reference_name='EVENT-1', content='Attempt started' if previous_status == 'Completed' else 'Queued', save=Mock())
        acceptance_insert = Mock()
        def get_doc(dt, *args, **kwargs):
            if isinstance(dt, dict):
                return Row(insert=acceptance_insert if dt.get('subject', '').startswith('EVENT_CHECKOUT_OTP_ACCEPTED|') else Mock())
            if dt == 'Webhook':
                return Row(request_url=webhook_url,
                    webhook_headers=[Row(key='Authorization', value=token if token.lower().startswith('bearer ') else 'Bearer ' + token)])
            return ticket if dt == 'Comment' else event
        f = SimpleNamespace(session=Row(user='fe@test'), form_dict=Row(event_id='EVENT-1', ticket_id='TICKET-1'), acceptance_insert=acceptance_insert, call=Mock(side_effect=lambda method, **kwargs: {'verification_policy': {'visible': eligible, 'categories': ['Site Visit']}} if kwargs['action'] == 'verification_policy' else {'otp_generation': {'event_id': 'EVENT-1', 'otp_ready': True}}),
            db=SimpleNamespace(commit=Mock(), exists=Mock(return_value=duplicate), get_value=Mock(side_effect=lambda dt, *args, **kwargs: otp if dt == 'Event' else Row(title='Customer',contact_mobile=mobile))),
            make_post_request=Mock(return_value=provider_response if provider_response is not None else {'result': True, 'error': None, 'receivers': [{'waId': '919876543210', 'localMessageId': 'wati-1', 'isValidWhatsAppNumber': True, 'errors': []}]} if accepted else {}, side_effect=provider_error), get_doc=Mock(side_effect=get_doc), log_error=Mock(),
            throw=Mock(side_effect=lambda msg: (_ for _ in ()).throw(ValueError(msg))))
        exec(source, {'frappe': f, 'doc': event})
        return f, event

    def test_only_completed_checkout_sends_existing_otp(self):
        f, event = self.send()
        self.assertEqual(event.custom_otp, '123456')
        payload = f.make_post_request.call_args.kwargs['json']
        self.assertEqual(payload['receivers'][0]['whatsappNumber'], '919876543210')
        self.assertEqual(payload['receivers'][0]['customParams'], [{'name':'otp_code','value':'123456'}])
        self.assertEqual(f.make_post_request.call_args.kwargs['headers']['Authorization'], 'Bearer test-token')
        self.assertEqual(f.make_post_request.call_args.args[0], 'https://live-mt-server.wati.io/423524/api/v1/sendTemplateMessages')
        self.assertEqual(f.make_post_request.call_args.kwargs['headers']['Accept'], 'application/json')
        self.assertNotIn('timeout', f.make_post_request.call_args.kwargs)
        self.assertNotIn('123456', str(f.get_doc.call_args))
        f.log_error.assert_not_called()

    def test_webhook_bearer_header_is_used_once_without_another_prefix(self):
        f, _ = self.send(token='Bearer existing-wati-token')
        self.assertEqual(f.make_post_request.call_args.kwargs['headers']['Authorization'], 'Bearer existing-wati-token')

    def test_missing_or_remarketing_template_is_not_sent_as_an_otp(self):
        for config in [{'template_name':''}, {'otp_parameter':''}, {'template_name':'remarketing_rnr'}]:
            with self.subTest(config=config):
                f, _ = self.send(**config)
                f.make_post_request.assert_not_called()
                self.assertIn('Validate approved WATI OTP template', f.log_error.call_args.kwargs['message'])

    def test_credentials_are_not_sent_to_an_unexpected_webhook_destination(self):
        f, _ = self.send(webhook_url='https://example.test/messages')
        f.make_post_request.assert_not_called()
        self.assertIn('BioSTP Request URL', f.log_error.call_args.kwargs['message'])

    def test_wati_business_failure_is_not_treated_as_accepted(self):
        for response in [{'result':False,'error':'template rejected'},
                         {'result':True,'receivers':[]},
                         {'result':True,'receivers':[{'waId':'other','localMessageId':'id'}]}]:
            with self.subTest(response=response):
                f, _ = self.send(provider_response=response)
                f.acceptance_insert.assert_not_called()
                f.log_error.assert_called_once()

    def test_actual_wati_v1_batch_response_is_accepted_without_recipient_ids(self):
        response = {'result':True, 'errors':{'error':'', 'invalidWhatsappNumbers':[], 'invalidCustomParameters':[]}}
        f, _ = self.send(provider_response=response)
        f.acceptance_insert.assert_called_once()
        f.log_error.assert_not_called()

    def test_wati_batch_response_with_validation_errors_is_rejected(self):
        for errors in [{'error':'template not found', 'invalidWhatsappNumbers':[], 'invalidCustomParameters':[]},
                       {'error':'', 'invalidWhatsappNumbers':['919876543210'], 'invalidCustomParameters':[]},
                       {'error':'', 'invalidWhatsappNumbers':[], 'invalidCustomParameters':['1']},
                       {'error':''}, {'error':'', 'invalidWhatsappNumbers':None,'invalidCustomParameters':[]}]:
            with self.subTest(errors=errors):
                f, _ = self.send(provider_response={'result':True,'errors':errors})
                f.acceptance_insert.assert_not_called()
                f.log_error.assert_called_once()

    def test_unconfirmed_wati_response_shape_is_logged_without_otp_or_phone(self):
        f, _ = self.send(provider_response={'result':True, 'receivers':[
            {'whatsappNumber':'919876543210','customParams':[{'name':'1','value':'123456'}]}]})
        log = f.log_error.call_args.kwargs['message']
        self.assertIn('WATI response:', log)
        self.assertIn('whatsappNumber', log)
        self.assertNotIn('919876543210', log)
        self.assertNotIn('123456', log)

    def test_request_error_log_has_stage_and_redacts_sensitive_values(self):
        f, event = self.send(provider_error=RuntimeError('HTTP 401 test-token 123456 919876543210 9876543210'))
        log = f.log_error.call_args.kwargs['message']
        self.assertIn('Stage: Send WhatsApp template request to WATI', log)
        self.assertIn('Source: event_visit_report / send_checkout_otp', log)
        self.assertIn('HTTP 401', log)
        for value in ['test-token', '123456', '919876543210', '9876543210']:
            self.assertNotIn(value, log)
        self.assertEqual(event.status, 'Completed')
        f.acceptance_insert.assert_not_called()

    def test_unconfirmed_provider_response_is_logged_without_secrets(self):
        f, _ = self.send(provider_response={'error': 'Invalid recipient 919876543210 for OTP 123456'})
        log = f.log_error.call_args.kwargs['message']
        self.assertIn('Check WATI acceptance response', log)
        self.assertIn('Invalid recipient', log)
        self.assertNotIn('919876543210', log)
        self.assertNotIn('123456', log)

    def test_http_404_log_includes_redacted_provider_response(self):
        error = RuntimeError('404 Client Error')
        error.response = SimpleNamespace(status_code=404,
            text='{"error":"Channel not found","token":"test-token","to":"919876543210","otp":"123456"}')
        f, _ = self.send(provider_error=error)
        log = f.log_error.call_args.kwargs['message']
        self.assertIn('HTTP status: 404', log)
        self.assertIn('Channel not found', log)
        for secret in ['test-token', '919876543210', '123456']:
            self.assertNotIn(secret, log)

    def test_insert_routine_save_ineligible_duplicate_do_not_send(self):
        for config in [dict(completed=False), dict(eligible=False), dict(duplicate=True),
                       dict(previous_checkout='2026-11-18 12:00:00',previous_status='Completed')]:
            with self.subTest(config=config):
                f, _ = self.send(**config)
                f.make_post_request.assert_not_called()

    def test_failure_missing_token_or_otp_does_not_undo_completion(self):
        for config in [dict(accepted=False), dict(otp=''), dict(token=''), dict(mobile='')]:
            with self.subTest(config=config):
                f, event = self.send(**config)
                self.assertEqual(event.status, 'Completed')
                f.acceptance_insert.assert_not_called()
                f.log_error.assert_called_once()


class ScriptCompatibilityTest(unittest.TestCase):
    def test_mobile_detail_and_history_do_not_disclose_otp_fields(self):
        for name in ['api_utils.py', 'api_single_device_updated.py']:
            tree = ast.parse((ROOT / 'backend_patches' / name).read_text())
            functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in ['event_details', 'history_list']]
            for node in functions: node.decorator_list = []
            secret_row = Row(name='EVENT-1', custom_otp='123456', custom_validate='654321', custom_whats_app='old')
            doc = Row(as_dict=lambda: dict(secret_row))
            f = SimpleNamespace(get_doc=Mock(return_value=doc), throw=Mock(),
                get_all=Mock(side_effect=lambda dt, **kwargs: [Row(reference_name='EVENT-1')] if dt == 'ToDo' else [dict(secret_row)]))
            scope = {'frappe': f, '_ensure_event_access': lambda *args: None, '_ensure_own_user': lambda *args, **kwargs: None}
            exec(compile(ast.Module(body=functions, type_ignores=[]), name, 'exec'), scope)
            detail = scope['event_details']('EVENT-1')['event']
            history = scope['history_list']('fe@test')[0]
            for field in ['custom_otp', 'custom_validate', 'custom_whats_app']:
                self.assertNotIn(field, detail)
                self.assertNotIn(field, history)
            self.assertEqual(detail['name'], 'EVENT-1')

    def test_restricted_scripts_do_not_define_functions_or_import(self):
        for name in ['event_visit_report_api.py', 'event_checkout_send_otp.py']:
            tree = ast.parse((ROOT / 'frappe_server_scripts' / name).read_text())
            self.assertFalse(any(isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.AsyncFunctionDef)) for node in ast.walk(tree)), name)


if __name__ == '__main__':
    unittest.main()
