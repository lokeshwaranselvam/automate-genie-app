import json
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock
import unittest
from test.business_policy_stub import install, Row

ROOT = Path(__file__).resolve().parents[1]

class MobileBusinessPolicyTest(unittest.TestCase):
    def setUp(self):
        self.event = Row(owner='user@example.test', starts_on='2026-10-26', custom_check_in=None, custom_check_out=None)
        self.attendance = [Row(log_type='IN', time='2026-10-26 09:00:00')]
        self.other_visit = False
        self.roles = []
        self.frappe = SimpleNamespace(
            session=Row(user='user@example.test'), response={}, form_dict={}, flags=Row(),
            utils=SimpleNamespace(today=lambda: '2026-10-26', getdate=lambda value: datetime.fromisoformat(str(value)).date()),
            get_doc=Mock(return_value=self.event), get_all=Mock(side_effect=lambda *a, **k: self.attendance),
            db=SimpleNamespace(get_value=Mock(return_value='EMP-1'), count=Mock(return_value=0),
                exists=Mock(side_effect=lambda doctype, filters: self.other_visit if doctype == 'Visit' else bool(self.roles))),
            throw=lambda msg: (_ for _ in ()).throw(ValueError(msg)),
        )
        self.bridge = install(self.frappe)

    def policy(self, feature='visit', **kwargs):
        return self.bridge('mobile_business_policy', feature=feature, **kwargs)['policy']

    def override(self, feature, values):
        self.bridge.overrides['policy_by_user = {}'] = 'policy_by_user = ' + repr({'user@example.test': {feature: values}})


    def test_visit_actions_use_authenticated_assignment_and_current_attendance(self):
        self.assertTrue(self.policy(event_id='EVENT-1')['actions']['check_in']['allowed'])
        self.attendance = []
        self.assertFalse(self.policy(event_id='EVENT-1')['actions']['check_in']['allowed'])
        self.override('visit', {'rules': {'attendance_exempt_roles': ['Sales User']}})
        self.roles = ['Sales User']
        self.assertTrue(self.policy(event_id='EVENT-1')['actions']['check_in']['allowed'])
        self.event.owner = 'other@example.test'
        self.assertEqual(self.policy(event_id='EVENT-1')['actions']['check_in']['reason'], 'This Event is not assigned to your user.')

    def test_event_day_and_multiple_active_visit_rules_can_be_changed(self):
        self.event.starts_on = '2026-10-25'
        self.assertFalse(self.policy(event_id='EVENT-1')['actions']['check_in']['allowed'])
        self.override('visit', {'rules': {'event_day_only': False}})
        self.other_visit = True
        self.assertFalse(self.policy(event_id='EVENT-1')['actions']['check_in']['allowed'])
        self.override('visit', {'rules': {'event_day_only': False, 'allow_multiple_active_visits': True}})
        self.assertTrue(self.policy(event_id='EVENT-1')['actions']['check_in']['allowed'])
        self.event.custom_check_in = '2026-10-26 10:00:00'
        self.event.event_category = 'Other'
        self.assertTrue(self.policy(event_id='EVENT-1')['actions']['check_out']['allowed'])
        self.assertFalse(self.policy(event_id='EVENT-1')['actions']['check_in']['allowed'])

    def test_fields_enforce_required_maximum_choices_and_read_only_defaults(self):
        self.override('visit', {'fields': {'summary': {'required': False, 'max_length': 3},
            'product_enquired': {'options': ['Windows']}}})
        self.policy(action='validate', values={'summary': '', 'assigned_to': 'user', 'product_enquired': 'Windows'})
        with self.assertRaisesRegex(ValueError, 'too long'):
            self.policy(action='validate', values={'summary': 'long', 'assigned_to': 'user'})
        with self.assertRaisesRegex(ValueError, 'valid'):
            self.policy(action='validate', values={'summary': '', 'assigned_to': 'user', 'product_enquired': 'Other'})
        self.override('visit', {'fields': {'summary': {'read_only': True, 'default': 'Server'}}})
        with self.assertRaisesRegex(ValueError, 'read-only'):
            self.policy(action='validate', values={'summary': 'Client', 'assigned_to': 'user'})

    def test_leave_window_duration_and_half_day_configuration(self):
        self.override('leave', {'rules': {'earliest_date': '2026-11-01', 'latest_date': '2026-11-30', 'max_days': 2, 'half_day_allowed': False}})
        base = {'leave_type': 'Annual', 'description': 'Reason', 'from_date': '2026-11-02', 'to_date': '2026-11-03'}
        self.policy('leave', action='validate', values=base)
        for override in [{'from_date': '2026-10-30'}, {'to_date': '2026-11-04'}, {'half_day': True}]:
            with self.subTest(override=override), self.assertRaises(ValueError):
                self.policy('leave', action='validate', values=dict(base, **override))

    def test_upload_rules_validate_size_format_and_count(self):
        self.override('visit', {'uploads': {'max_bytes': 10, 'max_count': 2, 'extensions': ['.jpg']}})
        self.policy(action='upload', file_name='PHOTO.JPG', file_size=10, file_count=2)
        for override in [{'file_size': 11}, {'file_count': 3}, {'file_name': 'file.exe'}]:
            args = dict(file_name='photo.jpg', file_size=10, file_count=2); args.update(override)
            with self.subTest(override=override), self.assertRaises(ValueError): self.policy(action='upload', **args)

    def test_file_guard_uses_actual_content_size_not_claimed_file_size(self):
        self.override('visit', {'uploads': {'max_bytes': 10}})
        doc = Row(name='FILE-1', attached_to_doctype='Event', attached_to_name='EVENT-1',
                  file_name='photo.jpg', file_size=1, file_url='/files/photo.jpg', is_folder=0)
        doc.get_content = lambda: b'x' * 11
        script = (ROOT / 'frappe_server_scripts/mobile_file_policy_guard.py').read_text()
        with self.assertRaisesRegex(ValueError, 'file size'):
            exec(compile(script, 'mobile_file_policy_guard.py', 'exec'), {'frappe': self.frappe, 'doc': doc})

    def test_disabled_actions_and_missing_event_date_return_reasons(self):
        self.event.starts_on = None
        result = self.policy(event_id='EVENT-1')['actions']
        self.assertFalse(result['check_in']['allowed'])
        self.assertIn('event day', result['check_in']['reason'])
        self.event.starts_on = '2026-10-26'
        self.override('visit', {'rules': {'check_in_enabled': False, 'check_in_disabled_reason': 'Temporarily paused'}})
        self.assertEqual(self.policy(event_id='EVENT-1')['actions']['check_in']['reason'], 'Temporarily paused')

    def test_nested_calls_explicitly_override_parent_action_and_event(self):
        self.frappe.form_dict = {'action': 'save', 'event_id': 'UNRELATED'}
        result = self.policy(action='get', event_id='')
        self.assertNotIn('actions', result)
        self.frappe.get_doc.assert_not_called()
        self.assertEqual(self.frappe.form_dict['action'], 'save')

    def test_photo_requirement_separates_upload_preparation_from_checkout(self):
        self.event.custom_check_in = '2026-10-26 10:00:00'
        self.override('visit', {'uploads': {'min_count': 1}})
        policy = self.policy(event_id='EVENT-1')
        self.assertFalse(policy['actions']['check_out']['allowed'])
        self.assertTrue(policy['actions']['check_out']['can_prepare'])
        self.assertEqual(policy['uploads']['current_count'], 0)
        self.roles = ['File exists']
        policy = self.policy(event_id='EVENT-1')
        self.assertTrue(policy['actions']['check_out']['allowed'])
        self.assertEqual(policy['uploads']['current_count'], 1)

    def test_attachment_categories_and_checkout_requirements(self):
        self.event.custom_check_in = '2026-10-26 10:00:00'
        exempt = ['Other', 'Others', 'Bank', 'Head Office', 'Head Office CH',
                  'Timbe Office', 'Timbe / Bioman Office CH', 'Measurement',
                  'Installation', 'Collection', 'Maintenance', '  MEASUREMENT  ']
        for category in exempt + ['Site Visit', 'Complaint Visit']:
            with self.subTest(category=category):
                self.event.event_category = category
                self.roles = []
                policy = self.policy(event_id='EVENT-1')
                self.assertEqual(policy['uploads']['min_count'], 0 if category in exempt else 1)
                self.assertEqual(policy['uploads']['max_count'], 0)
                self.assertEqual(policy['actions']['check_out']['allowed'], category in exempt)
                if category not in exempt:
                    self.assertTrue(policy['actions']['check_out']['can_prepare'])
                    self.roles = ['File exists']
                    self.assertTrue(self.policy(event_id='EVENT-1')['actions']['check_out']['allowed'])

    def test_attachment_exemptions_do_not_bypass_assignment_or_date(self):
        self.event.event_category = 'Bank'
        self.event.custom_check_in = '2026-10-26 10:00:00'
        self.event.owner = 'other@example.test'
        self.assertEqual(self.policy(event_id='EVENT-1')['actions']['check_out']['reason'],
                         'This Event is not assigned to your user.')
        self.event.owner = 'user@example.test'
        self.event.starts_on = '2026-10-25'
        self.assertIn('event day', self.policy(event_id='EVENT-1')['actions']['check_out']['reason'])

    def test_guest_and_unknown_feature_fail_without_loading_documents(self):
        with self.assertRaisesRegex(ValueError, 'supported'):
            self.policy('unknown')
        self.frappe.session.user = 'Guest'
        with self.assertRaisesRegex(ValueError, 'Sign in'):
            self.policy(event_id='EVENT-1')
        self.frappe.get_doc.assert_not_called()

if __name__ == '__main__': unittest.main()
