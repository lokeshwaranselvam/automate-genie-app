"""Behavior tests for the custom-app mobile login guard, without a live ERP."""
import copy
from concurrent.futures import ThreadPoolExecutor
import importlib.util
from pathlib import Path
import sys
import secrets
import threading
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch


class Row(dict):
    __getattr__ = dict.get


class Context:
    def __init__(self):
        self.local = threading.local()

    def __getattr__(self, key):
        return getattr(self.local, key)

    def __setattr__(self, key, value):
        if key == 'local':
            object.__setattr__(self, key, value)
        else:
            setattr(self.local, key, value)


class MobileLoginBackendTest(unittest.TestCase):
    def setUp(self):
        self.user = 'employee@example.test'
        self.bindings = {}
        self.accounts = {self.user: Row(name=self.user, api_key='key',
                                       api_secret='old-secret', full_name='Employee')}
        self.context = Context()
        self.mutex = threading.RLock()
        self.mutexes = {}
        self.created_sessions = []
        self.deleted_sessions = []
        self.events = []
        self.counter = 0
        self.mapping = True
        self.barrier = None
        test = self

        class Manager:
            def authenticate(self, usr, pwd):
                if pwd != 'correct':
                    raise ValueError('Incorrect username or password')
                self.user = usr.lower()
                if test.barrier:
                    test.barrier.wait(timeout=5)

            def login(self):
                test.counter += 1
                sid = f'sid-{test.counter}'
                test.created_sessions.append(sid)
                test.context.user = self.user
                test.context.sid = sid
                # Real Frappe commits during login: the guard must survive.
                test.db.commit()

        def sql(query, params):
            with self.mutex:
                mutex = self.mutexes.setdefault(params[0], threading.RLock())
            if 'GET_LOCK' in query:
                mutex.acquire()
                test.events.append('lock')
                return [(1,)]
            test.events.append('unlock')
            mutex.release()
            return [(1,)]

        def get_value(doctype, filters, fields, **kwargs):
            self.events.append('read')
            if doctype == 'Employee':
                return filters
            self.assertEqual(doctype, 'FCM Device')
            row = next((r for r in self.bindings.values()
                        if r.employee == filters['employee']), None)
            return copy.deepcopy(row)

        def set_value(doctype, name, values):
            self.assertEqual(doctype, 'FCM Device')
            row = next(r for r in self.bindings.values() if r.name == name)
            row.update(values)

        def get_doc(doctype, user=None):
            if doctype == 'Employee':
                self.assertIn(user, ('EMP-1', 'EMP-2'))
                return Row(name=user, custom_office_type_mapping=(
                    [Row(office_type='Head Office')] if self.mapping else []))
            if isinstance(doctype, dict):
                values = Row(doctype)
                def insert(**kwargs):
                    values['name'] = values.employee
                    self.bindings[values.user] = values
                    return values
                return SimpleNamespace(insert=insert)
            values = copy.deepcopy(self.accounts[user])
            document = SimpleNamespace(**values)
            def save(**kwargs):
                self.accounts[user].update(
                    api_key=document.api_key, api_secret=document.api_secret)
                # Frappe _save_passwords masks Password fields on the document
                # after writing the actual secret into encrypted storage.
                document.api_secret = '*' * len(document.api_secret)
            document.save = save
            return document

        def delete_session(sid, **kwargs):
            self.deleted_sessions.append(sid)
            self.db.commit()

        self.db = SimpleNamespace(
            sql=sql, commit=lambda: self.events.append('commit'),
            rollback=lambda: None, exists=lambda *args: True,
            get_value=get_value,
            set_value=set_value,
            delete=lambda dt, filters: self.bindings.pop(filters['name'], None),
        )
        frappe = ModuleType('frappe')
        frappe.local = self.context
        frappe.session = self.context
        frappe.db = self.db
        frappe.ValidationError = ValueError
        frappe.throw = lambda message, exc: (_ for _ in ()).throw(exc(message))
        frappe.get_doc = get_doc
        self.meta = SimpleNamespace(
            has_field=lambda name: True, get_field=lambda name: None, permissions=[],
        )
        frappe.get_meta = lambda dt: self.meta
        def get_all(doctype, **kwargs):
            if doctype == 'FCM Device':
                filters = kwargs['filters']
                expected = filters['user']
                return [copy.deepcopy(r) for r in self.bindings.values()
                        if (r.user != expected[1] if isinstance(expected, list) else r.user == expected)
                        and all(r.get(field) == value for field, value in filters.items() if field != 'user')
                        ][:kwargs.get('limit_page_length', 2)]
            self.assertEqual(doctype, 'Employee')
            # Child Table fields are not scalar columns in tabEmployee.
            if 'custom_office_type_mapping' in kwargs.get('fields', []):
                raise ValueError('Unknown column custom_office_type_mapping')
            self.assertEqual(kwargs['fields'], ['name'])
            return [Row(name='EMP-1' if kwargs['filters']['user_id'] == self.user else 'EMP-2')]
        frappe.get_all = get_all
        frappe.generate_hash = lambda length: secrets.token_hex(length)[:length]
        frappe.only_for = lambda role: None
        auth = ModuleType('frappe.auth')
        auth.LoginManager = Manager
        sessions = ModuleType('frappe.sessions')
        sessions.delete_session = delete_session
        password = ModuleType('frappe.utils.password')
        password.get_decrypted_password = lambda dt, user, field, **kw: self.accounts[user][field]
        spec = importlib.util.spec_from_file_location('mobile_auth_under_test',
            Path(__file__).resolve().parents[1] / 'backend_patches/mobile_auth.py')
        self.module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {'frappe': frappe, 'frappe.auth': auth,
                                     'frappe.sessions': sessions,
                                     'frappe.utils.password': password}):
            spec.loader.exec_module(self.module)

    def login(self, device, password='correct', platform='android', user=None):
        self.context.site = 'erp.example.test'
        self.context.response = {}
        self.context.sid = 'Guest'
        self.context.user = 'Guest'
        self.module.login(user or self.user, password, device, platform=platform)
        return self.context.response.copy()

    def logout(self, device):
        self.context.site = 'erp.example.test'
        self.context.response = {}
        self.module.logout(self.user, device)
        return self.context.response.copy()

    def test_second_phone_cannot_replace_token_or_session(self):
        first = self.login('a' * 43)
        secret = self.accounts[self.user].api_secret
        sid = self.bindings[self.user].custom_mobile_session_id
        second = self.login('b' * 43)
        self.assertTrue(first['single_device_login'])
        self.assertEqual(second['http_status_code'], 409)
        self.assertEqual(second['message']['message'], 'Wrong User')
        self.assertEqual(self.accounts[self.user].api_secret, secret)
        self.assertEqual(self.bindings[self.user].custom_mobile_session_id, sid)
        self.assertEqual(len(self.created_sessions), 1)
        self.assertEqual(self.deleted_sessions, [])

    def test_first_login_returns_real_secret_not_saved_document_password_mask(self):
        response = self.login('a' * 43)
        saved = self.accounts[self.user]
        self.assertEqual(response['token'], 'token ' + saved.api_key + ':' + saved.api_secret)
        self.assertEqual(response['api_secret'], saved.api_secret)
        self.assertNotIn('*', response['api_secret'])

    def test_same_installation_retry_keeps_token_and_replaces_only_its_sid(self):
        first = self.login('a' * 43)
        second = self.login('a' * 43)
        self.assertEqual(first['token'], second['token'])
        self.assertEqual(self.deleted_sessions, ['sid-1'])
        self.assertEqual(self.bindings[self.user].custom_mobile_session_id, 'sid-2')

    def test_logout_retains_binding_revokes_credentials_and_blocks_other_phone(self):
        self.login('a' * 43)
        old_secret = self.accounts[self.user].api_secret
        device_hash = self.bindings[self.user].custom_mobile_device_hash
        # Logout uses the installation capability, including after SID expiry.
        self.context.sid = 'Guest'
        self.assertEqual(self.logout('a' * 43)['message']['status'], 'success')
        self.assertEqual(self.bindings[self.user].custom_mobile_device_hash, device_hash)
        self.assertIsNone(self.bindings[self.user].custom_mobile_session_id)
        self.assertNotEqual(old_secret, self.accounts[self.user].api_secret)
        self.assertEqual(self.deleted_sessions, ['sid-1'])
        result = self.login('b' * 43)
        self.assertEqual(result['http_status_code'], 409)
        self.assertEqual(result['message']['message'], 'Wrong User')
        self.assertEqual(len(self.created_sessions), 1)
        self.assertTrue(self.login('a' * 43)['single_device_login'])

    def test_another_phone_cannot_release_binding(self):
        self.login('a' * 43)
        result = self.logout('b' * 43)
        self.assertEqual(result['http_status_code'], 403)
        self.assertIn(self.user, self.bindings)
        self.assertEqual(self.deleted_sessions, [])

    def test_lost_logout_response_can_be_retried(self):
        self.login('a' * 43)
        self.logout('a' * 43)
        secret = self.accounts[self.user].api_secret
        self.assertEqual(self.logout('a' * 43)['message']['status'], 'success')
        self.assertEqual(len(self.deleted_sessions), 1)
        self.assertEqual(self.accounts[self.user].api_secret, secret)

    def test_bad_password_and_old_build_do_not_change_active_phone(self):
        self.login('a' * 43)
        binding = self.bindings[self.user].copy()
        with self.assertRaises(ValueError):
            self.login('b' * 43, 'wrong')
        with self.assertRaises(ValueError):
            self.login(None)
        self.assertEqual(self.bindings[self.user], binding)
        self.assertEqual(len(self.created_sessions), 1)

    def test_office_mapping_validation_is_preserved(self):
        self.mapping = False
        result = self.login('a' * 43)
        self.assertEqual(result['http_status_code'], 403)
        self.assertEqual(self.bindings, {})
        self.assertEqual(self.created_sessions, [])

    def test_competing_logins_have_one_winner_even_with_internal_commits(self):
        self.barrier = threading.Barrier(2)
        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(self.login, ['a' * 43, 'b' * 43]))
        self.assertEqual(sum(r.get('single_device_login', False) for r in results), 1)
        self.assertEqual(sum(r.get('http_status_code') == 409 for r in results), 1)
        self.assertEqual(len(self.created_sessions), 1)
        self.assertEqual(len(self.bindings), 1)
        self.assertEqual(self.events.count('lock'), self.events.count('unlock'))
        self.assertEqual(self.events.count('lock'), 4)  # device + user per login
        self.assertGreaterEqual(self.events.count('commit'), self.events.count('lock'))

    def test_admin_reset_releases_lost_phone(self):
        self.login('a' * 43)
        self.module.reset_device(self.user)
        self.assertIsNone(self.bindings[self.user].custom_mobile_device_hash)
        self.assertTrue(self.login('b' * 43)['single_device_login'])

    def test_installer_adds_only_protected_optional_custom_fields(self):
        custom_fields = ModuleType('frappe.custom.doctype.custom_field.custom_field')
        calls = []
        custom_fields.create_custom_fields = lambda fields: calls.append(fields)
        with patch.dict(sys.modules, {custom_fields.__name__: custom_fields}), \
                patch.object(self.module.frappe, 'get_doc') as get_doc:
            self.module.install()
            self.module.install()
        get_doc.assert_not_called()  # No new DocType or legacy records.
        self.assertEqual(len(calls), 2)
        self.assertEqual(set(calls[0]), {'FCM Device'})
        for field in calls[0]['FCM Device']:
            self.assertEqual(field['permlevel'], 1)
            self.assertEqual(field['read_only'], 1)
            self.assertEqual(field['hidden'], 1)
            self.assertEqual(field['reqd'], 0)

    def test_ios_login_sets_platform_before_notification_registration(self):
        self.assertTrue(self.login('a' * 43, platform='ios')['single_device_login'])
        self.assertEqual(self.bindings[self.user].platform, 'ios')
        self.bindings[self.user]['platform'] = 'android'
        self.login('a' * 43, platform='ios')
        self.assertEqual(self.bindings[self.user].platform, 'ios')

    def test_platform_validation_happens_before_session_or_binding_changes(self):
        for platform in ('web', '', 123, ['android']):
            with self.subTest(platform=platform), self.assertRaisesRegex(ValueError, '[Pp]latform'):
                self.login('a' * 43, platform=platform)
        self.assertEqual(self.created_sessions, [])
        self.assertEqual(self.bindings, {})

    def test_platform_normalization_and_legacy_android_compatibility(self):
        self.login('a' * 43, platform=' IOS ')
        self.assertEqual(self.bindings[self.user].platform, 'ios')
        self.logout('a' * 43)
        self.bindings[self.user]['platform'] = None
        self.login('a' * 43, platform=None)
        self.assertEqual(self.bindings[self.user].platform, 'android')

    def test_first_login_seeds_android_for_registration_platform_lookup(self):
        self.assertTrue(self.login('a' * 43)['single_device_login'])
        row = self.bindings[self.user]
        self.assertEqual(row.employee, 'EMP-1')
        self.assertEqual(row.platform, 'android')
        self.assertEqual(row.is_active, 0)
        self.assertFalse(row.fcm_token)  # Firebase still supplies the real token.
        matching = [r for r in self.bindings.values()
                    if r.user == self.user and r.platform == 'android']
        self.assertEqual(len(matching), 1)

    def test_first_login_insert_passes_the_restricted_notification_save_guard(self):
        guard_path = Path(__file__).resolve().parents[1] / 'frappe_server_scripts/fcm_device_validation.py'
        guard = compile(guard_path.read_text(), str(guard_path), 'exec')
        get_doc = self.module.frappe.get_doc
        guarded_inserts = []

        def guarded_doc(doctype, user=None):
            document = get_doc(doctype, user)
            if isinstance(doctype, dict) and doctype.get('doctype') == 'FCM Device':
                original_insert = document.insert
                def insert(**kwargs):
                    doc = SimpleNamespace(get=doctype.get, name=doctype['employee'], is_new=lambda: True)
                    exec(guard, {'doc': doc, 'frappe': self.module.frappe})
                    guarded_inserts.append(doctype['employee'])
                    return original_insert(**kwargs)
                document.insert = insert
            return document

        with patch.object(self.module.frappe, 'get_doc', side_effect=guarded_doc):
            self.assertTrue(self.login('a' * 43)['single_device_login'])
        self.assertEqual(guarded_inserts, ['EMP-1'])
        self.assertTrue(self.bindings[self.user].custom_mobile_device_hash)

    def test_same_phone_login_repairs_existing_blank_platform(self):
        self.login('a' * 43)
        row = self.bindings[self.user]
        device_hash = row.custom_mobile_device_hash
        for blank in (None, ''):
            with self.subTest(platform=blank):
                row.update(platform=blank, fcm_token='existing-token', is_active=1)
                self.assertTrue(self.login('a' * 43)['single_device_login'])
                self.assertEqual(row.platform, 'android')
                self.assertEqual(row.fcm_token, 'existing-token')
                self.assertEqual(row.is_active, 1)
                self.assertEqual(row.custom_mobile_device_hash, device_hash)
                self.assertEqual(len(self.bindings), 1)

    def test_existing_ios_platform_is_not_overwritten(self):
        self.login('a' * 43)
        self.bindings[self.user]['platform'] = 'ios'
        self.login('a' * 43, platform=None)
        self.assertEqual(self.bindings[self.user].platform, 'ios')

    def test_existing_fcm_row_is_reused_and_notification_metadata_preserved(self):
        self.bindings[self.user] = Row(
            name='EMP-1', employee='EMP-1', user=self.user, fcm_token='old-token',
            platform='android', is_active=1, app_version='2',
            custom_mobile_device_hash=None, custom_mobile_session_id=None,
        )
        secret = self.accounts[self.user].api_secret
        self.assertTrue(self.login('a' * 43)['single_device_login'])
        row = self.bindings[self.user]
        self.assertEqual(len(self.bindings), 1)
        self.assertEqual(row.fcm_token, 'old-token')
        self.assertEqual(row.platform, 'android')
        self.assertEqual(row.app_version, '2')
        self.assertEqual(row.is_active, 0)
        self.assertNotEqual(self.accounts[self.user].api_secret, secret)
        row['is_active'] = 1  # Successful notification registration.
        self.login('a' * 43)
        self.assertEqual(row.is_active, 1)  # Same-phone retry preserves FCM.
        self.logout('a' * 43)
        self.assertEqual(row.fcm_token, 'old-token')
        self.assertEqual(row.is_active, 0)
        self.assertIsNone(row.custom_mobile_session_id)

    def test_missing_fields_returns_setup_error_before_session_creation(self):
        self.meta.has_field = lambda name: False
        self.assertEqual(self.login('a' * 43)['http_status_code'], 503)
        self.assertEqual(self.created_sessions, [])

    def test_conflicting_employee_owner_is_not_overwritten(self):
        self.bindings['other'] = Row(name='EMP-1', employee='EMP-1', user='other')
        with self.assertRaisesRegex(ValueError, 'another user'):
            self.login('a' * 43)
        self.assertEqual(self.bindings['other'].user, 'other')
        self.assertEqual(self.deleted_sessions, ['sid-1'])

    def test_duplicate_user_rows_fail_closed(self):
        for key in ('one', 'two'):
            self.bindings[key] = Row(name=key, employee=key, user=self.user)
        with self.assertRaisesRegex(ValueError, 'Multiple FCM Device'):
            self.login('a' * 43)
        self.assertEqual(self.created_sessions, [])

    def test_no_legacy_doctype_queries_or_migration(self):
        with patch.object(self.db, 'exists', side_effect=lambda dt, name: name == 'FCM Device'):
            self.assertTrue(self.login('a' * 43)['single_device_login'])

    def test_installer_rejects_existing_level_one_permissions(self):
        custom_fields = ModuleType('frappe.custom.doctype.custom_field.custom_field')
        custom_fields.create_custom_fields = lambda fields: self.fail('Must not change schema')
        self.meta.permissions = [Row(permlevel=1, role='Trainee')]
        with patch.dict(sys.modules, {custom_fields.__name__: custom_fields}):
            with self.assertRaisesRegex(ValueError, 'permission level 1'):
                self.module.install()

    def add_second_user(self):
        other = 'other@example.test'
        self.accounts[other] = Row(name=other, api_key='other-key',
                                   api_secret='other-secret', full_name='Other Employee')
        return other

    def test_same_device_cannot_be_claimed_by_a_second_user_after_logout(self):
        other = self.add_second_user()
        self.login('a' * 43)
        self.logout('a' * 43)
        result = self.login('a' * 43, user=other)
        self.assertEqual(result['http_status_code'], 409)
        self.assertEqual(result['message']['message'], 'Wrong User')
        self.assertEqual(len(self.created_sessions), 1)
        self.assertNotIn(other, self.bindings)
        self.assertEqual(self.accounts[other].api_secret, 'other-secret')

    def test_same_device_cannot_be_claimed_by_a_second_user_while_active(self):
        other = self.add_second_user()
        self.login('a' * 43)
        first = copy.deepcopy(self.bindings[self.user])
        self.assertEqual(self.login('a' * 43, user=other)['http_status_code'], 409)
        self.assertEqual(self.bindings[self.user], first)
        self.assertEqual(self.deleted_sessions, [])

    def test_different_users_can_use_their_own_devices(self):
        other = self.add_second_user()
        self.assertTrue(self.login('a' * 43)['single_device_login'])
        self.assertTrue(self.login('b' * 43, user=other)['single_device_login'])
        self.assertEqual(self.bindings[self.user].employee, 'EMP-1')
        self.assertEqual(self.bindings[other].employee, 'EMP-2')

    def test_two_accounts_racing_for_one_device_have_only_one_winner(self):
        other = self.add_second_user()
        self.barrier = threading.Barrier(2)
        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(lambda user: self.login('a' * 43, user=user), [self.user, other]))
        self.assertEqual(sum(r.get('single_device_login', False) for r in results), 1)
        self.assertEqual(sum(r.get('http_status_code') == 409 for r in results), 1)
        self.assertEqual(len(self.bindings), 1)
        self.assertEqual(len(self.created_sessions), 1)
        self.assertEqual(self.events.count('lock'), self.events.count('unlock'))

    def test_admin_can_reset_a_signed_out_device_before_reassignment(self):
        other = self.add_second_user()
        self.login('a' * 43)
        self.bindings[self.user].update(device_id='old-fcm-id', fcm_token='old-fcm-token', app_version='1')
        self.logout('a' * 43)
        self.assertEqual(self.bindings[self.user].device_id, 'old-fcm-id')
        self.module.reset_device(self.user)
        self.assertIsNone(self.bindings[self.user].custom_mobile_device_hash)
        self.assertIsNone(self.bindings[self.user].device_id)
        self.assertEqual(self.bindings[self.user].fcm_token, 'old-fcm-token')
        self.assertEqual(self.bindings[self.user].app_version, '1')
        self.assertEqual(self.bindings[self.user].is_active, 0)
        self.assertTrue(self.login('a' * 43, user=other)['single_device_login'])

    def test_ordinary_user_cannot_clear_permanent_binding(self):
        self.login('a' * 43)
        original = copy.deepcopy(self.bindings[self.user])
        with patch.object(self.module.frappe, 'only_for', side_effect=PermissionError('System Manager required')):
            with self.assertRaises(PermissionError):
                self.module.reset_device(self.user)
        self.assertEqual(self.bindings[self.user], original)
        self.assertEqual(self.deleted_sessions, [])


if __name__ == '__main__':
    unittest.main()
