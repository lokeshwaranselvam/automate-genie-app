"""Tests for the narrowly scoped deployment repair; no live ERP writes."""
import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest import TestCase
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[1]


class RepairMobileSiteVisitApiTest(TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = ROOT / "frappe_server_scripts/mobile_site_visit_api.py"
        self.old_source = 'frappe.throw("event_id is required.")'
        self.doc = SimpleNamespace(
            name="Existing Visits API", script=self.old_source,
            script_type="API", disabled=0,
            api_method="mobile_site_visit", allow_guest=0, enable_rate_limit=1,
            check_permission=Mock(), save=Mock(), clear_cache=Mock(),
        )
        self.doc.as_dict = lambda: {
            "name": self.doc.name, "script": self.doc.script,
            "api_method": self.doc.api_method, "allow_guest": 0,
        }
        self.frappe = SimpleNamespace(
            only_for=Mock(), local=SimpleNamespace(site="erp.example.test"),
            get_all=Mock(return_value=[SimpleNamespace(name=self.doc.name)]),
            get_doc=Mock(return_value=self.doc), as_json=json.dumps,
            get_site_path=lambda *parts: str(Path(self.temp.name).joinpath(*parts)),
            db=SimpleNamespace(commit=Mock(), rollback=Mock()),
        )
        with patch.dict("sys.modules", {"frappe": self.frappe}):
            spec = importlib.util.spec_from_file_location(
                "api_repair_test_module", ROOT / "backend_patches/repair_mobile_site_visit_api.py"
            )
            self.module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.module)

    def test_preview_does_not_write(self):
        result = self.module.repair_mobile_site_visit(self.source)
        self.assertEqual(result["status"], "ready")
        self.assertEqual(self.doc.script, self.old_source)
        self.doc.save.assert_not_called()
        self.frappe.db.commit.assert_not_called()

    def test_repair_backs_up_and_updates_only_target_body(self):
        result = self.module.repair_mobile_site_visit(self.source, apply=True)
        self.assertEqual(result["status"], "repaired")
        self.assertEqual(json.loads(Path(result["backup"]).read_text())["script"], self.old_source)
        self.assertEqual(self.doc.script, self.source.read_text(encoding="utf-8-sig"))
        self.assertEqual(self.doc.api_method, "mobile_site_visit")
        self.assertEqual(self.doc.allow_guest, 0)
        self.assertEqual(self.doc.enable_rate_limit, 1)
        self.doc.save.assert_called_once_with()
        self.frappe.db.commit.assert_called_once_with()
        self.doc.clear_cache.assert_called_once_with()
        self.frappe.only_for.assert_called_once_with("Script Manager")

    def test_missing_or_duplicate_enabled_mapping_stops_without_changes(self):
        for rows in [[], [SimpleNamespace(name="A"), SimpleNamespace(name="B")]]:
            self.frappe.get_all.return_value = rows
            with self.assertRaisesRegex(ValueError, "exactly one"):
                self.module.repair_mobile_site_visit(self.source, apply=True)
        self.doc.save.assert_not_called()

    def test_custom_permission_api_is_not_overwritten(self):
        self.doc.script = 'if action == "can_create":\n    pass'
        with self.assertRaisesRegex(ValueError, "without overwriting"):
            self.module.repair_mobile_site_visit(self.source, apply=True)
        self.doc.save.assert_not_called()

    def test_save_failure_rolls_back(self):
        self.doc.save.side_effect = ValueError("Save rejected")
        with self.assertRaisesRegex(ValueError, "Save rejected"):
            self.module.repair_mobile_site_visit(self.source, apply=True)
        self.frappe.db.rollback.assert_called_once_with()
        self.frappe.db.commit.assert_not_called()
