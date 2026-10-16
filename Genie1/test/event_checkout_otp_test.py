"""OTP must block checkout before any Visit writes or route requests."""
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


class EventCheckoutOtpTest(unittest.TestCase):
    def run_checkout(self, filename, otp=None, saved_otp=None, checked_in=True, checked_out=False):
        doc = Row(custom_check_in='2026-10-16 09:00:00' if checked_in else None,
                  custom_check_out='2026-10-16 10:00:00' if checked_out else None,
                  custom_otp=saved_otp)
        doc.save = Mock()
        frappe = SimpleNamespace(
            get_doc=Mock(return_value=doc),
            db=SimpleNamespace(exists=Mock(return_value=False), rollback=Mock()),
            log_error=Mock(), get_traceback=lambda: 'trace',
        )
        tree = ast.parse((ROOT / 'backend_patches' / filename).read_text(encoding='utf-8'))
        function = next(node for node in tree.body
                        if isinstance(node, ast.FunctionDef) and node.name == 'event_checkout')
        function.decorator_list = []
        module = ast.Module(body=[function], type_ignores=[])
        namespace = dict(frappe=frappe, now_datetime=lambda: datetime(2026, 10, 16, 10))
        exec(compile(module, filename, 'exec'), namespace)
        result = namespace['event_checkout'](
            'sales@example.test', 'EVENT-1', custom_otp=otp,
            address='Site', working_hrs='01:00',
        )
        return result, doc, frappe

    def test_empty_invalid_or_missing_otp_cannot_start_checkout_writes(self):
        for filename in ['api.py', 'api_single_device_updated.py']:
            for otp in [None, '', '   ', 123, []]:
                with self.subTest(filename=filename, otp=otp):
                    result, doc, frappe = self.run_checkout(filename, otp)
                    self.assertEqual(result['status'], 'error')
                    self.assertIn('OTP is required', result['message'])
                    frappe.db.exists.assert_not_called()
                    doc.save.assert_not_called()
                    self.assertIsNone(doc.custom_check_out)

    def test_otp_and_checkout_are_saved_together_preserving_leading_zeroes(self):
        for filename in ['api.py', 'api_single_device_updated.py']:
            with self.subTest(filename=filename):
                result, doc, _ = self.run_checkout(filename, ' 0123 ')
                self.assertEqual(result['status'], 'success')
                self.assertEqual(doc.custom_otp, '0123')
                self.assertEqual(doc.status, 'Completed')
                self.assertEqual(doc.custom_check_out_location, 'Site')
                doc.save.assert_called_once_with(ignore_permissions=True)

    def test_checkout_rejects_short_long_or_nonnumeric_otp_before_writes(self):
        for filename in ['api.py', 'api_single_device_updated.py']:
            for otp in ['1', '123', '12345', '123456', '12a4', '12 4', '１２３４']:
                with self.subTest(filename=filename, otp=otp):
                    result, doc, frappe = self.run_checkout(filename, otp)
                    self.assertEqual(result['status'], 'error')
                    self.assertIn('exactly 4 digits', result['message'])
                    doc.save.assert_not_called()
                    frappe.db.exists.assert_not_called()

    def test_previously_saved_otp_is_preserved_when_parameter_is_omitted(self):
        result, doc, _ = self.run_checkout('api.py', saved_otp='0123')
        self.assertEqual(result['status'], 'success')
        self.assertEqual(doc.custom_otp, '0123')

    def test_explicit_blank_cannot_replace_saved_otp(self):
        result, doc, _ = self.run_checkout('api.py', ' ', saved_otp='0123')
        self.assertEqual(result['status'], 'error')
        doc.save.assert_not_called()

    def test_existing_checkin_and_completed_checks_are_preserved(self):
        for kwargs, message in [
            ({'checked_in': False}, 'Cannot check out before check-in'),
            ({'checked_out': True}, 'Already Checked Out'),
        ]:
            result, doc, _ = self.run_checkout('api.py', **kwargs)
            self.assertEqual(result['message'], message)
            doc.save.assert_not_called()


class EventVisitReportOtpTest(unittest.TestCase):
    def report(self, params=None, owner='sales@example.test', description='', otp='0123', clear_on_save=False):
        event = Row(name='EVENT-1', owner=owner, description=description, custom_otp=otp)
        event.save = Mock()
        if clear_on_save:
            event.save.side_effect = lambda **kwargs: event.update(custom_otp='')
        response = {}
        frappe = SimpleNamespace(
            session=SimpleNamespace(user='sales@example.test'),
            form_dict=dict(event_id='EVENT-1', **(params or {})),
            get_doc=Mock(return_value=event), response=response,
            db=SimpleNamespace(get_value=Mock(side_effect=lambda *args: event.get('custom_otp'))),
            throw=Mock(side_effect=lambda message: (_ for _ in ()).throw(ValueError(message))),
        )
        script = (ROOT / 'frappe_server_scripts/event_visit_report_api.py').read_text()
        exec(compile(script, 'event_visit_report_api.py', 'exec'), {'frappe': frappe})
        return response['message'], event

    def test_get_includes_saved_otp_without_modifying_event(self):
        result, event = self.report()
        self.assertEqual(result['custom_otp'], '0123')
        event.save.assert_not_called()

    def test_save_otp_persists_independently_without_requiring_report(self):
        result, event = self.report(dict(action='save_otp', custom_otp=' 0123 '),
                                    description='Existing notes', otp='')
        self.assertEqual(event.custom_otp, '0123')
        self.assertEqual(event.description, 'Existing notes')
        self.assertEqual(result['action'], 'save_otp')
        self.assertTrue(result['otp_saved'])
        self.assertEqual(result['custom_otp'], '0123')
        event.save.assert_called_once_with(ignore_permissions=True)

    def test_save_otp_rejects_empty_and_unassigned_requests(self):
        for otp in [None, '', ' ', 123]:
            with self.subTest(otp=otp), self.assertRaisesRegex(ValueError, 'OTP is required'):
                self.report(dict(action='save_otp', custom_otp=otp))
        with self.assertRaisesRegex(ValueError, 'not assigned'):
            self.report(dict(action='save_otp', custom_otp='0123'), owner='other@example.test')

    def test_save_otp_detects_a_hook_clearing_the_field(self):
        with self.assertRaisesRegex(ValueError, 'OTP could not be saved'):
            self.report(dict(action='save_otp', custom_otp='0123'), clear_on_save=True)

    def test_both_save_actions_reject_invalid_digit_lengths(self):
        for action in ['save_otp', 'save']:
            for otp in ['1', '123', '12345', '123456', '12a4', '12 4', '１２３４']:
                with self.subTest(action=action, otp=otp), self.assertRaisesRegex(ValueError, 'exactly 4 digits'):
                    self.report(dict(action=action, custom_otp=otp,
                                     observation='Visited', outcome='Interested'))

    def test_save_otp_does_not_unlock_a_submitted_report(self):
        description = 'observation : Visited\nOutcome: Interested'
        _, event = self.report(dict(action='save_otp', custom_otp='0123'), description=description)
        self.assertEqual(event.description, description)

    def test_existing_report_submission_preserves_otp(self):
        result, event = self.report(dict(action='save', observation='Site visited', outcome='Interested'))
        self.assertEqual(result['description'], 'observation : Site visited\nOutcome: Interested')
        self.assertEqual(event.custom_otp, '0123')
        self.assertTrue(result['is_submitted'])
        event.save.assert_called_once_with(ignore_permissions=True)

    def test_optional_otp_is_saved_as_text(self):
        result, event = self.report(dict(action='save', observation='Visited',
                                         outcome='Interested', custom_otp=' 0012 '))
        self.assertEqual(result['custom_otp'], '0012')
        self.assertEqual(event.custom_otp, '0012')

    def test_empty_explicit_otp_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'OTP cannot be empty'):
            self.report(dict(action='save', observation='Visited', outcome='Interested', custom_otp=' '))

    def test_assignment_and_submitted_report_locks_are_preserved(self):
        with self.assertRaisesRegex(ValueError, 'not assigned'):
            self.report(owner='other@example.test')
        with self.assertRaisesRegex(ValueError, 'already been submitted'):
            self.report(dict(action='save', observation='Changed', outcome='Interested'),
                        description='observation : Visited\nOutcome: Interested')


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
