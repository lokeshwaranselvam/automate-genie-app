"""Attachment-only checkout and report contracts, without a live ERP."""
import ast
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]

class Row(dict):
    __getattr__ = dict.get
    __setattr__ = dict.__setitem__

class EventCheckoutAttachmentTest(unittest.TestCase):
    def run_checkout(self, filename, attachment=True, checked_in=True, checked_out=False, otp=None):
        doc = Row(custom_check_in='2026-10-16 09:00:00' if checked_in else None,
                  custom_check_out='2026-10-16 10:00:00' if checked_out else None,
                  custom_otp='historical', custom_whats_app=None)
        doc.save = Mock()
        def exists(doctype, filters):
            if doctype == 'File':
                self.assertEqual(filters, {
                    'attached_to_doctype': 'Event', 'attached_to_name': 'EVENT-1',
                    'is_folder': 0, 'file_url': ['is', 'set'],
                })
                return 'FILE-1' if attachment else None
            self.assertEqual(doctype, 'Visit')
            return False
        frappe = SimpleNamespace(
            get_doc=Mock(return_value=doc),
            db=SimpleNamespace(exists=Mock(side_effect=exists), rollback=Mock()),
            log_error=Mock(), get_traceback=lambda: 'trace',
        )
        tree = ast.parse((ROOT / 'backend_patches' / filename).read_text(encoding='utf-8'))
        node = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'event_checkout')
        node.decorator_list = []
        namespace = dict(frappe=frappe, now_datetime=lambda: datetime(2026, 10, 16, 10))
        exec(compile(ast.Module(body=[node], type_ignores=[]), filename, 'exec'), namespace)
        result = namespace['event_checkout']('sales@example.test', 'EVENT-1',
            custom_otp=otp, address='Site', working_hrs='01:00')
        return result, doc, frappe

    def test_missing_attachment_blocks_before_visit_lookup_or_checkout_writes(self):
        for filename in ['api.py', 'api_single_device_updated.py']:
            with self.subTest(filename=filename):
                result, doc, frappe = self.run_checkout(filename, attachment=False)
                self.assertEqual(result['status'], 'error')
                self.assertIn('Attach a visit photo', result['message'])
                doc.save.assert_not_called()
                self.assertIsNone(doc.custom_check_out)
                self.assertEqual(frappe.db.exists.call_count, 1)

    def test_attachment_allows_checkout_without_any_otp_configuration(self):
        for filename in ['api.py', 'api_single_device_updated.py']:
            for otp in [None, '', 'wrong', 123]:
                with self.subTest(filename=filename, legacy_otp=otp):
                    result, doc, _ = self.run_checkout(filename, otp=otp)
                    self.assertEqual(result['status'], 'success')
                    self.assertEqual(doc.status, 'Completed')
                    self.assertEqual(doc.custom_otp, 'historical')
                    self.assertEqual(doc.custom_check_out_location, 'Site')
                    self.assertEqual(doc.custom_duration, '01:00')
                    doc.save.assert_called_once_with(ignore_permissions=True)

    def test_existing_checkin_and_completed_guards_are_preserved(self):
        for filename in ['api.py', 'api_single_device_updated.py']:
            for kwargs, message in [({'checked_in': False}, 'Cannot check out before check-in'),
                                    ({'checked_out': True}, 'Already Checked Out')]:
                result, doc, frappe = self.run_checkout(filename, **kwargs)
                self.assertEqual(result['message'], message)
                frappe.db.exists.assert_not_called()
                doc.save.assert_not_called()

class EventVisitReportWithoutOtpTest(unittest.TestCase):
    def report(self, params=None, owner='sales@example.test', description='', otp='0123', clear_on_save=False, expected_otp='0123'):
        event = Row(name='EVENT-1', owner=owner, description=description, custom_otp=otp, custom_whats_app=expected_otp, event_category='Site Visit')
        self.last_event = event
        event.save = Mock()
        if clear_on_save:
            event.save.side_effect = lambda **kwargs: event.update(custom_otp='')
        response = {}
        frappe = SimpleNamespace(
            session=SimpleNamespace(user='sales@example.test'),
            form_dict=dict(event_id='EVENT-1', **(params or {})),
            get_doc=Mock(return_value=event), response=response,
            get_all=Mock(return_value=[dict(name='FILE-1', file_name='visit.jpg', file_url='/private/files/visit.jpg', is_private=1)]),
            db=SimpleNamespace(get_value=Mock(side_effect=lambda *args: event.get('custom_otp'))),
            throw=Mock(side_effect=lambda message: (_ for _ in ()).throw(ValueError(message))),
        )
        self.last_frappe = frappe
        script = (ROOT / 'frappe_server_scripts/event_visit_report_api.py').read_text()
        exec(compile(script, 'event_visit_report_api.py', 'exec'), {'frappe': frappe})
        if (params or {}).get('action', 'get') == 'get':
            frappe.get_all.assert_called_once_with(
                'File', filters={'attached_to_doctype': 'Event', 'attached_to_name': 'EVENT-1',
                                 'is_folder': 0, 'file_url': ['is', 'set']},
                fields=['name', 'file_name', 'file_url', 'is_private', 'creation'],
                order_by='creation asc, name asc', limit_page_length=100,
            )
        else:
            frappe.get_all.assert_not_called()
        return response['message'], event


    def test_get_preserves_report_options_and_historical_data(self):
        result, event = self.report(description='observation : Visited\nOutcome: Interested')
        self.assertTrue(result['is_submitted'])
        self.assertEqual(result['observation'], 'Visited')
        self.assertEqual(result['outcome'], 'Interested')
        self.assertEqual(result['custom_otp'], '0123')
        self.assertEqual(result['event_category'], 'Site Visit')
        self.assertEqual(result['attachments'][0]['file_name'], 'visit.jpg')
        event.save.assert_not_called()

    def test_report_saves_without_otp_and_ignores_legacy_otp_parameter(self):
        for params in ({}, {'custom_otp': 'wrong'}, {'custom_otp': ''}):
            result, event = self.report(dict(action='save', observation='Visited',
                                            outcome='Interested', **params), expected_otp=None)
            self.assertTrue(result['is_submitted'])
            self.assertEqual(event.description, 'observation : Visited\nOutcome: Interested')
            self.assertEqual(event.custom_otp, '0123')
            event.save.assert_called_once_with(ignore_permissions=True)

    def test_assignment_and_submitted_report_locks_are_preserved(self):
        with self.assertRaisesRegex(ValueError, 'not assigned'):
            self.report(owner='other@example.test')
        self.last_frappe.get_all.assert_not_called()
        with self.assertRaisesRegex(ValueError, 'already been submitted'):
            self.report(dict(action='save', observation='Changed', outcome='Interested'),
                        description='observation : Visited\nOutcome: Interested')

    def test_observation_and_outcome_validations_remain(self):
        for observation, outcome in [('', 'Interested'), ('Visited', 'invalid')]:
            with self.assertRaises(ValueError):
                self.report(dict(action='save', observation=observation, outcome=outcome))

    def test_retired_otp_action_does_not_modify_event(self):
        with self.assertRaisesRegex(ValueError, 'Invalid action'):
            self.report(dict(action='save_otp', custom_otp='0123'))
        self.last_event.save.assert_not_called()

class EventOtpVerificationTest(unittest.TestCase):
    def load(self, filename):
        event = Row(custom_otp='0123')
        event.save = Mock()
        frappe = SimpleNamespace(get_doc=Mock(return_value=event),
                                 db=SimpleNamespace(commit=Mock()),
                                 msgprint=Mock(), log_error=Mock())
        random = SimpleNamespace(randint=Mock(return_value=1234))
        tree = ast.parse((ROOT / 'backend_patches' / filename).read_text())
        functions = [node for node in tree.body if isinstance(node, ast.FunctionDef)
                     and node.name in ['send_otp', 'verify_otp']]
        for function in functions:
            function.decorator_list = []
        namespace = dict(frappe=frappe, random=random)
        exec(compile(ast.Module(body=functions, type_ignores=[]), filename, 'exec'), namespace)
        return namespace, frappe, random

    def test_generation_uses_four_digits_and_existing_verification_still_matches(self):
        for filename in ['api.py', 'api_single_device_updated.py']:
            with self.subTest(filename=filename):
                api, frappe, random = self.load(filename)
                self.assertEqual(api['verify_otp']('0123', 'EVENT-1')['status'], 'success')
                self.assertEqual(api['verify_otp']('9999', 'EVENT-1')['status'], 'error')
                self.assertEqual(api['send_otp']('EVENT-1')['status'], 'success')
                random.randint.assert_called_once_with(1000, 9999)
                self.assertEqual(frappe.get_doc.return_value.custom_otp, 1234)

    def test_invalid_verification_codes_are_rejected_before_database_lookup(self):
        for filename in ['api.py', 'api_single_device_updated.py']:
            api, frappe, _ = self.load(filename)
            for otp in ['123', '12345', '123456', '12a4']:
                self.assertEqual(api['verify_otp'](otp, 'EVENT-1')['status'], 'error')
            frappe.get_doc.assert_not_called()


if __name__ == '__main__':
    unittest.main()
