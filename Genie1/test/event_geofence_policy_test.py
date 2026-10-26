"""Exercise the custom-app event_details response without a live Frappe site."""
import ast
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock


class EventGeofencePolicyTest(unittest.TestCase):
    def test_category_policy_preserves_event_and_participant_response(self):
        for filename in ("api_utils.py", "api_single_device_updated.py"):
            path = Path(__file__).resolve().parents[1] / "backend_patches" / filename
            tree = ast.parse(path.read_text(encoding="utf-8"))
            function = next(node for node in tree.body
                            if isinstance(node, ast.FunctionDef) and node.name == "event_details")
            function.decorator_list = []
            for category in ("Installation", " installation ", "INSTALLATION",
                             "Measurement", " measurement ", "MEASUREMENT",
                             "Other", "Others", " Bank ", "Head Office CH",
                             "Timbe / Bioman Office CH", "Collection", "COLLECTION",
                             "Site Visit", "SiteVisit", "Client Visit",
                             "Complaint Visit", "Meeting", "", None):
                with self.subTest(filename=filename, category=category):
                    participant = SimpleNamespace(reference_doctype="Opportunity",
                                                  reference_docname="OPP-1")
                    event_data = {"name": "EVENT-1", "event_category": category,
                                  "event_participants": [participant]}
                    event = Mock()
                    event.as_dict.return_value = event_data
                    event.get.side_effect = lambda key, default=None: event_data.get(key, default)
                    opportunity = SimpleNamespace(
                        opportunity_from="Customer", party_name="CUSTOMER-1",
                        custom_product_enquired="Doors", contact_mobile="1234567890")
                    frappe = Mock()
                    frappe.get_doc.side_effect = [event, opportunity]
                    namespace = {"frappe": frappe}
                    exec(compile(ast.Module(body=[function], type_ignores=[]), str(path), "exec"), namespace)
                    result = namespace["event_details"]("EVENT-1")
                    self.assertEqual(result, {
                        "event": event_data,
                        "requires_geofence": category not in (
                            "Installation", " installation ", "INSTALLATION",
                            "Measurement", " measurement ", "MEASUREMENT",
                            "Other", "Others", " Bank ", "Head Office CH",
                            "Timbe / Bioman Office CH", "Collection", "COLLECTION"),
                        "reference_details": [{
                            "doctype": "Opportunity", "name": "OPP-1",
                            "opportunity_from": "Customer", "party_name": "CUSTOMER-1",
                            "custom_product_enquired": "Doors", "contact_mobile": "1234567890",
                        }],
                    })
                    self.assertEqual(frappe.get_doc.call_count, 2)
                    event.save.assert_not_called()


if __name__ == "__main__":
    unittest.main()
