from test.business_policy_stub import install as install_business_policy
"""Focused restricted-script contracts, without a live ERP site."""
import json
from datetime import date
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock
import unittest

SCRIPT = (Path(__file__).resolve().parents[1] / 'frappe_server_scripts/mobile_opportunity_policy.py').read_text()

class Row(dict):
    __getattr__ = dict.get
    __setattr__ = dict.__setitem__

class MobileOpportunityPolicyTest(unittest.TestCase):
    def setUp(self):
        self.doc = Row(name='OPP-1', owner='creator@example.test', opportunity_owner='sales@example.test',
                       status='Open', sales_stage='Original stage', modified='2026-10-26 10:00:00',
                       custom_next_followup_date='2026-10-26', notes=[{'name': 'NOTE-1', 'note': 'History'}])
        self.doc.check_permission = Mock()
        self.doc.save = Mock()
        self.doc.apply_fieldlevel_read_permissions = Mock()
        self.doc.as_dict = lambda: {key: value for key, value in self.doc.items() if not callable(value)}
        fields = [Row(fieldname='opportunity_owner', fieldtype='Link', label='Opportunity Owner', options='User'),
                  Row(fieldname='status', fieldtype='Select', label='Status', options='Open\nFollow-up\nDemo\nLost'),
                  Row(fieldname='custom_next_followup_date', fieldtype='Date', label='Next Followup Date'),
                  Row(fieldname='notes', fieldtype='Table', label='Notes', options='CRM Note')]
        meta = SimpleNamespace(fields=fields, get_field=lambda key: next((field for field in fields if field.fieldname == key), None))
        event_meta = SimpleNamespace(get_field=lambda key: Row(fieldtype='Table', options='Event Participants') if key == 'event_participants' else None)
        child_meta = SimpleNamespace(get_field=lambda key: Row(fieldname=key))
        note_meta = SimpleNamespace(get_field=lambda key: Row(fieldname=key) if key in ['note', 'added_by', 'added_on'] else None)
        self.frappe = SimpleNamespace(
            session=Row(user='sales@example.test', csrf_token='csrf'), form_dict={}, response={}, request=SimpleNamespace(method='POST'),
            get_list=Mock(return_value=[]), get_meta=Mock(side_effect=lambda name: event_meta if name == 'Event' else child_meta if name == 'Event Participants' else note_meta if name == 'CRM Note' else meta), get_doc=Mock(return_value=self.doc),
            db=SimpleNamespace(exists=Mock(return_value=True)),
            utils=SimpleNamespace(nowdate=lambda: '2026-10-26', now_datetime=lambda: '2026-10-26 12:34:56', getdate=date.fromisoformat),
            throw=lambda message: (_ for _ in ()).throw(ValueError(message)),
        )

    def run_api(self, action='get', script=SCRIPT, **params):
        if action in ['save', 'change_owner']:
            params.setdefault('csrf_token', 'csrf')
        self.frappe.form_dict = dict(action=action, **params)
        self.frappe.response = {}
        install_business_policy(self.frappe)
        exec(compile(script, 'mobile_opportunity_policy.py', 'exec'), {'frappe': self.frappe, 'json': json})
        return self.frappe.response

    def save(self, changes, **kwargs):
        if 'notes' not in changes and (changes.get('status', self.doc.status) != self.doc.status or 'custom_next_followup_date' in changes):
            changes = dict(changes, notes=self.doc.notes + [{'note': '<p>Reason for change</p>'}])
        return self.run_api(action='save', name='OPP-1', modified=self.doc.modified, changes=changes, **kwargs)

    def test_notes_and_dependencies_are_enforced_from_shared_policy(self):
        with self.assertRaisesRegex(ValueError, 'Note required'):
            self.run_api(action='save', name='OPP-1', modified=self.doc.modified, changes={'status': 'Demo'})
        self.frappe.db.exists.return_value = False
        with self.assertRaisesRegex(ValueError, 'Create an event'):
            self.save({'status': 'Demo'})
        self.doc.save.assert_not_called()
        bridge = install_business_policy(self.frappe)
        bridge.overrides['policy_by_user = {}'] = 'policy_by_user = ' + repr({'sales@example.test': {'opportunity': {
            'rules': {'note_on_status_change': False, 'dependencies': []}}}})
        self.run_api(action='save', name='OPP-1', modified=self.doc.modified, changes={'status': 'Demo'})
        self.doc.save.assert_called_once_with()
        self.assertEqual(self.doc.notes, [{'name': 'NOTE-1', 'note': 'History'}])

    def test_read_only_status_is_enforced_against_the_existing_document(self):
        bridge = install_business_policy(self.frappe)
        bridge.overrides['policy_by_user = {}'] = 'policy_by_user = ' + repr({'sales@example.test': {'opportunity': {
            'fields': {'status': {'read_only': True}}}}})
        with self.assertRaisesRegex(ValueError, 'read-only'):
            self.save({'status': 'Demo'})
        self.doc.save.assert_not_called()
        self.save({'notes': self.doc.notes + [{'note': 'More context'}]})
        self.doc.save.assert_called_once_with()

    def test_existing_note_history_cannot_be_deleted(self):
        with self.assertRaisesRegex(ValueError, 'history'):
            self.save({'status': 'Demo', 'notes': [{'note': 'New note'}]})
        self.doc.save.assert_not_called()

    def test_default_policy_intersects_configured_statuses_and_uses_server_date(self):
        result = self.run_api()['message']
        self.assertEqual(result['current_user'], 'sales@example.test')
        self.assertEqual(result['editable_statuses'], ['Open', 'Follow-up', 'Demo'])
        self.assertEqual(result['followup_policy'], {'allow_past': False, 'earliest_date': '2026-10-26'})
        self.doc.save.assert_not_called()

    def test_csrf_validation_also_applies_when_safe_exec_hides_http_method(self):
        self.frappe.request = {'path': '/api/method/mobile_opportunity_policy'}
        with self.assertRaisesRegex(ValueError, 'update session'):
            self.run_api(action='save', name='OPP-1', modified=self.doc.modified,
                         changes={'status': 'Demo'}, csrf_token='wrong')
        self.doc.save.assert_not_called()
        self.save({'status': 'Demo'})
        self.doc.save.assert_called_once_with()

    def test_save_preserves_owner_history_and_normal_permissions_and_syncs_stage(self):
        result = self.save({'status': 'Follow-up', 'notes': self.doc.notes + [{'note': 'New note'}]})
        self.assertEqual(result['data']['sales_stage'], 'Follow-up')
        self.assertEqual(result['data']['opportunity_owner'], 'sales@example.test')
        self.assertEqual(result['data']['owner'], 'creator@example.test')
        self.assertEqual(result['data']['notes'][0], {'name': 'NOTE-1', 'note': 'History'})
        self.doc.check_permission.assert_any_call('read')
        self.doc.check_permission.assert_any_call('write')
        self.doc.save.assert_called_once_with()

    def test_new_note_uses_session_author_and_server_time_not_client_values(self):
        result = self.save({'notes': self.doc.notes + [{'note': 'Called customer',
            'added_by': 'spoofed@example.test', 'added_on': '2000-01-01 00:00:00'}]})
        note = result['data']['notes'][-1]
        self.assertEqual(note['added_by'], 'sales@example.test')
        self.assertEqual(note['added_on'], '2026-10-26 12:34:56')

    def test_unchanged_note_keeps_its_original_author_and_time(self):
        original = {'name': 'NOTE-1', 'note': 'History', 'added_by': 'original@example.test',
                    'added_on': '2026-10-20 09:00:00'}
        self.doc.notes = [dict(original)]
        tampered = dict(original, added_by='spoofed@example.test', added_on='2099-01-01 00:00:00')
        result = self.save({'notes': [tampered, {'note': 'New note'}]})
        self.assertEqual(result['data']['notes'][0], original)

    def test_note_audit_does_not_invent_authorship_for_legacy_rows(self):
        result = self.save({'notes': [dict(self.doc.notes[0], added_by='fake', added_on='fake'), {'note': 'New'}]})
        self.assertEqual(result['data']['notes'][0], {'name': 'NOTE-1', 'note': 'History'})

    def test_invalid_note_rows_are_rejected(self):
        for notes in ['text', [None], [{'note': 'Valid'}, 'invalid']]:
            with self.subTest(notes=notes), self.assertRaisesRegex(ValueError, 'list of note rows'):
                self.save({'notes': notes})
        self.doc.save.assert_not_called()

    def test_owner_search_uses_erp_user_link_permissions(self):
        self.frappe.call = Mock(return_value=[{'value': 'next@example.test'}])
        result = self.run_api(action='owner_options', name='OPP-1', txt='next')
        self.assertEqual(result['message']['options'], [{'value': 'next@example.test'}])
        self.doc.check_permission.assert_any_call('write')
        self.frappe.call.original.assert_called_once_with('frappe.desk.search.search_link',
            doctype='User', txt='next', page_length=20, reference_doctype='Opportunity',
            ignore_user_permissions=False, filters={'enabled': 1})
        self.doc.save.assert_not_called()

    def test_owner_change_updates_only_owner_and_returns_receipt(self):
        self.frappe.call = Mock(return_value=[{'value': 'next@example.test'}])
        result = self.run_api(action='change_owner', name='OPP-1', modified=self.doc.modified,
            new_owner='next@example.test', changes={'status': 'Demo'})
        self.assertEqual(self.doc.opportunity_owner, 'next@example.test')
        self.assertEqual(self.doc.status, 'Open')
        self.assertEqual(self.doc.sales_stage, 'Original stage')
        self.assertEqual(self.doc.notes, [{'name': 'NOTE-1', 'note': 'History'}])
        self.assertEqual(result['message']['opportunity_owner'], 'next@example.test')
        self.assertNotIn('data', result)
        self.doc.save.assert_called_once_with()

    def test_owner_change_rejects_stale_request_csrf_and_unpermitted_user(self):
        self.frappe.call = Mock(return_value=[])
        for extra, message in [({'csrf_token': 'wrong'}, 'session expired'),
                               ({'modified': 'old'}, 'changed'), ({}, 'permitted ERP user')]:
            params = dict(name='OPP-1', modified=self.doc.modified, new_owner='next@example.test')
            params.update(extra)
            with self.subTest(extra=extra), self.assertRaisesRegex(ValueError, message):
                self.run_api(action='change_owner', **params)
        self.doc.save.assert_not_called()

    def test_owner_change_requires_existing_owner_and_write_permission(self):
        self.doc.opportunity_owner = 'someone-else@example.test'
        with self.assertRaisesRegex(ValueError, 'Opportunity Owner'):
            self.run_api(action='change_owner', name='OPP-1', modified=self.doc.modified, new_owner='next@example.test')
        self.doc.opportunity_owner = 'sales@example.test'
        self.doc.check_permission.side_effect = lambda permission: (_ for _ in ()).throw(PermissionError('Denied')) if permission == 'write' else None
        with self.assertRaises(PermissionError):
            self.run_api(action='owner_options', name='OPP-1')
        self.doc.save.assert_not_called()

    def test_unchanged_status_does_not_change_sales_stage(self):
        self.save({'status': 'Open'})
        self.assertEqual(self.doc.sales_stage, 'Original stage')

    def test_user_specific_policy_and_fieldlevel_read_filter_are_preserved(self):
        script = SCRIPT.replace('opportunity_policy_by_user = {}',
            'opportunity_policy_by_user = {"sales@example.test": {"editable_statuses": ["Demo"], "allow_past_followup": True}}')
        result = self.run_api(script=script, user='spoof@example.test')['message']
        self.assertEqual(result['editable_statuses'], ['Demo'])
        self.assertEqual(result['current_user'], 'sales@example.test')
        self.doc.private_note = 'Hidden'
        self.doc.apply_fieldlevel_read_permissions.side_effect = lambda: self.doc.pop('private_note', None)
        result = self.save({'status': 'Demo'}, script=script)
        self.assertNotIn('private_note', result['data'])

    def test_guest_wrong_owner_and_permission_denial_do_not_write(self):
        self.frappe.session.user = 'Guest'
        with self.assertRaisesRegex(ValueError, 'Sign in'):
            self.run_api()
        self.frappe.session.user = 'other@example.test'
        with self.assertRaisesRegex(ValueError, 'Opportunity Owner'):
            self.save({'status': 'Demo'})
        self.frappe.session.user = 'sales@example.test'
        self.doc.check_permission.side_effect = PermissionError('Denied')
        with self.assertRaises(PermissionError):
            self.save({'status': 'Demo'})
        self.doc.save.assert_not_called()

    def test_transition_and_date_policy_changes_are_enforced_on_save(self):
        script = SCRIPT.replace('status_transitions = {}', 'status_transitions = {"Open": ["Follow-up"]}')
        with self.assertRaisesRegex(ValueError, 'transition'):
            self.save({'status': 'Demo'}, script=script)
        with self.assertRaisesRegex(ValueError, 'on or after'):
            self.save({'custom_next_followup_date': '2026-10-25'})
        script = SCRIPT.replace('allow_past_followup = False', 'allow_past_followup = True').replace(
            'earliest_followup_date = ""', 'earliest_followup_date = "2026-10-20"')
        result = self.save({'custom_next_followup_date': '2026-10-25'}, script=script)
        self.assertEqual(result['data']['custom_next_followup_date'], '2026-10-25')

    def test_unknown_fields_invalid_status_dates_and_stale_writes_are_rejected(self):
        for changes in [{'company': 'Other'}, {'opportunity_owner': 'other'}, {'status': 'Lost'},
                        {'custom_next_followup_date': ''}, {'custom_next_followup_date': '2026-02-30'}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.save(changes)
        with self.assertRaisesRegex(ValueError, 'changed'):
            self.run_api(action='save', name='OPP-1', modified='old', changes={'status': 'Demo'})
        self.frappe.request.method = 'GET'
        with self.assertRaisesRegex(ValueError, 'POST'):
            self.save({'status': 'Demo'})
        self.doc.save.assert_not_called()

if __name__ == '__main__':
    unittest.main()
