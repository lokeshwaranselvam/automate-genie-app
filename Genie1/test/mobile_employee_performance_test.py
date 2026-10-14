"""Verify ownership, date boundaries and real ERP record aggregation."""
from calendar import monthrange
from datetime import date, datetime
from pathlib import Path
from types import SimpleNamespace
import unittest


def getdate(value):
    return date.fromisoformat(str(value)[:10])


def add_months(value, count):
    value = getdate(value)
    total = value.year * 12 + value.month - 1 + count
    year, month = divmod(total, 12)
    return date(year, month + 1, min(value.day, monthrange(year, month + 1)[1]))


class PerformanceTest(unittest.TestCase):
    def setUp(self):
        self.user = 'staff@example.test'
        self.tables = {
            'Lead': [
                dict(lead_owner=self.user, owner='admin', creation='2026-10-01 00:00:00', status='Converted', docstatus=0),
                dict(lead_owner=self.user, creation='2026-10-31 23:59:59', status='Open', docstatus=0),
                dict(lead_owner=self.user, creation='2026-09-30 23:59:59', status='Converted', docstatus=0),
                dict(lead_owner=self.user, creation='2026-11-01 00:00:00', status='Open', docstatus=0),
                dict(lead_owner='other', owner=self.user, creation='2026-10-01', status='Converted', docstatus=0),
            ],
            'Quotation': [dict(owner=self.user, transaction_date='2026-10-01', docstatus=state) for state in [0, 1, 2]],
            'Sales Order': [dict(owner=owner, transaction_date='2026-10-31', docstatus=1) for owner in [self.user, 'other']],
            'Employee': [dict(name='EMP-1', user_id=self.user, status='Active')],
            'Visit': [
                dict(employee='EMP-1', event_id='EVENT-1', custom_check_in_time='2026-10-01 09:00:00', custom_check_out_time='2026-10-01 10:00:00', docstatus=0),
                dict(employee='EMP-1', event_id='EVENT-2', custom_check_in_time='2026-10-01 11:00:00', custom_check_out_time=None, docstatus=0),
                dict(employee='EMP-1', event_id='Employee Checked In', custom_check_in_time='2026-10-01', docstatus=0),
                dict(employee='OTHER', event_id='EVENT-3', custom_check_in_time='2026-10-01', docstatus=0),
            ],
            'Employee Checkin': [dict(employee='EMP-1', time='2026-10-13 10:00:00', log_type=kind) for kind in ['IN', 'IN', 'OUT']],
            'Attendance': [dict(employee='EMP-1', attendance_date='2026-10-13', status=status, docstatus=state) for status, state in [('Present', 1), ('Present', 1), ('Absent', 1), ('Present', 0)]],
        }
        self.missing_fields = set()
        self.queries = []
        self.frappe = SimpleNamespace(
            session=SimpleNamespace(user=self.user), form_dict={'month': '2026-10', 'user': 'other'}, response={},
            utils=SimpleNamespace(getdate=getdate, add_months=add_months, nowdate=lambda: '2026-10-13'),
            get_all=self.get_all,
            get_meta=lambda doctype: SimpleNamespace(get_field=lambda name: name not in self.missing_fields),
            db=SimpleNamespace(exists=lambda doctype, name: name in self.tables),
            throw=lambda message: (_ for _ in ()).throw(ValueError(message)),
        )

    def get_all(self, doctype, filters, fields, limit_page_length):
        self.queries.append((doctype, filters, limit_page_length))
        if isinstance(filters, dict):
            filters = [[key, '=', value] for key, value in filters.items()]
        result = []
        for row in self.tables[doctype]:
            match = True
            for field, operator, expected in filters:
                actual = row.get(field)
                if operator == '=':
                    match = match and actual == expected
                elif operator == '!=':
                    match = match and actual != expected
                elif operator == 'in':
                    match = match and actual in expected
                elif operator == 'not in':
                    match = match and actual is not None and actual not in expected
                elif operator in ['>=', '<']:
                    match = match and actual is not None and (str(actual) >= expected if operator == '>=' else str(actual) < expected)
                else:
                    raise AssertionError(operator)
            if match:
                result.append({field: row.get(field) for field in fields})
        return result[:limit_page_length] if limit_page_length else result

    def run_script(self):
        source = (Path(__file__).resolve().parents[1] / 'frappe_server_scripts/mobile_employee_performance_api.py').read_text(encoding='utf-8-sig')
        exec(compile(source, 'mobile_employee_performance_api.py', 'exec'), {'frappe': self.frappe})
        return self.frappe.response['message']

    def test_sales_excludes_other_users_drafts_cancelled_and_next_month(self):
        result = self.run_script()
        self.assertEqual(result['sales'], dict(leads=2, site_visits=2, quotations=1, orders=1))
        self.assertEqual(result['previous']['leads'], 1)
        self.assertEqual(result['weekly'][0]['conversions'], 1)
        self.assertEqual(result['weekly'][3]['leads'], 1)
        self.assertEqual(sum(row['leads'] for row in result['weekly']), result['sales']['leads'])
        self.assertEqual([row['month'] for row in result['trend']], ['2026-05', '2026-06', '2026-07', '2026-08', '2026-09', '2026-10'])
        self.assertEqual(result['current_user'], self.user)

    def test_actual_visits_and_distinct_days_not_scheduled_events(self):
        result = self.run_script()
        self.assertEqual(result['activity'], dict(site_visits=2, completed_visits=1, ongoing_visits=1, visit_days=1))
        self.assertEqual(result['attendance'], dict(available=True, checkin_days=1, checkins=2, checkouts=1, present_days=1))
        self.assertNotIn('Event', [query[0] for query in self.queries])

    def test_missing_schema_or_ambiguous_employee_returns_unavailable(self):
        self.missing_fields.add('custom_check_in_time')
        self.assertIsNone(self.run_script()['sales']['site_visits'])
        self.tables['Employee'].append(dict(name='EMP-2', user_id=self.user, status='Active'))
        result = self.run_script()
        self.assertIsNone(result['attendance']['checkin_days'])
        self.assertFalse(result['attendance']['available'])
        self.assertEqual(result['sales']['leads'], 2)

    def test_empty_records_are_zero_not_unavailable(self):
        self.tables['Lead'] = []
        self.tables['Visit'] = []
        self.assertEqual(self.run_script()['sales']['leads'], 0)
        self.assertEqual(self.run_script()['sales']['site_visits'], 0)

    def test_year_rollover_and_leap_day_buckets(self):
        self.frappe.form_dict['month'] = '2024-02'
        self.tables['Lead'] = [dict(lead_owner=self.user, creation='2024-02-29 23:59:59', status='Converted', docstatus=0)]
        result = self.run_script()
        self.assertEqual(result['previous_month'], '2024-01')
        self.assertEqual(result['weekly'][3]['leads'], 1)
        self.assertEqual(result['trend'][0]['month'], '2023-09')

    def test_guest_and_invalid_month_fail_before_queries(self):
        for month in ['2026-13', '2026-00', '2026-1', 'garbage']:
            self.frappe.form_dict['month'] = month
            with self.assertRaises(ValueError):
                self.run_script()
        self.frappe.session.user = 'Guest'
        with self.assertRaises(ValueError):
            self.run_script()
        self.assertEqual(self.queries, [])


if __name__ == '__main__':
    unittest.main()
