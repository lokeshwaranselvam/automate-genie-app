from test.business_policy_stub import install as install_business_policy
"""Run with: python -m unittest discover -s test -p site_visit_api_test.py"""
from datetime import datetime
from itertools import combinations
from pathlib import Path
from types import SimpleNamespace
import unittest
import re
from unittest.mock import Mock


class Row(dict):
    __getattr__ = dict.get
    __setattr__ = dict.__setitem__


class Document(Row):
    def set(self, key, value):
        self[key] = value

    def append(self, key, value):
        self.setdefault(key, []).append(Row(value))

    def insert(self, **kwargs):
        self.name = self.get("name") or "EVENT-TEST"
        return self


def field(name, fieldtype="Data", options=None):
    return Row(fieldname=name, fieldtype=fieldtype, options=options)


def meta(name, fields, title_field=None):
    return SimpleNamespace(
        name=name, fields=fields, title_field=title_field,
        get_field=lambda name: next((f for f in fields if f.fieldname == name), None),
    )


class SiteVisitApiTest(unittest.TestCase):
    def setUp(self):
        self.script = (Path(__file__).resolve().parents[1] /
                       "frappe_server_scripts/mobile_site_visit_api.py").read_text()
        self.user = "sales@example.test"
        self.location = Row(name="LOC-1", location="https://maps.example.test/1",
                            latitude=13, longitude=80, location_type="Site")
        self.opportunity = Document(name="OPP-1", owner=self.user,
                                    title="Lokesh", party_name="LEAD-1",
                                    opportunity_from="Lead", locations=[self.location],
                                    custom_product_enquired="D'sign Doors")
        self.product_field = field("custom_product_enquired", "Select",
                                   "\nD'sign Doors\nWindows\nD'sign Doors\n")
        self.opportunity_rows = [self.opportunity]
        self.lead_rows = [Row(name="LEAD-1", mobile_no="+91 9876543210")]
        self.metas = {
            "Opportunity": meta("Opportunity", [
                field("title"), field("party_name"), field("opportunity_from"),
                self.product_field, field("locations", "Table", "Customer Location"),
            ], "title"),
            "Lead": meta("Lead", [field("mobile_no")]),
            "Customer Location": meta("Customer Location", [
                field("location"), field("latitude"), field("longitude"),
                field("location_type", "Select", "Site\nHome\nOthers"),
            ]),
            "Event": meta("Event", [
                field("starts_on"), field("ends_on"), field("custom_product_enquired"),
                field("event_category", "Select", "Installation\nMeasurement\nSite Visit\nClient Visit\nMeeting\nCall"),
                field("custom_validate"), field("location"), field("assigned_to"),
                field("event_participants", "Table", "Event Participants"),
            ]),
            "Measurement": meta("Measurement", [field("customer_name"), field("contact_number"), field("company")], "customer_name"),
            "Installation Note": meta("Installation Note", [field("customer_name"), field("contact_mobile"), field("company")], "customer_name"),
            "Event Participants": meta("Event Participants", [
                field("reference_doctype"), field("reference_docname"), field("email"),
            ]),
        }
        self.reference_rows = {
            "Measurement": [Document(name="MEAS-1", customer_name="Customer M", contact_number="+91 98765 43210", company="Company M")],
            "Installation Note": [Document(name="INST-1", customer_name="Customer I", contact_mobile="+91 86677-33611", company="Company I")],
        }
        for rows in self.reference_rows.values():
            for row in rows:
                row.check_permission = Mock()
        self.event = Document()
        self.created = []
        self.frappe = SimpleNamespace(
            session=Row(user=self.user, data=Row(csrf_token="test-token")),
            response={}, get_meta=lambda name: self.metas[name],
            enqueue=Mock(), log_error=Mock(), call=Mock(return_value={"status": "sent"}),
            get_all=Mock(side_effect=self.get_all), get_list=Mock(side_effect=self.get_list),
            get_doc=Mock(side_effect=self.get_doc), new_doc=Mock(return_value=self.event),
            db=SimpleNamespace(exists=Mock(side_effect=lambda doctype, filters:
                               not (doctype == "Has Role" and (filters.get("role") == "Accounts User"
                                    or isinstance(filters.get("role"), list)))),
                               get_value=Mock(return_value=Row(name=self.user, full_name="Sales"))),
            utils=SimpleNamespace(get_datetime=datetime.fromisoformat,
                                  now_datetime=lambda: datetime(2026, 10, 12, 11)),
            throw=lambda message: (_ for _ in ()).throw(ValueError(message)),
        )
        self.params = dict(action="create_event", opportunity="OPP-1", location_row="LOC-1",
                           summary="Customer visit", assigned_to=self.user, category="Site Visit",
                           starts_on="2026-10-12 11:15:00", ends_on="2026-10-12 11:45:00",
                           product_enquired="D'sign Doors")

    def get_all(self, doctype, **kwargs):
        if doctype in ["Opportunity", "Lead"]:
            self.assertNotIn("owner", kwargs.get("filters") or {})
            rows = self.opportunity_rows if doctype == "Opportunity" else self.lead_rows
            for key, value in (kwargs.get("filters") or {}).items():
                if isinstance(value, list):
                    self.assertEqual(value[0], "in")
                    rows = [row for row in rows if row.get(key) in value[1]]
                else:
                    rows = [row for row in rows if row.get(key) == value]
            if kwargs.get("or_filters"):
                def matches(row):
                    for key, operator, value in kwargs["or_filters"]:
                        self.assertEqual(operator, "like")
                        pattern = re.escape(value).replace("%", ".*")
                        if re.fullmatch(pattern, str(row.get(key) or "")):
                            return True
                    return False
                rows = [row for row in rows if matches(row)]
            if kwargs.get("limit_page_length"):
                rows = rows[:kwargs["limit_page_length"]]
            return [Row({name: row.get(name) for name in kwargs["fields"]}) for row in rows]
        if doctype == "User":
            return [Row(name=self.user, full_name="Sales")]
        if doctype == "Product":
            self.assertEqual(kwargs["limit_page_length"], 0)
            return [Row(name="Doors"), Row(name="Windows")]
        if doctype == "Event Category":
            return [Row(name=name) for name in [
                "Installation", "Measurement", "SiteVisit", "Client Visit", "Meeting",
            ]]
        self.fail("Unexpected product source: " + doctype)

    def get_list(self, doctype, **kwargs):
        if doctype == "Opportunity":
            self.assertEqual(kwargs["limit_page_length"], 50)
            return self.get_all(doctype, **kwargs)
        self.assertIn(doctype, ["Measurement", "Installation Note"])
        self.assertLessEqual(kwargs["limit_page_length"], 500)
        rows = self.reference_rows[doctype]
        for key, value in kwargs.get("filters", {}).items():
            if key == "docstatus":
                self.assertEqual(value, ["<", 2])
                rows = [row for row in rows if row.get("docstatus", 0) < 2]
                continue
            self.assertEqual(value[0], "like")
            pattern = re.escape(value[1]).replace("%", ".*")
            rows = [row for row in rows if re.fullmatch(pattern, str(row.get(key) or ""))]
        return rows

    def get_doc(self, value, *args):
        if isinstance(value, str) and value in self.reference_rows:
            return next(row for row in self.reference_rows[value] if row.name == args[0])
        if value == "Opportunity":
            return self.opportunity
        doc = Document(value)
        self.created.append(doc)
        return doc

    def run_api(self, **overrides):
        self.frappe.form_dict = dict(self.params, **overrides)
        install_business_policy(self.frappe)
        exec(compile(self.script, "mobile_site_visit_api.py", "exec"), {"frappe": self.frappe})
        return self.frappe.response["message"]

    def test_schedule_settings_apply_to_options_and_server_validation(self):
        self.assertEqual(self.run_api(action="get")["schedule_policy"], {
            "interval_minutes": 15, "allow_past": False, "earliest_booking_date": "2026-10-12",
        })
        self.script = self.script.replace('schedule_interval_minutes = 15', 'schedule_interval_minutes = 30').replace(
            'schedule_allow_past = False', 'schedule_allow_past = True').replace(
            'schedule_earliest_booking_date = ""', 'schedule_earliest_booking_date = "2026-10-10"')
        result = self.run_api(starts_on="2026-10-11 11:30:00", ends_on="2026-10-11 12:00:00")
        self.assertEqual(result['event'], 'EVENT-TEST')
        for start, end in [('2026-10-11 11:15:00', '2026-10-11 12:00:00'),
                           ('2026-10-09 11:30:00', '2026-10-09 12:00:00')]:
            with self.subTest(start=start), self.assertRaises(ValueError):
                self.run_api(starts_on=start, ends_on=end)

    def test_sales_manager_menu_permissions_do_not_require_an_event_id(self):
        self.configure_category_policy(['Sales Manager'], 'Other Company')
        result = self.run_api(action='can_create', event_id='')
        self.assertEqual(result['current_user'], self.user)
        self.assertTrue(result['can_create'])
        self.assertTrue(result['can_create_lead'])
        self.assertTrue(result['can_view_opportunities'])
        self.assertTrue(result['feature_visibility']['new_visit'])
        self.frappe.get_doc.assert_not_called()

    def test_tracking_eligibility_comes_from_session_roles_and_not_request_user(self):
        for roles, expected in [(['Sales User'], True), (['Designer'], True), (['Sales Manager'], False),
                                (['Employee'], False), ([], False)]:
            self.configure_category_policy(roles, 'Other Company')
            self.assertIs(self.run_api(action='can_create', user='spoof@example.test')['can_track'], expected)

    def test_visibility_and_user_overrides_do_not_grant_creation_permissions(self):
        self.configure_category_policy(['Employee'], 'Other Company')
        self.script = self.script.replace('feature_visibility_overrides = {}',
            'feature_visibility_overrides = {"visits": False, "new_visit": True, "leads": True}')
        self.script = self.script.replace('tracking_user_overrides = {}',
            'tracking_user_overrides = {"sales@example.test": True}')
        result = self.run_api(action='can_create')
        self.assertFalse(result['can_create'])
        self.assertFalse(result['can_create_lead'])
        self.assertTrue(result['can_track'])
        self.assertFalse(result['feature_visibility']['visits'])
        self.assertTrue(result['feature_visibility']['new_visit'])
        self.assertTrue(result['feature_visibility']['leads'])
        with self.assertRaisesRegex(ValueError, 'Sales Manager'):
            self.run_api()
        self.frappe.new_doc.assert_not_called()

    def test_location_type_is_optional_in_category_rules_for_all_creators(self):
        result = self.run_api(action="get")
        self.assertFalse(result["business_policy"]["fields"]["location_type"]["required"])
        for rule in result["event_category_rules"].values():
            self.assertNotIn("location_type", rule["required_fields"])

    def test_opportunity_location_accepts_blank_type_without_skipping_permissions(self):
        self.opportunity.save = Mock()
        self.frappe.utils.flt = float
        self.run_api(action="save_location", map_link=self.location.location,
                     location_type="", latitude="13", longitude="80")
        self.assertEqual(self.opportunity.locations[-1].location_type, "")
        self.opportunity.save.assert_called_once_with()
        for invalid in ["Unknown", "site"]:
            with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, "valid location type"):
                self.run_api(action="save_location", map_link=self.location.location,
                             location_type=invalid, latitude="13", longitude="80")

    def test_reference_events_allow_blank_type_but_reject_invalid_supplied_type(self):
        for category, doctype in [("Measurement", "Measurement"), ("Installation", "Installation Note")]:
            params = dict(category=category, opportunity="", location_row="", product_enquired="",
                          reference_doctype=doctype, reference_name=self.reference_rows[doctype][0].name,
                          map_link=self.location.location, latitude="13", longitude="80", location_type="")
            with self.subTest(category=category):
                result = self.run_api(**params)
                self.assertEqual(result["location_type"], "")
                self.assertEqual(self.event.location, "")
                self.assertIn("13.0,80.0", self.event.custom_validate)
                self.reference_rows[doctype][0].check_permission.assert_called_with("read")
                with self.assertRaisesRegex(ValueError, "valid location type"):
                    self.run_api(**dict(params, location_type="Unknown"))

    def test_opportunity_event_preserves_an_existing_blank_location_type(self):
        self.location.location_type = ""
        result = self.run_api()
        self.assertEqual(result["location_type"], "")
        self.assertEqual(self.event.custom_validate, self.location.location)

    def test_selected_home_type_is_saved_without_optional_custom_type_field(self):
        self.location.location_type = "Home"
        result = self.run_api()
        self.assertEqual(self.event.location, "Home")
        self.assertEqual(self.event.custom_validate, self.location.location)
        self.assertEqual(result["location_type"], "Home")
        self.assertEqual(result["location_row"], "LOC-1")

    def test_category_rules_report_the_same_existing_creation_routes_and_fields(self):
        self.configure_category_policy(["Sales Manager"], "Other Company")
        result = self.run_api(action="get")
        rules = result["event_category_rules"]
        self.assertEqual(set(rules), set(result["event_categories"]))
        for category, doctype in [("Measurement", "Measurement"), ("Installation", "Installation Note")]:
            self.assertEqual(rules[category]["reference_mode"], "document")
            self.assertEqual(rules[category]["reference_doctype"], doctype)
            self.assertIn("reference_name", rules[category]["required_fields"])
            self.assertIn("map_link", rules[category]["required_fields"])
            self.assertNotIn("opportunity", rules[category]["required_fields"])
        for category in ["Other", "Bank", "Collection", "Head Office CH", "Timbe / Bioman Office CH", "Maintenance"]:
            self.assertEqual(rules[category]["reference_mode"], "none")
            self.assertEqual(rules[category]["reference_doctype"], "")
            self.assertEqual(rules[category]["required_fields"], ["category", "summary", "starts_on", "ends_on", "assigned_to"])
        self.assertEqual(rules["Site Visit"]["reference_doctype"], "Opportunity")
        self.assertIn("location_row", rules["Site Visit"]["required_fields"])

    def test_api_category_mapping_controls_listing_reference_search_and_creation(self):
        self.script = self.script.replace(
            '"measurement": "Measurement",',
            '"site visit": "Measurement", "measurement": "Measurement",',
            1,
        )
        self.configure_category_policy(["Sales Manager"], "Other Company")
        rule = self.run_api(action="get")["event_category_rules"]["Site Visit"]
        self.assertEqual(rule["reference_doctype"], "Measurement")
        self.assertEqual(len(self.run_api(action="get_references", category="Site Visit")["references"]), 1)
        with self.assertRaisesRegex(ValueError, "must reference Measurement"):
            self.run_api(category="Site Visit")
        result = self.run_api(category="Site Visit", opportunity="", location_row="", product_enquired="",
                              reference_doctype="Measurement", reference_name="MEAS-1",
                              map_link="https://maps.google.com/?q=11,77", latitude="11", longitude="77", location_type="Site")
        self.assertEqual(result["event"], "EVENT-TEST")
        self.assertEqual(self.event.event_participants[-1].reference_doctype, "Measurement")

    def test_map_url_and_type_are_saved_in_separate_fields(self):
        self.metas["Event"].fields.extend([field("custom_location"), field("custom_location_type")])
        self.run_api()
        self.assertEqual(self.event.location, "Site")
        self.assertEqual(self.event.custom_location_type, "Site")
        self.assertEqual(self.event.custom_location, self.location.location)
        self.assertEqual(self.event.custom_validate, self.location.location)

    def test_missing_type_storage_is_rejected_instead_of_silently_losing_selection(self):
        self.metas["Event"].fields[:] = [f for f in self.metas["Event"].fields if f.fieldname != "location"]
        with self.assertRaisesRegex(ValueError, "selected Home/Site/Others"):
            self.run_api()
        self.frappe.new_doc.assert_not_called()

    def test_options_and_mobile_search_return_title_party_and_custom_product(self):
        result = self.run_api(action="get")
        self.assertEqual(result["product_enquired_options"], ["D'sign Doors", "Windows"])
        self.assertEqual(result["event_categories"], ["Installation", "Measurement", "Site Visit", "Client Visit", "Meeting", "Call"])
        opportunity_query = self.frappe.get_all.call_args_list[0]
        self.assertEqual(set(opportunity_query.kwargs["fields"]),
                         {"name", "owner", "title", "party_name", "custom_product_enquired"})
        self.assertFalse(any(call.args[0] == "Lead"
                             for call in self.frappe.get_all.call_args_list))
        for row in (result["opportunities"][0],
                    self.run_api(action="search_by_mobile", mobile="98765")["opportunities"][0]):
            self.assertEqual((row["title"], row["party_name"], row["name"]),
                             ("Lokesh", "LEAD-1", "OPP-1"))
            self.assertEqual(row["product_enquired"], "D'sign Doors")
            self.assertEqual(row["assigned_to"], self.user)
            self.assertEqual(set(row), {"name", "title", "party_name", "contact_mobile", "phone", "product_enquired", "assigned_to"})

    def test_opportunity_owner_and_product_are_returned_together_for_selection(self):
        self.metas["Opportunity"].fields.append(field("opportunity_owner", "Link", "User"))
        self.opportunity.opportunity_owner = "installer@example.test"
        for action in ["get", "search_by_mobile"]:
            result = self.run_api(action=action, mobile="98765")
            row = result["opportunities"][0]
            self.assertEqual(row["assigned_to"], "installer@example.test")
            self.assertEqual(row["product_enquired"], "D'sign Doors")
        self.opportunity.opportunity_owner = ""
        self.assertEqual(self.run_api(action="get")["opportunities"][0]["assigned_to"], self.user)

    def test_link_product_field_returns_all_options(self):
        self.product_field.fieldtype = "Link"
        self.product_field.options = "Product"
        self.assertEqual(self.run_api(action="get")["product_enquired_options"], ["Doors", "Windows"])

    def test_event_saves_selected_times_product_and_opportunity_link(self):
        result = self.run_api()
        self.assertEqual(self.event.starts_on, datetime.fromisoformat(self.params["starts_on"]))
        self.assertEqual(self.event.ends_on, datetime.fromisoformat(self.params["ends_on"]))
        self.assertEqual(self.event.custom_product_enquired, "D'sign Doors")
        self.assertEqual(self.event.event_participants[0].reference_docname, "OPP-1")
        self.assertEqual(self.event.custom_validate, self.location.location)
        self.assertEqual([doc.doctype for doc in self.created], ["Comment", "ToDo"])

    def test_changed_product_and_non_installation_category_are_saved(self):
        self.run_api(product_enquired="Windows", category="Client Visit")
        self.assertEqual(self.event.custom_product_enquired, "Windows")
        self.assertEqual(self.opportunity.custom_product_enquired, "D'sign Doors")
        self.assertEqual(self.event.event_category, "Client Visit")

    def test_opportunity_without_product_returns_empty_selection(self):
        self.opportunity.custom_product_enquired = ""
        result = self.run_api(action="get")
        self.assertEqual(result["opportunities"][0]["product_enquired"], "")
        self.assertEqual(result["product_enquired_options"], ["D'sign Doors", "Windows"])

    def test_category_options_and_validation_use_the_same_event_field(self):
        for category in ["", "Unknown"]:
            with self.subTest(category=category), self.assertRaises(ValueError):
                self.run_api(category=category)
        self.frappe.new_doc.assert_not_called()
        category_field = self.metas["Event"].get_field("event_category")
        category_field.fieldtype = "Link"
        category_field.options = "Event Category"
        result = self.run_api(action="get")
        self.assertEqual(result["event_categories"], ["Installation", "Measurement", "SiteVisit", "Client Visit", "Meeting"])
        self.run_api(category="Client Visit")
        self.assertEqual(self.event.event_category, "Client Visit")

    def test_reference_lists_and_phone_search_use_correct_fields_and_permissions(self):
        for category, doctype, phone, digits, detail in [
            ("Measurement", "Measurement", "contact_number", "98765", "company"),
            ("Installation", "Installation Note", "contact_mobile", "86677", "company"),
        ]:
            with self.subTest(category=category):
                result = self.run_api(action="get_references", category=category, mobile=digits)
                self.assertEqual(result["reference_doctype"], doctype)
                self.assertEqual(len(result["references"]), 1)
                self.assertTrue(result["references"][0][detail])
                self.assertIn(phone, self.frappe.get_list.call_args.kwargs["filters"])
                self.assertEqual(result["references"][0]["name"], self.reference_rows[doctype][0].name)
                self.assertEqual(self.run_api(action="get_references", category=category, mobile="00000")["references"], [])
                with self.assertRaises(ValueError):
                    self.run_api(action="get_references", category=category, mobile="1234")
        self.frappe.get_all.assert_not_called()
        with self.assertRaises(ValueError):
            self.run_api(action="get_references", category="Site Visit")

    def test_source_references_create_events_without_opportunity_or_product(self):
        for category, doctype in [("Measurement", "Measurement"), ("Installation", "Installation Note")]:
            with self.subTest(category=category):
                row = self.reference_rows[doctype][0]
                result = self.run_api(category=category, opportunity="", location_row="",
                    reference_doctype=doctype, reference_name=row.name, product_enquired="",
                    map_link="https://maps.app.goo.gl/resolved", latitude="13", longitude="80", location_type="Site")
                row.check_permission.assert_called_with("read")
                participant = self.event.event_participants[-1]
                self.assertEqual(participant.reference_doctype, doctype)
                self.assertEqual(participant.reference_docname, row.name)
                self.assertEqual(result["reference_name"], row.name)
                self.assertEqual(result["opportunity"], "")
                self.assertEqual(self.event.custom_validate, "https://www.google.com/maps/search/?api=1&query=13.0,80.0")
                self.assertNotIn("custom_product_enquired", self.event)
                self.assertNotIn("company", self.event)
                self.assertNotIn("custom_brand", self.event)
        self.frappe.get_all.assert_not_called()
        self.assertFalse(any(call.args[0] == "Opportunity" for call in self.frappe.get_doc.call_args_list))

    def test_reference_creation_rejects_wrong_missing_cancelled_or_unreadable_documents(self):
        params = dict(category="Measurement", opportunity="", location_row="", product_enquired="",
            reference_doctype="Measurement", reference_name="MEAS-1", map_link="https://maps.example.test",
            latitude="13", longitude="80", location_type="Site")
        for changes in [{"reference_name": ""}, {"reference_doctype": "Installation Note"},
                        {"opportunity": "OPP-1"}, {"product_enquired": "Windows"},
                        {"category": "Site Visit"}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.run_api(**dict(params, **changes))
        row = self.reference_rows["Measurement"][0]
        row.docstatus = 2
        with self.assertRaisesRegex(ValueError, "cancelled"):
            self.run_api(**params)
        row.docstatus = 0
        row.check_permission.side_effect = PermissionError("No read access")
        with self.assertRaises(PermissionError):
            self.run_api(**params)
        self.frappe.new_doc.assert_not_called()

    def test_reference_search_permission_denial_is_not_bypassed(self):
        self.frappe.get_list.side_effect = PermissionError("No read access")
        with self.assertRaises(PermissionError):
            self.run_api(action="get_references", category="Measurement")
        self.frappe.get_all.assert_not_called()

    def test_missing_source_fields_or_event_reference_schema_fail_clearly(self):
        self.metas["Measurement"].fields[:] = [field("company")]
        with self.assertRaisesRegex(ValueError, "contact_number"):
            self.run_api(action="get_references", category="Measurement")
        self.metas["Event Participants"].fields[:] = [field("email")]
        with self.assertRaisesRegex(ValueError, "document reference fields"):
            self.run_api(category="Installation", opportunity="", location_row="", product_enquired="",
                reference_doctype="Installation Note", reference_name="INST-1",
                map_link="https://maps.example.test", latitude="13", longitude="80", location_type="Site")
        self.assertEqual(self.event.get("name"), None)

    def test_reference_list_excludes_cancelled_documents(self):
        self.reference_rows["Measurement"][0].docstatus = 2
        self.assertEqual(self.run_api(action="get_references", category="Measurement")["references"], [])

    def test_direct_categories_create_without_location_or_coordinate_comment(self):
        self.metas["Event"].fields[:] = [f for f in self.metas["Event"].fields
            if f.fieldname not in ["location", "custom_location_type", "custom_validate", "custom_location"]]
        for category in ["Other", "Others", "Bank", "Head Office CH", "Timbe / Bioman Office CH", "Collection", "Maintenance"]:
            with self.subTest(category=category):
                self.metas["Event"].get_field("event_category").options += "\n" + category
                self.frappe.get_doc.reset_mock()
                result = self.run_api(category=category, opportunity="", location_row="", product_enquired="")
                self.assertNotIn("custom_validate", self.event)
                self.assertNotIn("location", self.event)
                self.assertEqual(result["opportunity"], "")
                self.assertEqual(result["location_row"], "")
                self.assertEqual(result["location_type"], "")
                self.assertEqual(self.event.event_participants[-1].reference_doctype, "User")
                self.assertEqual(self.created[-1].allocated_to, self.user)
                self.assertTrue(all(doc.doctype == "ToDo" for doc in self.created))
                self.assertFalse(any(call.args[0] == "Opportunity" for call in self.frappe.get_doc.call_args_list))

    def test_location_exemption_cannot_bypass_opportunity_or_reference_routes(self):
        self.metas["Event"].get_field("event_category").options += "\nBank"
        with self.assertRaises(ValueError):
            self.run_api(category="Bank")
        with self.assertRaises(ValueError):
            self.run_api(opportunity="", location_row="")
        for category, doctype, name in [("Measurement", "Measurement", "MEAS-1"),
                                       ("Installation", "Installation Note", "INST-1")]:
            with self.subTest(category=category), self.assertRaisesRegex(ValueError, "map location"):
                self.run_api(category=category, opportunity="", location_row="", product_enquired="",
                             reference_doctype=doctype, reference_name=name)
        self.frappe.new_doc.assert_not_called()

    def test_maintenance_does_not_accept_an_opportunity_link(self):
        self.configure_category_policy(["SCM Manager"], "Other Company")
        with self.assertRaisesRegex(ValueError, "does not use an Opportunity"):
            self.run_api(category="Maintenance")
        self.frappe.new_doc.assert_not_called()

    def test_invalid_times_and_product_are_rejected_before_inserting(self):
        for overrides in [
            {"ends_on": ""}, {"starts_on": "2026-10-12 10:45:00"},
            {"starts_on": "2026-10-12 11:16:00"}, {"ends_on": "2026-10-12 11:45:01"},
            {"ends_on": "2026-10-12 11:15:00"}, {"ends_on": "2026-10-12 11:00:00"},
            {"product_enquired": "Unknown"},
        ]:
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                self.run_api(**overrides)
        self.frappe.new_doc.assert_not_called()

    def test_product_is_optional_and_midnight_end_is_saved(self):
        self.run_api(product_enquired="", starts_on="2026-10-12 23:45:00",
                     ends_on="2026-10-13 00:00:00")
        self.assertNotIn("custom_product_enquired", self.event)
        self.assertEqual(self.event.ends_on, datetime(2026, 10, 13))

    def test_product_cannot_silently_fall_back_to_description(self):
        self.metas["Event"].fields = [
            f for f in self.metas["Event"].fields if f.fieldname != "custom_product_enquired"
        ]
        with self.assertRaisesRegex(ValueError, "custom_product_enquired"):
            self.run_api()
        self.frappe.new_doc.assert_not_called()

    def test_existing_opportunity_location_and_guest_checks_are_preserved(self):
        self.frappe.db.exists.side_effect = lambda doctype, filters: (
            doctype == "Has Role" and filters.get("role") != "Accounts User"
            and not isinstance(filters.get("role"), list)
        )
        with self.assertRaisesRegex(ValueError, "existing opportunity"):
            self.run_api()
        self.frappe.db.exists.side_effect = lambda doctype, filters: not (
            doctype == "Has Role" and (filters.get("role") == "Accounts User"
                                      or isinstance(filters.get("role"), list))
        )
        with self.assertRaisesRegex(ValueError, "does not belong"):
            self.run_api(location_row="OTHER-LOCATION")
        self.frappe.session.user = "Guest"
        with self.assertRaisesRegex(ValueError, "Sign in"):
            self.run_api()
        self.frappe.new_doc.assert_not_called()

    def test_event_creation_keeps_assignment_without_legacy_inline_fcm_send(self):
        result = self.run_api(assigned_to="designer@example.test")
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["event"], self.event.name)
        self.assertFalse(result["alarm_sent"])
        self.assertFalse(result["alarm_queued"])
        self.frappe.enqueue.assert_not_called()
        self.frappe.call.assert_not_called()
        self.assertEqual(self.created[-1].doctype, "ToDo")
        self.assertEqual(self.created[-1].allocated_to, "designer@example.test")
        self.assertEqual(self.created[-1].reference_type, "Event")
        self.assertEqual(self.created[-1].reference_name, self.event.name)

    def test_removed_inline_sender_cannot_block_event_or_assignment_creation(self):
        self.frappe.call.side_effect = AttributeError("Old sender is unavailable")
        result = self.run_api()
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["event"], self.event.name)
        self.assertEqual(self.created[-1].doctype, "ToDo")
        self.frappe.call.assert_not_called()
        self.frappe.log_error.assert_not_called()

    def test_capability_uses_session_role_and_does_not_load_form_data(self):
        for roles, allowed in [([], False), (["Employee"], False),
                               (["Sales User"], False), (["Designer"], False),
                               (["Sales Manager", "Sales User"], True),
                               (["Sales Manager", "Designer"], True)]:
            self.configure_category_policy(roles, "Other Company")
            result = self.run_api(action="can_create", user="other@example.test")
            self.assertEqual(result["can_create"], allowed)
            self.assertEqual(result["current_user"], self.user)
            self.frappe.db.exists.assert_any_call("Has Role", {
                "parent": self.user, "parenttype": "User", "parentfield": "roles",
                "role": "Sales Manager",
            })
        self.frappe.get_all.assert_not_called()

    def test_home_actions_follow_exact_session_sales_roles(self):
        for roles, lead, visit, pending in [([], False, False, False),
                                   (["Employee"], False, False, False),
                                   (["Sales User"], True, False, True),
                                   (["Sales Manager"], True, True, True),
                                   (["Accounts User"], False, True, False),
                                   (["SCM Manager"], False, True, False),
                                   (["Delivery Manager"], False, True, False),
                                   (["Production User"], False, False, True),
                                   (["Production Manager"], False, False, True)]:
            self.frappe.db.exists.side_effect = lambda doctype, filters: (
                doctype == "Has Role" and filters["parent"] == self.user
                and (any(role in roles for role in filters["role"][1])
                     if isinstance(filters["role"], list) else filters["role"] in roles)
            )
            result = self.run_api(action="can_create", user="other@example.test")
            self.assertEqual(result["can_create_lead"], lead)
            self.assertEqual(result["can_create"], visit)
            self.assertEqual(result["can_view_opportunities"], "Sales Manager" in roles)
            self.assertTrue(result["can_view_visits"])
            self.assertEqual(result["can_view_pending"], pending)
        self.frappe.get_all.assert_not_called()
        self.frappe.get_doc.assert_not_called()

    def test_designer_can_view_assigned_visits_without_creation_or_other_sales_access(self):
        roles = ["Designer"]
        self.frappe.db.exists.side_effect = lambda doctype, filters: (
            doctype == "Has Role" and filters["parent"] == self.user
            and (any(role in roles for role in filters["role"][1])
                 if isinstance(filters["role"], list) else filters["role"] in roles)
        )
        result = self.run_api(action="can_create")
        self.assertTrue(result["can_view_visits"])
        self.assertFalse(result["can_create"])
        self.assertFalse(result["can_create_lead"])
        self.assertFalse(result["can_view_pending"])
        for action in ["get", "get_references", "create_event"]:
            with self.subTest(action=action), self.assertRaisesRegex(ValueError, "Sales Manager"):
                self.run_api(action=action)
        self.frappe.get_all.assert_not_called()
        self.frappe.new_doc.assert_not_called()

    def configure_category_policy(self, roles, company):
        self.frappe.db.exists.side_effect = lambda doctype, filters: (
            (any(role in roles for role in filters["role"][1]) if isinstance(filters["role"], list) else filters["role"] in roles) if doctype == "Has Role" else True
        )
        self.frappe.db.get_value.side_effect = lambda doctype, *args, **kwargs: (
            company if doctype == "Employee" else Row(name=self.user, full_name="Sales")
        )
        self.metas["Event"].get_field("event_category").options = (
            "Showroom Visit\nMeasurement\nHead Office CH\nTimbe / Bioman Office CH\n"
            "Depot Visit (Out Station)\nMaintenance\nSite Visit\nComplaint Visit\n"
            "Collection\nBank\nTraining\nInstallation\nOther\nClient Visit\nVideo Call\n"
            "Model Demo(Vellore)\nModel Demo(Sriperumbudur)\nConference Call"
        )

    def test_company_categories_apply_to_all_sales_managers_including_sales_user(self):
        for roles in [["Sales Manager"], ["Sales Manager", "Employee"], ["Sales Manager", "Production User"],
                      ["Sales Manager", "Sales User"], ["Sales Manager", "Designer"]]:
            for company in ["Bioman Sewage Solutions Private Limited",
                            "Homegenie Building Products Private Limited",
                            "Doortisan Creations Private Limited", "Timbe Windows Private Limited"]:
                with self.subTest(roles=roles, company=company):
                    self.configure_category_policy(roles, company)
                    self.frappe.db.get_value.reset_mock()
                    result = self.run_api(action="get")
                    expected = {"Measurement", "Collection", "Site Visit"}
                    if company in ["Bioman Sewage Solutions Private Limited",
                                   "Homegenie Building Products Private Limited"]:
                        expected.update(["Installation", "Complaint Visit"])
                    self.assertEqual(set(result["event_categories"]), expected)
                    employee_queries = [call for call in self.frappe.db.get_value.call_args_list
                                        if call.args[0] == "Employee"]
                    self.assertEqual(len(employee_queries), 1)
                    self.assertEqual(employee_queries[0].args,
                                     ("Employee", {"user_id": self.user, "status": "Active"}, "company"))

    def test_active_homegenie_employee_takes_priority_over_old_timbe_company(self):
        for roles in [["Sales Manager"], ["Sales Manager", "Accounts User"],
                      ["Sales Manager", "Accounts User", "Delivery Manager"]]:
            with self.subTest(roles=roles):
                self.configure_category_policy(roles, "Homegenie Building Products Private Limited")
                self.frappe.db.get_value.side_effect = lambda doctype, filters, *args, **kwargs: (
                    ("Homegenie Building Products Private Limited" if filters.get("status") == "Active"
                     else "Timbe Windows Private Limited") if doctype == "Employee"
                    else Row(name=self.user, full_name="Sales")
                )
                result = self.run_api(action="get")
                expected = {"Measurement", "Site Visit", "Collection", "Installation", "Complaint Visit"}
                if "Accounts User" in roles:
                    expected.update(["Bank", "Other"])
                if "Delivery Manager" in roles:
                    expected.add("Maintenance")
                self.assertEqual(set(result["event_categories"]), expected)

    def test_active_timbe_employee_does_not_inherit_old_homegenie_categories(self):
        self.configure_category_policy(["Sales Manager"], "Timbe Windows Private Limited")
        self.frappe.db.get_value.side_effect = lambda doctype, filters, *args, **kwargs: (
            ("Timbe Windows Private Limited" if filters.get("status") == "Active"
             else "Homegenie Building Products Private Limited") if doctype == "Employee"
            else Row(name=self.user, full_name="Sales")
        )
        self.assertEqual(set(self.run_api(action="get")["event_categories"]),
                         {"Measurement", "Site Visit", "Collection"})

    def test_missing_active_company_keeps_the_previous_company_fallback(self):
        self.configure_category_policy(["Sales Manager"], "Homegenie Building Products Private Limited")
        self.frappe.db.get_value.side_effect = lambda doctype, filters, *args, **kwargs: (
            (None if filters.get("status") == "Active" else "Homegenie Building Products Private Limited")
            if doctype == "Employee" else Row(name=self.user, full_name="Sales")
        )
        self.assertEqual(set(self.run_api(action="get")["event_categories"]),
                         {"Measurement", "Site Visit", "Collection", "Installation", "Complaint Visit"})

    def test_accounts_categories_without_other_creation_roles_keep_existing_policy(self):
        for roles in [["Accounts User"],
                      ["Accounts User", "Sales User"], ["Accounts User", "Designer"]]:
            for company in ["Bioman Sewage Solutions Private Limited",
                            "Homegenie Building Products Private Limited",
                            "Doortisan Creations Private Limited", "Timbe Windows Private Limited",
                            "Other Company", None]:
                with self.subTest(roles=roles, company=company):
                    self.configure_category_policy(roles, company)
                    self.metas["Event"].get_field("event_category").options += "\nOthers"
                    result = self.run_api(action="get", user="other@example.test")
                    self.assertEqual(set(result["event_categories"]),
                                     {"Bank", "Collection", "Other", "Others"})

    def test_accounts_can_create_allowed_categories_and_cannot_submit_other_categories(self):
        self.configure_category_policy(["Accounts User"], "Timbe Windows Private Limited")
        self.metas["Event"].get_field("event_category").options += "\nOthers"
        for category in ["Bank", "Collection", "Other", "Others"]:
            with self.subTest(category=category):
                result = self.run_api(category=category, opportunity="", location_row="",
                                      product_enquired="")
                self.assertEqual(result["event"], "EVENT-TEST")
                self.assertEqual(self.event.event_category, category)
        self.frappe.new_doc.reset_mock()
        for category in ["Site Visit", "Measurement", "Installation", "Training"]:
            with self.subTest(category=category), self.assertRaisesRegex(ValueError, "valid event category"):
                self.run_api(category=category, company="Other Company", user="other@example.test")
        with self.assertRaisesRegex(ValueError, "valid event category"):
            self.run_api(action="get_references", category="Measurement")
        self.frappe.new_doc.assert_not_called()

    def test_scm_and_delivery_categories_use_session_roles_across_companies(self):
        for roles in [["SCM Manager"], ["Delivery Manager"],
                      ["SCM Manager", "Delivery Manager"],
                      ["Delivery Manager", "Sales User"]]:
            for company in ["Bioman Sewage Solutions Private Limited",
                            "Homegenie Building Products Private Limited",
                            "Doortisan Creations Private Limited", "Timbe Windows Private Limited",
                            "Other Company", None]:
                with self.subTest(roles=roles, company=company):
                    self.configure_category_policy(roles, company)
                    self.assertEqual(set(self.run_api(action="get")["event_categories"]),
                                     {"Installation", "Complaint Visit", "Site Visit", "Maintenance", "Other"})
        for role in ["SCM Manager", "Delivery Manager"]:
            self.configure_category_policy([role], "Timbe Windows Private Limited")
            for category in ["Bank", "Collection", "Measurement", "Training"]:
                with self.subTest(role=role, category=category), self.assertRaisesRegex(ValueError, "valid event category"):
                    self.run_api(category=category, user="other@example.test", company="Other Company")
            self.frappe.new_doc.assert_not_called()

    def test_scm_and_delivery_can_create_their_categories_using_existing_workflows(self):
        for role in ["SCM Manager", "Delivery Manager"]:
            self.configure_category_policy([role], "Doortisan Creations Private Limited")
            for category in ["Complaint Visit", "Site Visit"]:
                with self.subTest(role=role, category=category):
                    self.assertEqual(self.run_api(category=category)["event"], "EVENT-TEST")
                    self.assertEqual(self.event.event_category, category)
            result = self.run_api(category="Maintenance", opportunity="", location_row="", product_enquired="")
            self.assertEqual(result["event"], "EVENT-TEST")
            self.assertEqual(result["opportunity"], "")
            self.assertEqual(self.event.event_category, "Maintenance")
            self.assertEqual(len(self.run_api(action="get_references", category="Installation")["references"]), 1)
            result = self.run_api(category="Installation", opportunity="", location_row="",
                                  product_enquired="", reference_name="INST-1",
                                  reference_doctype="Installation Note", map_link="https://maps.google.com/?q=11,77",
                                  latitude="11", longitude="77", location_type="Site")
            self.assertEqual(result["event"], "EVENT-TEST")
            self.assertEqual(self.event.event_category, "Installation")

    def test_accounts_and_operations_categories_are_combined(self):
        for role in ["SCM Manager", "Delivery Manager"]:
            self.configure_category_policy(["Accounts User", role], "Other Company")
            self.assertEqual(set(self.run_api(action="get")["event_categories"]),
                             {"Bank", "Collection", "Other", "Installation",
                              "Complaint Visit", "Site Visit", "Maintenance"})

    def test_scm_and_delivery_other_labels_are_listed_and_create_without_location(self):
        for role in ["SCM Manager", "Delivery Manager"]:
            for label in ["Other", "Others"]:
                with self.subTest(role=role, label=label):
                    self.configure_category_policy([role], "Timbe Windows Private Limited")
                    category_field = self.metas["Event"].get_field("event_category")
                    category_field.options = category_field.options.replace("\nOther\n", "\n" + label + "\n")
                    categories = self.run_api(action="get")["event_categories"]
                    self.assertIn(label, categories)
                    self.assertNotIn("Bank", categories)
                    self.assertNotIn("Collection", categories)
                    result = self.run_api(category=label, opportunity="", location_row="", product_enquired="")
                    self.assertEqual(result["event"], "EVENT-TEST")
                    self.assertEqual(self.event.event_category, label)
                    self.assertEqual(result["location_row"], "")
                    self.assertEqual(self.created[-1].doctype, "ToDo")

    def test_all_creation_role_combinations_union_company_categories_without_duplicates(self):
        creation_roles = ["Sales Manager", "Accounts User", "SCM Manager", "Delivery Manager"]
        for count in range(1, len(creation_roles) + 1):
            for roles in combinations(creation_roles, count):
                for company in ["Bioman Sewage Solutions Private Limited",
                                "Homegenie Building Products Private Limited",
                                "Doortisan Creations Private Limited", "Timbe Windows Private Limited",
                                "Other Company", None]:
                    with self.subTest(roles=roles, company=company):
                        self.configure_category_policy(roles, company)
                        configured = self.metas["Event"].get_field("event_category").options.splitlines()
                        expected = set()
                        if "Sales Manager" in roles:
                            if company in ["Bioman Sewage Solutions Private Limited",
                                           "Homegenie Building Products Private Limited"]:
                                expected.update(["Measurement", "Collection", "Site Visit",
                                                 "Installation", "Complaint Visit"])
                            elif company in ["Doortisan Creations Private Limited", "Timbe Windows Private Limited"]:
                                expected.update(["Measurement", "Collection", "Site Visit"])
                            else:
                                expected.update(configured)
                        if "Accounts User" in roles:
                            expected.update(["Bank", "Collection", "Other"])
                        if "SCM Manager" in roles or "Delivery Manager" in roles:
                            expected.update(["Installation", "Complaint Visit", "Site Visit", "Maintenance", "Other"])
                        actual = self.run_api(action="get")["event_categories"]
                        self.assertEqual(actual, [category for category in configured if category in expected])
                        self.assertEqual(len(actual), len(set(actual)))

    def test_mixed_roles_create_categories_from_each_grant_and_reject_ungranted_categories(self):
        for roles in [["Sales Manager", "Accounts User"],
                      ["Sales Manager", "SCM Manager"],
                      ["Accounts User", "Delivery Manager"],
                      ["Sales Manager", "Accounts User", "SCM Manager", "Delivery Manager"]]:
            self.configure_category_policy(roles, "Timbe Windows Private Limited")
            categories = self.run_api(action="get")["event_categories"]
            for category in categories:
                with self.subTest(roles=roles, category=category):
                    params = {"category": category}
                    if category in ["Bank", "Collection", "Other", "Maintenance"]:
                        params.update(opportunity="", location_row="", product_enquired="")
                    elif category in ["Measurement", "Installation"]:
                        doctype, name = (("Measurement", "MEAS-1") if category == "Measurement"
                                         else ("Installation Note", "INST-1"))
                        self.assertEqual(len(self.run_api(action="get_references", category=category)["references"]), 1)
                        params.update(opportunity="", location_row="", product_enquired="",
                                      reference_doctype=doctype, reference_name=name,
                                      map_link="https://maps.google.com/?q=11,77",
                                      latitude="11", longitude="77", location_type="Site")
                    self.assertEqual(self.run_api(**params)["event"], "EVENT-TEST")
                    self.assertEqual(self.event.event_category, category)
            self.frappe.new_doc.reset_mock()
            with self.assertRaisesRegex(ValueError, "valid event category"):
                self.run_api(category="Training", company="Other Company", roles=["Sales Manager"])
            self.frappe.new_doc.assert_not_called()

    def test_mixed_roles_link_category_options_preserve_configured_labels(self):
        self.configure_category_policy(["Sales Manager", "Accounts User", "SCM Manager", "Delivery Manager"],
                                       "Timbe Windows Private Limited")
        category_field = self.metas["Event"].get_field("event_category")
        category_field.fieldtype = "Link"
        category_field.options = "Event Category"
        self.assertEqual(self.run_api(action="get")["event_categories"],
                         ["Installation", "Measurement", "SiteVisit"])

    def test_disallowed_categories_cannot_bypass_policy_using_direct_requests(self):
        for roles in [["Sales Manager"], ["Sales Manager", "Sales User"]]:
            for company in ["Bioman Sewage Solutions Private Limited",
                            "Homegenie Building Products Private Limited",
                            "Doortisan Creations Private Limited", "Timbe Windows Private Limited"]:
                self.configure_category_policy(roles, company)
                blocked = ["Bank", "Other", "Training", "Client Visit"]
                if company in ["Doortisan Creations Private Limited", "Timbe Windows Private Limited"]:
                    blocked.extend(["Installation", "Complaint Visit"])
                for category in blocked:
                    with self.subTest(roles=roles, company=company, category=category):
                        with self.assertRaisesRegex(ValueError, "valid event category"):
                            self.run_api(category=category, company="Other Company", user="other@example.test")
                if "Installation" in blocked:
                    with self.assertRaisesRegex(ValueError, "valid event category"):
                        self.run_api(action="get_references", category="Installation")
        self.frappe.new_doc.assert_not_called()
        self.frappe.get_doc.assert_not_called()
        self.frappe.get_list.assert_not_called()

    def test_company_policy_preserves_allowed_event_and_reference_workflows(self):
        for company in ["Bioman Sewage Solutions Private Limited",
                        "Homegenie Building Products Private Limited",
                        "Doortisan Creations Private Limited", "Timbe Windows Private Limited"]:
            with self.subTest(company=company):
                self.configure_category_policy(["Sales Manager", "Sales User"], company)
                self.assertEqual(self.run_api()["event"], "EVENT-TEST")
                self.assertEqual(self.run_api(category="Collection", opportunity="", location_row="",
                                              product_enquired="")["event"], "EVENT-TEST")
                self.assertEqual(len(self.run_api(action="get_references", category="Measurement")["references"]), 1)
                if company in ["Bioman Sewage Solutions Private Limited", "Homegenie Building Products Private Limited"]:
                    self.assertEqual(len(self.run_api(action="get_references", category="Installation")["references"]), 1)

    def test_all_link_categories_preserve_erp_spelling(self):
        self.configure_category_policy(["Sales Manager"], "Timbe Windows Private Limited")
        category_field = self.metas["Event"].get_field("event_category")
        category_field.fieldtype = "Link"
        category_field.options = "Event Category"
        self.assertEqual(self.run_api(action="get")["event_categories"],
                         ["Measurement", "SiteVisit"])

    def test_missing_allowed_configured_categories_never_returns_all_categories(self):
        self.configure_category_policy(["Sales Manager", "Sales User"], "Timbe Windows Private Limited")
        self.metas["Event"].get_field("event_category").options = "Bank\nTraining"
        with self.assertRaisesRegex(ValueError, "no configured categories allowed"):
            self.run_api(action="get")

    def test_sales_user_without_manager_still_cannot_create_or_load_creation_categories(self):
        self.configure_category_policy(["Sales User"], "Timbe Windows Private Limited")
        self.assertFalse(self.run_api(action="can_create")["can_create"])
        for action in ["get", "get_references", "create_event"]:
            with self.subTest(action=action), self.assertRaisesRegex(ValueError, "Sales Manager"):
                self.run_api(action=action)
        self.frappe.new_doc.assert_not_called()

    def test_other_companies_and_missing_employee_company_keep_existing_categories(self):
        for company in ["Other Company", None, ""]:
            self.configure_category_policy(["Sales Manager"], company)
            self.assertEqual(len(self.run_api(action="get")["event_categories"]), 18)

    def test_restricted_roles_cannot_bypass_button_with_direct_api_requests(self):
        for roles in [[], ["Employee"], ["Production User"], ["Production Manager"],
                      ["System Manager"], ["Sales User"], ["Designer"], ["Sales User", "Designer"],
                      ["Sales User", "Employee"], ["Designer", "Production User"]]:
            self.configure_category_policy(roles, "Other Company")
            for action in ["get", "get_references", "search_by_mobile", "save_location", "create_event"]:
                with self.subTest(roles=roles, action=action):
                    with self.assertRaisesRegex(ValueError, "Sales Manager role"):
                        self.run_api(action=action)
        self.frappe.get_all.assert_not_called()
        self.frappe.get_doc.assert_not_called()
        self.frappe.new_doc.assert_not_called()

    def test_other_creators_opportunities_can_be_listed_searched_and_linked(self):
        self.opportunity.owner = "other@example.test"
        for action in ["get", "search_by_mobile"]:
            result = self.run_api(action=action, mobile="98765")
            self.assertEqual(result["opportunities"][0]["name"], "OPP-1")
            self.assertEqual(result["opportunities"][0]["assigned_to"], "other@example.test")
        opportunity_queries = [call for call in self.frappe.get_all.call_args_list
                               if call.args[0] == "Opportunity"]
        self.assertEqual(opportunity_queries[-1].kwargs["limit_page_length"], 0)
        self.assertEqual(self.run_api()["event"], "EVENT-TEST")
        self.frappe.db.exists.assert_called_with("Opportunity", "OPP-1")

    def test_saving_other_creators_location_keeps_normal_document_permissions(self):
        self.opportunity.owner = "other@example.test"
        self.opportunity.save = Mock()
        self.frappe.utils.flt = float
        result = self.run_api(action="save_location", map_link=self.location.location,
                              location_type="Site", latitude="13", longitude="80")
        self.assertEqual(result["opportunity"], "OPP-1")
        self.opportunity.save.assert_called_once_with()
        self.frappe.db.exists.assert_called_with("Opportunity", "OPP-1")

    def test_opportunity_text_search_matches_id_title_and_customer_party(self):
        self.opportunity_rows.append(Row(
            name="CRM-OPP-2", title="Customer Project", party_name="CUST-2",
            opportunity_from="Customer", owner=self.user,
        ))
        for query, expected in [("OPP-1", "OPP-1"), ("Lokesh", "OPP-1"),
                                ("Customer Project", "CRM-OPP-2")]:
            with self.subTest(query=query):
                result = self.run_api(action="search_opportunities", query=query)
                self.assertEqual([row["name"] for row in result["opportunities"]], [expected])
                self.assertEqual(result["current_user"], self.user)
        self.frappe.get_all.assert_not_called()

    def test_opportunity_text_search_finds_records_outside_initial_500(self):
        self.opportunity_rows = [Row(name="UNRELATED-" + str(i)) for i in range(600)]
        self.opportunity_rows.append(self.opportunity)
        result = self.run_api(action="search_opportunities", query="OPP-1")
        self.assertEqual([row["name"] for row in result["opportunities"]], ["OPP-1"])

    def test_opportunity_text_search_is_bounded_and_returns_empty_for_no_match(self):
        self.opportunity_rows = [Row(name="MATCH-" + str(i)) for i in range(70)]
        self.assertEqual(len(self.run_api(action="search_opportunities", query="MATCH")["opportunities"]), 50)
        self.assertEqual(self.run_api(action="search_opportunities", query="missing")["opportunities"], [])

    def test_opportunity_text_search_validates_input_before_querying(self):
        for query in ["", " ", "a", "x" * 141, ["OPP-1"]]:
            with self.subTest(query=query), self.assertRaisesRegex(ValueError, "Opportunity ID or name"):
                self.run_api(action="search_opportunities", query=query)
        self.frappe.get_list.assert_not_called()

    def test_opportunity_text_search_preserves_document_permission_denial(self):
        self.frappe.get_list.side_effect = PermissionError("No Opportunity access")
        with self.assertRaises(PermissionError):
            self.run_api(action="search_opportunities", query="OPP-1")
        self.frappe.get_all.assert_not_called()

    def test_phone_search_prefilters_and_keeps_formatted_partial_and_lead_matches(self):
        self.metas["Opportunity"].fields.append(field("contact_mobile"))
        self.opportunity.contact_mobile = "(987) 65-43210"
        # This is a database LIKE candidate, but is not a consecutive digit
        # match and must not be offered by the form.
        self.opportunity_rows.append(Row(name="FALSE-MATCH", contact_mobile="9182736450"))
        result = self.run_api(action="search_by_mobile", mobile="98765")
        self.assertEqual([row["name"] for row in result["opportunities"]], ["OPP-1"])
        calls = self.frappe.get_all.call_args_list
        candidates = [call for call in calls if call.kwargs.get("or_filters")]
        self.assertEqual({call.args[0] for call in candidates}, {"Opportunity", "Lead"})
        for call in candidates:
            self.assertTrue(all(value[2] == "%9%8%7%6%5%" for value in call.kwargs["or_filters"]))
        details = [call for call in calls if "custom_product_enquired" in call.kwargs.get("fields", [])]
        self.assertEqual(len(details), 1)
        self.assertEqual(details[0].kwargs["filters"], {"name": ["in", ["OPP-1"]]})
        self.assertIn("contact_mobile", details[0].kwargs["fields"])

    def test_opportunity_id_search_does_not_match_linked_lead_id(self):
        self.assertEqual(self.run_api(action="search_opportunities", query="LEAD-1")["opportunities"], [])
        self.assertEqual(self.run_api(action="search_opportunities", query="OPP-1")["opportunities"][0]["name"], "OPP-1")

    def test_opportunity_phone_fields_find_customer_opportunities_without_a_lead(self):
        self.metas["Opportunity"].fields.extend([field("contact_mobile"), field("phone")])
        self.lead_rows = []
        self.opportunity.name = "CRM-OPP-2026-28718"
        self.opportunity.opportunity_from = "Customer"
        self.opportunity.party_name = "CUST-1"
        self.opportunity.contact_mobile = "+91 98738 23617"
        self.opportunity.phone = "044-12345678"
        for query in ["9873823617", "12345678"]:
            result = self.run_api(action="search_by_mobile", mobile=query)["opportunities"]
            self.assertEqual(result[0]["name"], "CRM-OPP-2026-28718")
            self.assertEqual(result[0]["contact_mobile"], "+91 98738 23617")
            self.assertEqual(result[0]["phone"], "044-12345678")

    def test_no_phone_matches_does_not_load_unfiltered_opportunities(self):
        result = self.run_api(action="search_by_mobile", mobile="8667733611")
        self.assertEqual(result["opportunities"], [])
        self.assertFalse(any(call.args[0] == "Opportunity" for call in self.frappe.get_all.call_args_list))

    def test_phone_search_finds_an_old_opportunity_outside_the_initial_500(self):
        self.opportunity_rows = [Row(name="UNRELATED-" + str(i), owner=self.user) for i in range(600)]
        self.opportunity_rows.append(self.opportunity)
        result = self.run_api(action="search_by_mobile", mobile="+91 98765 43210")
        self.assertEqual([row["name"] for row in result["opportunities"]], ["OPP-1"])

    def test_phone_matching_excludes_country_prefix_and_uses_last_ten_digits(self):
        self.lead_rows[0].mobile_no = "+12345 86677 33611"
        self.assertEqual(self.run_api(action="search_by_mobile", mobile="12345")["opportunities"], [])
        self.assertEqual(self.run_api(action="search_by_mobile", mobile="8667733611")["opportunities"][0]["name"], "OPP-1")


if __name__ == "__main__":
    unittest.main()
