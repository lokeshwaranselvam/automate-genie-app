"""Local integration: real checkout -> sender -> API, using fake DB/WHAPI I/O.

These tests do not claim live Frappe field permissions or WhatsApp delivery.
"""
import ast
from datetime import datetime
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock
from test.business_policy_stub import install
from test.visit_verification_test import Row

ROOT = Path(__file__).resolve().parents[1]


class VerificationFlow(unittest.TestCase):
    def setup_flow(self, filename='api_utils.py', *, eligible=True, fail_generation=False, fail_send=False,
                   has_number_log_field=True):
        self.event = Row(name='EVENT-1', owner='fe@test', status='Open', starts_on='2026-11-18',
            custom_check_in='2026-11-18 09:00:00', custom_check_out=None,
            custom_otp='', custom_validate='', description='', event_category='Site Visit',
            event_participants=[Row(reference_doctype='Opportunity', reference_docname='OPP-1')])
        self.previous = Row(self.event)
        self.logs = []
        self.comments = []
        self.requests = []
        self.codes_generated = 0
        self.jobs = []
        self.last_job = None
        self.sender = (ROOT / 'frappe_server_scripts/event_checkout_send_otp.py').read_text()
        self.api = (ROOT / 'frappe_server_scripts/event_visit_report_api.py').read_text()
        if eligible:
            self.api = self.api.replace('VERIFICATION_USERS = []', 'VERIFICATION_USERS = ["fe@test"]')

        def throw(message): raise ValueError(message)
        def get_doc(doctype, name=None, **kwargs):
            if isinstance(doctype, dict):
                data = Row(doctype)
                data.owner = 'fe@test'
                data.save = lambda **kwargs: None
                data.name = 'LOG-1' if data.doctype == 'Number Log' else 'COMMENT-' + str(len(self.comments))
                def insert(**kwargs):
                    (self.logs if data.doctype == 'Number Log' else self.comments).append(data)
                    return data
                data.insert = insert
                return data
            if doctype == 'Webhook':
                return Row(request_url='https://live-mt-server.wati.io/423524/api/v1/sendTemplateMessages',
                    webhook_headers=[Row(key='Authorization', value='Bearer test-token')])
            if doctype == 'Comment': return next(row for row in self.comments if row.name == name)
            if doctype == 'Event': return self.event
            raise AssertionError(doctype)
        def get_value(doctype, name, fields, **kwargs):
            if doctype == 'Webhook':
                return Row(request_url='https://live-mt-server.wati.io/423524/api/v1/sendTemplateMessages',
                    webhook_headers=[Row(key='Authorization', value='Bearer test-token')])
            if doctype == 'Comment': return next(row for row in self.comments if row.name == name)
            if doctype == 'Event': return self.event.get(fields)
            if doctype == 'Number Log': return self.logs[0] if self.logs else None
            if doctype == 'Opportunity': return Row(title='Customer', contact_mobile='9876543210')
            return None
        def set_value(doctype, name, field, value, **kwargs):
            self.assertEqual(doctype, 'Event')
            if field == 'number_log' and not has_number_log_field:
                raise RuntimeError("Unknown column 'number_log' in 'SET'")
            self.event[field] = value
        def exists(doctype, filters):
            if doctype == 'Comment': return any(row.get('subject') == filters.get('subject') for row in self.comments)
            return False
        def sql(*args, **kwargs):
            if fail_generation: raise RuntimeError('RANDOM_BYTES unavailable')
            self.codes_generated += 1
            return [Row(otp='012345')]
        def send(url, **kwargs):
            self.requests.append(kwargs['json'])
            if fail_send: raise RuntimeError('provider unavailable')
            return {'result': True, 'errors': {'error':'', 'invalidWhatsappNumbers':[], 'invalidCustomParameters':[]}}
        def get_all(doctype, **kwargs):
            if doctype == 'Event': return [self.event]
            if doctype == 'Event Participants': return [Row(parent='EVENT-1', email='fe@test')]
            if doctype == 'Comment': return [row for row in self.comments if row.get('subject') == 'Genie OTP attempt']
            return []

        self.frappe = SimpleNamespace(session=Row(user='fe@test'), flags=Row(), form_dict=Row(), response={},
            db=SimpleNamespace(get_value=get_value, set_value=set_value, exists=exists, sql=sql, rollback=Mock(), commit=Mock()),
            get_doc=get_doc, get_all=get_all, log_error=Mock(), throw=throw, get_traceback=lambda: 'trace', ValidationError=ValueError,
            get_meta=lambda dt: SimpleNamespace(get_field=lambda field: has_number_log_field),
            enqueue=lambda method, **kwargs: self.jobs.append((method, kwargs)),
            make_post_request=send, utils=SimpleNamespace(now_datetime=lambda: datetime(2026, 11, 18, 10),
                add_to_date=lambda *args, **kwargs: '2026-11-18 09:45:00', today=lambda: '2026-11-18'))
        def dispatch(method, **kwargs):
            self.assertEqual(method, 'event_visit_report')
            form, flags = self.frappe.form_dict, self.frappe.flags
            self.frappe.form_dict, self.frappe.flags = Row(kwargs), Row()
            try:
                exec(compile(self.api, method, 'exec'), {'frappe': self.frappe, 'json': json})
                return dict(self.frappe.flags)
            finally:
                self.frappe.form_dict, self.frappe.flags = form, flags
        self.frappe.call = dispatch
        install(self.frappe)

        def save(**kwargs):
            exec(compile(self.sender, 'event_checkout_send_otp.py', 'exec'), {'frappe': self.frappe, 'doc': self.event})
            self.previous = Row(self.event)
        self.event.get_doc_before_save = lambda: self.previous
        self.event.save = save
        source = (ROOT / 'backend_patches' / filename).read_text().replace('        from frappe.utils.safe_exec import call_whitelisted_function', '')
        node = next(n for n in ast.parse(source).body if isinstance(n, ast.FunctionDef) and n.name == 'event_checkout')
        node.decorator_list = []
        scope = {'frappe': self.frappe, 'now_datetime': lambda: datetime(2026, 11, 18, 10),
            'call_whitelisted_function': lambda *args, **kwargs: {'policy': {'actions': {'check_out': {'allowed': True, 'reason': ''}}}}}
        exec(compile(ast.Module(body=[node], type_ignores=[]), filename, 'exec'), scope)
        self.checkout = scope['event_checkout']

    def drain_jobs(self):
        while self.jobs:
            method, args = self.jobs.pop(0)
            self.assertTrue(args['enqueue_after_commit'])
            self.assertTrue(args['is_async'])
            self.last_job = (method, args)
            self.assertEqual(method, 'event_visit_report')
            self.assertEqual(args['action'], 'send_checkout_otp')
            self.frappe.call(method, action=args['action'], event_id=args['event_id'], ticket_id=args['ticket_id'])

    def call_api(self, action, **kwargs):
        self.frappe.response = {}
        flags = self.frappe.call('event_visit_report', action=action, event_id='EVENT-1', **kwargs)
        return self.frappe.response.get('message') or flags

    def test_checkout_generation_send_wrong_then_correct_verification_for_both_backends(self):
        for filename in ['api_utils.py', 'api_single_device_updated.py']:
            with self.subTest(filename=filename):
                self.setup_flow(filename)
                result = self.checkout('fe@test', 'EVENT-1', address='Site', working_hrs='01:00')
                self.assertEqual(result['status'], 'success')
                self.assertEqual(self.event.status, 'Completed')
                self.assertEqual(self.requests, [])
                self.assertEqual(self.codes_generated, 0)
                self.drain_jobs()
                self.assertEqual(self.event.custom_otp, '012345')
                self.assertEqual(self.event.number_log, 'LOG-1')
                self.assertEqual(self.codes_generated, 1)
                self.assertEqual(len(self.logs), 1)
                self.assertEqual(len(self.requests), 1)
                self.assertEqual(self.requests[0]['receivers'][0]['customParams'], [{'name':'1','value':'012345'}])
                self.assertNotIn('message', self.frappe.response)  # Sender cannot clobber checkout response.
                self.assertFalse(self.call_api('verify', custom_validate='654321')['is_verified'])
                self.assertEqual(self.event.custom_validate, '')
                self.assertTrue(self.call_api('verify', custom_validate='012345')['is_verified'])
                self.assertEqual(self.event.custom_validate, '012345')
                self.assertEqual(self.event.status, 'Completed')
                self.call_api('ensure_otp')
                self.event.save()
                self.assertEqual(self.codes_generated, 1)
                self.assertEqual(len(self.requests), 1)
                states = self.call_api('verification_states', event_ids='["EVENT-1"]')
                self.assertTrue(states['events'][0]['is_verified'])
                self.assertNotIn('custom_otp', str(states))
                self.assertTrue(self.call_api('verify', custom_validate='654321')['is_verified'])
                self.assertEqual(self.event.custom_validate, '012345')

    def test_generation_or_delivery_failure_never_undoes_checkout(self):
        for config in [{'fail_generation': True}, {'fail_send': True}]:
            with self.subTest(config=config):
                self.setup_flow(**config)
                self.assertEqual(self.checkout('fe@test', 'EVENT-1')['status'], 'success')
                self.assertEqual(self.event.status, 'Completed')
                self.assertEqual(self.event.custom_validate, '')
                self.assertEqual(self.requests, [])
                self.drain_jobs()
                self.frappe.db.rollback.assert_not_called()
                self.frappe.log_error.assert_called_once()

    def test_missing_optional_number_log_field_still_sends_and_verifies(self):
        self.setup_flow(has_number_log_field=False)
        self.assertEqual(self.checkout('fe@test', 'EVENT-1')['status'], 'success')
        self.drain_jobs()
        self.assertEqual(len(self.logs), 1)
        self.assertEqual(len(self.requests), 1)
        self.assertNotIn('number_log', self.event)
        self.assertTrue(self.call_api('verify', custom_validate='012345')['is_verified'])
        self.frappe.log_error.assert_not_called()

    def test_excluded_user_has_normal_checkout_without_generation_or_sending(self):
        self.setup_flow(eligible=False)
        self.assertEqual(self.checkout('fe@test', 'EVENT-1')['status'], 'success')
        self.assertEqual(self.codes_generated, 0)
        self.assertEqual(self.requests, [])
        with self.assertRaisesRegex(ValueError, 'not enabled'):
            self.call_api('verify', custom_validate='012345')

    def test_replayed_worker_ticket_cannot_send_twice_after_timeout(self):
        self.setup_flow(fail_send=True)
        self.checkout('fe@test', 'EVENT-1')
        self.assertEqual(self.requests, [])
        self.drain_jobs()
        self.assertEqual(len(self.requests), 1)
        method, args = self.last_job
        self.frappe.call(method, action=args['action'], event_id=args['event_id'], ticket_id=args['ticket_id'])
        self.assertEqual(len(self.requests), 1)
        self.assertGreater(self.frappe.db.commit.call_count, 0)

    def test_unrelated_user_cannot_run_another_users_delivery_ticket(self):
        self.setup_flow()
        self.checkout('fe@test', 'EVENT-1')
        method, args = self.jobs[0]
        self.frappe.session.user = 'other@test'
        with self.assertRaisesRegex(ValueError, 'does not belong'):
            self.frappe.call(method, action=args['action'], event_id=args['event_id'], ticket_id=args['ticket_id'])
        self.assertEqual(self.requests, [])

    def test_queue_failure_preserves_checkout_without_synchronous_fallback(self):
        self.setup_flow()
        self.frappe.enqueue = Mock(side_effect=RuntimeError('Redis unavailable'))
        self.assertEqual(self.checkout('fe@test', 'EVENT-1')['status'], 'success')
        self.assertEqual(self.requests, [])
        self.assertEqual(self.codes_generated, 0)
        self.frappe.log_error.assert_called_once()

    def test_five_bad_attempts_block_further_attempt_without_reopening_event(self):
        self.setup_flow()
        self.checkout('fe@test', 'EVENT-1')
        self.drain_jobs()
        for _ in range(5):
            self.assertFalse(self.call_api('verify', custom_validate='654321')['is_verified'])
        with self.assertRaisesRegex(ValueError, 'Too many'):
            self.call_api('verify', custom_validate='012345')
        self.assertEqual(self.event.status, 'Completed')
        self.assertEqual(len(self.requests), 1)


if __name__ == '__main__':
    unittest.main()
