"""Run with: python -m unittest discover -s test -p site_visit_api_test.py"""
from datetime import datetime
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
            "Event Participants": meta("Event Participants", [
                field("reference_doctype"), field("reference_docname"), field("email"),
            ]),
        }
        self.event = Document()
        self.created = []
        self.frappe = SimpleNamespace(
            session=Row(user=self.user, data=Row(csrf_token="test-token")),
            response={}, get_meta=lambda name: self.metas[name],
            get_all=Mock(side_effect=self.get_all),
            get_doc=Mock(side_effect=self.get_doc), new_doc=Mock(return_value=self.event),
            db=SimpleNamespace(exists=Mock(return_value=True),
                               get_value=Mock(return_value=Row(name=self.user, full_name="Sales"))),
            utils=SimpleNamespace(get_datetime=datetime.fromisoformat,
                                  now_datetime=lambda: datetime(2026, 10, 12, 11)),
            throw=lambda message: (_ for _ in ()).throw(ValueError(message)),
        )
        self.params = dict(action="create_event", opportunity="OPP-1", location_row="LOC-1",
                           summary="Install doors", assigned_to=self.user, category="Installation",
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

    def get_doc(self, value, *args):
        if value == "Opportunity":
            return self.opportunity
        doc = Document(value)
        self.created.append(doc)
        return doc

    def run_api(self, **overrides):
        self.frappe.form_dict = dict(self.params, **overrides)
        exec(compile(self.script, "mobile_site_visit_api.py", "exec"), {"frappe": self.frappe})
        return self.frappe.response["message"]

    def test_selected_home_type_is_saved_without_optional_custom_type_field(self):
        self.location.location_type = "Home"
        result = self.run_api()
        self.assertEqual(self.event.location, "Home")
        self.assertEqual(self.event.custom_validate, self.location.location)
        self.assertEqual(result["location_type"], "Home")
        self.assertEqual(result["location_row"], "LOC-1")

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
        self.assertEqual(result["event_categories"], ["Installation", "Measurement", "Site Visit", "Client Visit"])
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
            self.assertEqual(set(row), {"name", "title", "party_name", "product_enquired", "assigned_to"})

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
        self.run_api(product_enquired="Windows", category="Measurement")
        self.assertEqual(self.event.custom_product_enquired, "Windows")
        self.assertEqual(self.opportunity.custom_product_enquired, "D'sign Doors")
        self.assertEqual(self.event.event_category, "Measurement")

    def test_opportunity_without_product_returns_empty_selection(self):
        self.opportunity.custom_product_enquired = ""
        result = self.run_api(action="get")
        self.assertEqual(result["opportunities"][0]["product_enquired"], "")
        self.assertEqual(result["product_enquired_options"], ["D'sign Doors", "Windows"])

    def test_category_options_and_validation_use_the_same_event_field(self):
        for category in ["", "Unknown", "Meeting", "Call"]:
            with self.subTest(category=category), self.assertRaises(ValueError):
                self.run_api(category=category)
        self.frappe.new_doc.assert_not_called()
        category_field = self.metas["Event"].get_field("event_category")
        category_field.fieldtype = "Link"
        category_field.options = "Event Category"
        result = self.run_api(action="get")
        self.assertEqual(result["event_categories"], ["Installation", "Measurement", "SiteVisit", "Client Visit"])
        self.run_api(category="Measurement")
        self.assertEqual(self.event.event_category, "Measurement")

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
        self.frappe.db.exists.side_effect = lambda doctype, filters: doctype == "Has Role"
        with self.assertRaisesRegex(ValueError, "existing opportunity"):
            self.run_api()
        self.frappe.db.exists.side_effect = None
        self.frappe.db.exists.return_value = True
        with self.assertRaisesRegex(ValueError, "does not belong"):
            self.run_api(location_row="OTHER-LOCATION")
        self.frappe.session.user = "Guest"
        with self.assertRaisesRegex(ValueError, "Sign in"):
            self.run_api()
        self.frappe.new_doc.assert_not_called()

    def test_capability_uses_session_role_and_does_not_load_form_data(self):
        for allowed in [True, False]:
            self.frappe.db.exists.return_value = allowed
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
            self.assertEqual(result["can_view_pending"], pending)
        self.frappe.get_all.assert_not_called()
        self.frappe.get_doc.assert_not_called()

    def test_non_manager_cannot_bypass_button_with_direct_api_requests(self):
        self.frappe.db.exists.return_value = False
        for action in ["get", "search_by_mobile", "save_location", "create_event"]:
            with self.subTest(action=action):
                with self.assertRaisesRegex(ValueError, "Sales Manager"):
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
        self.assertNotIn("contact_mobile", details[0].kwargs["fields"])

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
