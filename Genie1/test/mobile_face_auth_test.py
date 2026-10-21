"""Run with: python -m unittest discover -s test -p mobile_face_auth_test.py.

The mock intentionally exposes only the Frappe namespaces used in safe_exec,
not request.files/method, session.sid, cache, SQL, or custom app imports.
"""
import base64
from datetime import datetime
import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
import unittest


class Row(dict):
    __getattr__ = dict.get
    __setattr__ = dict.__setitem__


class Document(Row):
    def get_content(self):
        if self.decode:
            self.decode_calls = (self.decode_calls or 0) + 1
            content = base64.b64decode(self.content, validate=True)
            self.decode = False
            return content
        return self.content

    def check_permission(self, action):
        if not self.get("read_allowed", True):
            raise ValueError("Event read denied")

    def save(self, ignore_permissions=False):
        self.store[self.name] = self
        return self

    def has_value_changed(self, field):
        return self.get("previous", {}).get(field) != self.get(field)

    def insert(self, ignore_permissions=False, set_name=None):
        store = self.store
        name = set_name or "DOC-" + str(len(store) + 1)
        if name in store:
            raise ValueError("Duplicate primary key")
        self.name = name
        self.owner = self.current_user
        self.creation = "2026-10-12 10:00:00"
        if self.doctype == "File":
            content = self.get_content()
            self.content_hash = hashlib.sha256(content).hexdigest()
            self.file_url = "/private/files/" + name + ".jpg"
        store[name] = self
        return self


class MobileFaceAuthTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = (Path(__file__).resolve().parents[1] /
                      "frappe_server_scripts/mobile_face_auth.py").read_text()

    def setUp(self):
        self.user = "employee@example.test"
        self.store = {}
        self.created = []
        self.events = {}
        self.error_logs = []
        self.jpg = b"\xff\xd8\xff" + b"live-selfie" + b"\xff\xd9"
        self.encoded = base64.b64encode(self.jpg).decode()
        self.frappe = SimpleNamespace(
            session=Row(user=self.user, csrf_token="csrf-test"), response={},
            form_dict=Row(), get_doc=self.get_doc,
            get_meta=lambda doctype: SimpleNamespace(has_field=lambda field: False),
            db=SimpleNamespace(get_value=self.get_value, exists=self.exists, set_value=self.set_value),
            log_error=self.log_error,
            utils=SimpleNamespace(
                sha256_hash=lambda value: hashlib.sha256(value.encode()).hexdigest(),
                flt=lambda value: float(value or 0),
                now=lambda: "2026-10-12 10:00:00",
                now_datetime=datetime.now,
                time_diff_in_seconds=lambda first, second: (
                    datetime.fromisoformat(str(first)) - datetime.fromisoformat(str(second))
                ).total_seconds(),
            ),
            throw=lambda message: (_ for _ in ()).throw(ValueError(message)),
        )

    def log_error(self, **kwargs):
        self.error_logs.append(kwargs)

    def get_doc(self, value, name=None, **kwargs):
        if isinstance(value, dict):
            doc = Document(value, store=self.store, current_user=self.frappe.session.user)
            self.created.append(doc)
            return doc
        if value == "Event":
            return self.events[name]
        return self.store[name]

    def get_value(self, doctype, name, fields, as_dict=False):
        if doctype == "Employee":
            return self.user if name == "EMP-1" else "other@example.test"
        self.assertEqual(doctype, "File")
        row = self.store.get(name)
        return Row({field: row.get(field) for field in fields}) if row else None

    def exists(self, doctype, name):
        if doctype == "ToDo" and isinstance(name, dict):
            return any(
                row.get("doctype") == "ToDo"
                and all(row.get(key) == value for key, value in name.items() if key != "status")
                and row.get("status") not in ["Cancelled", "Closed"]
                for row in self.store.values()
            )
        return (doctype == "Event" and name in self.events) or (doctype == "Comment" and name in self.store)

    def set_value(self, doctype, name, field, value):
        self.assertEqual(doctype, "Comment")
        self.store[name][field] = value

    def run_api(self, action="status", **params):
        self.frappe.form_dict = Row(action=action, **params)
        self.frappe.response = {}
        exec(compile(self.script, "mobile_face_auth.py", "exec"),
             {"frappe": self.frappe, "json": json})
        return self.frappe.response["message"]

    def enroll(self, **params):
        values = dict(
            image_base64=self.encoded, csrf_token="csrf-test",
            model_version="opencv-sface-2021dec-v1", blink_completed=True)
        values.update(params)
        return self.run_api("enroll", **values)

    def verify(self, **params):
        reference = self.run_api()["reference_file"]
        values = dict(
            csrf_token="csrf-test",
            reference_file=reference["name"], reference_version=reference["version"],
            verification_action="attendance_in", model_version="opencv-sface-2021dec-v1",
            similarity=0.7, blink_completed=True, latitude=13.01, longitude=80.1,
            captured_on="2026-10-12T10:00:00", event="",
        )
        values.update(params)
        return self.run_api("record_verification", **values)

    def test_guest_cannot_read_status_or_enroll(self):
        self.frappe.session.user = "Guest"
        for action in ["status", "enroll", "record_verification"]:
            with self.subTest(action=action), self.assertRaisesRegex(ValueError, "Sign in"):
                self.run_api(action)
        self.assertFalse(self.created)

    def test_model_version_negotiation_preserves_existing_clients(self):
        self.assertEqual(self.run_api()["model_version"], "opencv-sface-2021dec-v1")
        version = "opencv-sface-2021dec-int8bq-v1"
        self.assertEqual(self.run_api(model_version=version)["model_version"], version)
        self.enroll(model_version=version)
        result = self.verify(model_version=version)
        metadata = json.loads(self.store[result["record_id"]].content)
        self.assertEqual(metadata["model_version"], version)
        with self.assertRaisesRegex(ValueError, "model has changed"):
            self.run_api(model_version="unknown")

    def test_status_is_read_only_and_returns_no_other_user_reference(self):
        result = self.run_api()
        self.assertFalse(result["enrolled"])
        self.assertIsNone(result["reference_file"])
        self.assertEqual(result["csrf_token"], "csrf-test")
        self.assertFalse(self.created)
        self.enroll()
        self.frappe.session.user = "another@example.test"
        self.assertFalse(self.run_api()["enrolled"])

    def test_first_photo_is_private_and_attached_only_to_authenticated_user(self):
        result = self.enroll(user="other@example.test", attached_to_name="other@example.test")
        doc = self.store[result["reference_file"]["name"]]
        self.assertEqual((doc.attached_to_doctype, doc.attached_to_name, doc.owner),
                         ("User", self.user, self.user))
        self.assertEqual(doc.is_private, 1)
        self.assertEqual(doc.content, self.jpg)
        self.assertEqual(doc.decode_calls, 1)
        self.assertEqual(self.run_api()["reference_file"], result["reference_file"])

    def test_enrollment_never_overwrites_existing_reference(self):
        reference = self.enroll()["reference_file"]
        with self.assertRaisesRegex(ValueError, "already registered"):
            self.enroll()
        self.assertEqual(len(self.store), 1)
        self.assertEqual(self.run_api()["reference_file"], reference)

    def test_verification_never_creates_a_file_even_for_legacy_image_payload(self):
        self.enroll()
        for params in [{}, {"image_base64": self.encoded}]:
            result = self.verify(**params)
            self.assertEqual(result["receipt_version"], 2)
            self.assertNotIn("evidence_file", result)
            self.assertNotIn("photo_url", result)
        self.assertEqual(sum(row.doctype == "File" for row in self.created), 1)

    def test_invalid_base64_characters_at_any_position_are_rejected(self):
        for char in ["!", " ", "\n", "\t", "é"]:
            for position in [0, len(self.encoded) // 2, len(self.encoded) - 1]:
                value = self.encoded[:position] + char + self.encoded[position + 1:]
                with self.subTest(char=char, position=position):
                    with self.assertRaisesRegex(ValueError, "encoding is invalid"):
                        self.enroll(image_base64=value)
        self.assertFalse(self.store)

    def test_server_timings_are_optional_and_contain_only_durations(self):
        self.enroll()
        self.verify()
        self.assertNotIn("attendance_timings_ms", self.frappe.response)
        result = self.verify(include_timings=True)
        timings = self.frappe.response["attendance_timings_ms"]
        self.assertEqual(set(timings), {
            "request_validation",
            "receipt_insert", "receipt_secure", "verification_total",
        })
        self.assertTrue(all(isinstance(value, (int, float)) and value >= 0
                            for value in timings.values()))
        self.assertEqual(self.store[result["record_id"]].owner, "Administrator")

    def test_csrf_body_required_for_all_mutations(self):
        for token in [None, "wrong"]:
            with self.subTest(token=token), self.assertRaisesRegex(ValueError, "session token"):
                self.run_api("enroll", image_base64=self.encoded, csrf_token=token)
        self.enroll()
        with self.assertRaisesRegex(ValueError, "session token"):
            self.verify(csrf_token="wrong")
        self.assertEqual(len(self.store), 1)

    def test_session_data_csrf_fallback_for_older_frappe(self):
        self.frappe.session = Row(user=self.user, data=Row(csrf_token="csrf-test"))
        self.assertEqual(self.run_api()["csrf_token"], "csrf-test")
        self.enroll()

    def test_invalid_jpeg_base64_and_oversize_are_rejected_without_insert(self):
        invalid = ["", "not-base64!", "====", base64.b64encode(b"not a JPEG").decode(),
                   base64.b64encode(b"\xff\xd8\xff" + b"x" * (2 * 1024 * 1024) + b"\xff\xd9").decode()]
        for data in invalid:
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                self.run_api("enroll", image_base64=data, csrf_token="csrf-test",
                             model_version="opencv-sface-2021dec-v1", blink_completed=True)
        self.assertFalse(self.store)

    def test_enrollment_requires_the_configured_model_and_live_blink_assertion(self):
        for params in [{"model_version": "old", "blink_completed": True},
                       {"model_version": "opencv-sface-2021dec-v1", "blink_completed": False}]:
            with self.subTest(params=params), self.assertRaises(ValueError):
                self.run_api("enroll", image_base64=self.encoded, csrf_token="csrf-test", **params)
        self.assertFalse(self.store)

    def test_tampered_public_or_other_owner_reference_fails_closed(self):
        name = self.enroll()["reference_file"]["name"]
        for field, value in [("is_private", 0), ("owner", "other@example.test"),
                             ("attached_to_name", "other@example.test")]:
            doc = self.store[name]
            original = doc[field]
            doc[field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "reference is invalid"):
                self.run_api()
            doc[field] = original

    def test_daily_receipt_has_no_photo_and_is_system_owned(self):
        self.enroll()
        result = self.verify()
        receipt = self.store[result["record_id"]]
        metadata = json.loads(receipt.content)
        self.assertEqual(metadata["version"], 2)
        self.assertNotIn("evidence_file", metadata)
        self.assertNotIn("photo_url", metadata)
        self.assertEqual((receipt.reference_doctype, receipt.reference_name), ("User", self.user))
        self.assertEqual((receipt.owner, receipt.comment_type), ("Administrator", "Info"))
        self.assertEqual(metadata["current_user"], self.user)
        self.assertEqual(metadata["received_on"], "2026-10-12 10:00:00")
        self.assertFalse(metadata["used"])
        self.assertEqual(metadata["verification_source"], "device_reported")

    def test_unexpected_verification_type_error_is_written_to_error_log(self):
        self.enroll()

        def raise_type_error(value):
            raise TypeError("simulated conversion failure")

        self.frappe.utils.flt = raise_type_error
        with self.assertRaisesRegex(TypeError, "simulated conversion failure"):
            self.verify()

        self.assertEqual(len(self.error_logs), 1)
        self.assertEqual(
            self.error_logs[0]["title"], "Genie Face Verification TypeError"
        )
        self.assertTrue(self.error_logs[0]["defer_insert"])
        self.assertIn(
            "Stage: validating match and GPS values",
            self.error_logs[0]["message"],
        )
        self.assertIn("simulated conversion failure", self.error_logs[0]["message"])

    def test_wrong_face_no_blink_stale_template_and_invalid_coordinates_create_no_evidence(self):
        self.enroll()
        invalid = [{"similarity": 0.49}, {"similarity": float("nan")},
                   {"similarity": float("inf")}, {"blink_completed": False},
                   {"reference_file": "another-file"}, {"reference_version": "old"},
                   {"model_version": "unknown"}, {"latitude": float("nan")},
                   {"latitude": 91}, {"longitude": 181}, {"latitude": None},
                   {"verification_action": "approve"}, {"event": "EVENT-1"},
                   {"verification_action": "event_in"},
                   {"verification_action": "event_out"}]
        for values in invalid:
            with self.subTest(values=values), self.assertRaises(ValueError):
                self.verify(**values)
        self.assertEqual(len(self.store), 1)

    def test_event_actions_are_rejected_without_creating_evidence(self):
        self.enroll()
        for action in ["event_in", "event_out"]:
            with self.subTest(action=action), self.assertRaisesRegex(
                ValueError, "only available for attendance"
            ):
                self.verify(verification_action=action)
        self.assertEqual(len(self.store), 1)

    def test_receipt_json_survives_html_sensitive_usernames_and_capture_strings(self):
        self.user = "sales&support@example.test"
        self.frappe.session.user = self.user
        self.enroll()
        result = self.verify(captured_on="<client&time>")
        content = self.store[result["record_id"]].content
        self.assertNotIn("&", content)
        self.assertNotIn("<", content)
        metadata = json.loads(content)
        self.assertEqual(metadata["current_user"], self.user)
        self.assertEqual(metadata["captured_on"], "<client&time>")


class MobileFaceGuardTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = (Path(__file__).resolve().parents[1] /
                      "frappe_server_scripts/mobile_face_auth.py").read_text()

    def setUp(self):
        MobileFaceAuthTest.setUp(self)
        self.user = "lokeshwaran.trainee@homegeniegroup.com"
        self.frappe.session.user = self.user

    log_error = MobileFaceAuthTest.log_error
    get_doc = MobileFaceAuthTest.get_doc
    get_value = MobileFaceAuthTest.get_value
    exists = MobileFaceAuthTest.exists
    set_value = MobileFaceAuthTest.set_value
    run_api = MobileFaceAuthTest.run_api
    enroll = MobileFaceAuthTest.enroll
    verify = MobileFaceAuthTest.verify

    def run_guard(self, name, doc, **params):
        self.frappe.form_dict = Row(params)
        script = (Path(__file__).resolve().parents[1] /
                  "frappe_server_scripts" / (name + ".py")).read_text()
        exec(compile(script, name + ".py", "exec"),
             {"frappe": self.frappe, "json": json, "doc": doc})

    def daily(self, receipt, **params):
        values = dict(cmd="company.api.checkin", face_verification=receipt["record_id"])
        values.update(params)
        self.run_guard("mobile_face_employee_checkin_guard",
                       Document(employee="EMP-1", log_type="IN"), **values)

    def attach_daily_photo(self, receipt, **params):
        values = dict(cmd="company.api.checkin", face_verification=receipt["record_id"])
        values.update(params)
        self.run_guard(
            "mobile_face_employee_checkin_attach",
            Document(name="CHECKIN-1"),
            **values,
        )

    def test_both_rollout_users_require_receipts_for_checkin_and_checkout(self):
        for user in ("lokeshwaran.trainee@homegeniegroup.com",
                     "arun.itdigital@homegeniegroup.com"):
            self.user = user
            self.frappe.session.user = user
            for command, log_type in (("itgenie.api.checkin", "IN"),
                                      ("itgenie.api.checkout", "OUT")):
                with self.subTest(user=user, command=command):
                    with self.assertRaisesRegex(ValueError, "Complete face verification"):
                        self.run_guard("mobile_face_employee_checkin_guard",
                                       Document(employee="EMP-1", log_type=log_type), cmd=command)
                    with self.assertRaisesRegex(ValueError, "receipt is missing"):
                        self.run_guard("mobile_face_employee_checkin_attach",
                                       Document(name="CHECKIN-1"), cmd=command)

    def test_other_users_skip_both_receipt_hooks_without_modifying_records(self):
        self.user = "employee@example.test"
        self.frappe.session.user = self.user
        for command, log_type in (("itgenie.api.checkin", "IN"),
                                  ("itgenie.api.checkout", "OUT")):
            self.run_guard("mobile_face_employee_checkin_guard",
                           Document(employee="EMP-1", log_type=log_type), cmd=command)
            self.run_guard("mobile_face_employee_checkin_attach",
                           Document(name="CHECKIN-1"), cmd=command)
        self.assertEqual(self.store, {})

    def test_other_users_still_cannot_submit_for_another_employee_or_wrong_action(self):
        self.user = "employee@example.test"
        self.frappe.session.user = self.user
        for employee, log_type in (("EMP-OTHER", "IN"), ("EMP-1", "OUT")):
            with self.assertRaisesRegex(ValueError, "employee or action"):
                self.run_guard("mobile_face_employee_checkin_guard",
                               Document(employee=employee, log_type=log_type),
                               cmd="itgenie.api.checkin")

    def test_guest_still_blocked_in_both_hooks(self):
        self.frappe.session.user = "Guest"
        for script in ("mobile_face_employee_checkin_guard", "mobile_face_employee_checkin_attach"):
            with self.assertRaisesRegex(ValueError, "Sign in"):
                self.run_guard(script, Document(employee="EMP-1", log_type="IN"),
                               cmd="itgenie.api.checkin")

    def test_int8_block_receipt_is_consumed_by_existing_attendance_guard(self):
        version = "opencv-sface-2021dec-int8bq-v1"
        self.enroll(model_version=version)
        receipt = self.verify(model_version=version)
        self.daily(receipt)
        self.assertTrue(json.loads(self.store[receipt["record_id"]].content)["used"])
        with self.assertRaisesRegex(ValueError, "used or expired"):
            self.daily(receipt)

    def test_daily_valid_receipt_consumed_and_cannot_be_replayed(self):
        self.enroll()
        receipt = self.verify()
        self.daily(receipt)
        self.assertTrue(json.loads(self.store[receipt["record_id"]].content)["used"])
        with self.assertRaisesRegex(ValueError, "used or expired"):
            self.daily(receipt)

    def test_profile_timings_preserve_receipt_consumption_and_attachment(self):
        self.enroll()
        receipt = self.verify()
        self.daily(receipt, include_timings="1")
        self.attach_daily_photo(receipt, include_timings="1")
        timings = self.frappe.response["attendance_timings_ms"]
        self.assertEqual(set(timings), {
            "receipt_lock", "guard_total", "attach_total",
        })
        self.assertTrue(all(value >= 0 for value in timings.values()))
        self.assertEqual(json.loads(self.store[receipt["record_id"]].content)["used_for_name"], "CHECKIN-1")
        with self.assertRaisesRegex(ValueError, "used or expired"):
            self.daily(receipt, include_timings="1")

    def test_receipt_links_to_exact_checkin_without_file_save(self):
        self.enroll()
        receipt = self.verify()
        self.daily(receipt)
        self.attach_daily_photo(receipt)
        self.assertEqual(json.loads(self.store[receipt["record_id"]].content)["used_for_name"], "CHECKIN-1")
        self.assertEqual(sum(row.doctype == "File" for row in self.created), 1)
        with self.assertRaisesRegex(ValueError, "already linked"):
            self.attach_daily_photo(receipt)

    def test_non_string_receipt_id_is_rejected_cleanly_by_checkin_hooks(self):
        doc = Document(employee="EMP-1", log_type="IN")
        with self.assertRaisesRegex(ValueError, "Complete face verification"):
            self.run_guard(
                "mobile_face_employee_checkin_guard",
                doc,
                cmd="company.api.checkin",
                face_verification=123,
            )
        with self.assertRaisesRegex(ValueError, "face verification receipt is missing"):
            self.run_guard(
                "mobile_face_employee_checkin_attach",
                Document(name="CHECKIN-1"),
                cmd="company.api.checkin",
                face_verification=123,
            )

    def test_missing_receipts_block_only_mobile_calls(self):
        self.run_guard("mobile_face_employee_checkin_guard",
                       Document(employee="EMP-1", log_type="IN"), cmd="frappe.desk.form.save.savedocs")
        with self.assertRaisesRegex(ValueError, "Complete face verification"):
            self.run_guard("mobile_face_employee_checkin_guard",
                           Document(employee="EMP-1", log_type="IN"), cmd="company.api.checkin")

    def test_receipt_for_wrong_action_other_employee_or_different_photo_rejected(self):
        self.enroll()
        receipt = self.verify(verification_action="attendance_out")
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.daily(receipt)
        receipt = self.verify()
        with self.assertRaisesRegex(ValueError, "employee or action"):
            self.run_guard("mobile_face_employee_checkin_guard",
                           Document(employee="EMP-OTHER", log_type="IN"),
                           cmd="company.api.checkin", face_verification=receipt["record_id"])
        self.assertFalse(json.loads(self.store[receipt["record_id"]].content)["used"])

    def test_expired_and_future_receipts_rejected_using_server_creation(self):
        self.enroll()
        for created in ["2026-10-12 09:57:59", "2026-10-12 10:00:01"]:
            receipt = self.verify()
            self.store[receipt["record_id"]].creation = created
            with self.subTest(created=created), self.assertRaisesRegex(ValueError, "used or expired"):
                self.daily(receipt)

    def test_changed_reference_and_legacy_receipt_rejected(self):
        self.enroll()
        receipt = self.verify()
        reference_id = self.run_api()["reference_file"]["name"]
        original = self.store[reference_id].content_hash
        self.store[reference_id].content_hash = "different"
        with self.assertRaisesRegex(ValueError, "reference has changed"):
            self.daily(receipt)
        self.store[reference_id].content_hash = original
        record = self.store[receipt["record_id"]]
        metadata = json.loads(record.content)
        metadata["version"] = 1
        record.content = json.dumps(metadata)
        with self.assertRaisesRegex(ValueError, "format has changed"):
            self.daily(receipt)

    def test_user_owned_editable_comment_cannot_be_used_as_receipt(self):
        self.enroll()
        receipt = self.verify()
        self.store[receipt["record_id"]].owner = self.user
        with self.assertRaisesRegex(ValueError, "does not belong"):
            self.daily(receipt)
        self.assertFalse(json.loads(self.store[receipt["record_id"]].content)["used"])


if __name__ == "__main__":
    unittest.main()
