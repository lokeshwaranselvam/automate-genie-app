import http.client
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tool"))
from serve_pwa_local import LocalPwaServer


class ProxyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        (self.root / "index.html").write_text("local app")
        self.server = LocalPwaServer(0, self.root, {
            "SITE_URL": "https://erp.example.test/",
            "URL": "https://erp.example.test/api/method/itgenie.api_utils",
        })
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.directory.cleanup()

    def request(self, path, method="GET", body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port)
        connection.request(method, path, body, {"Host": self.server.local_origin.removeprefix("http://"), **(headers or {})})
        response = connection.getresponse()
        result = response.status, response.getheaders(), response.read()
        connection.close()
        return result

    def test_environment_is_local_without_changing_the_build(self):
        (self.root / "assets").mkdir()
        original = b"SITE_URL=https://erp.example.test/"
        (self.root / "assets/.env").write_bytes(original)
        status, _, body = self.request("/genie/assets/.env")
        self.assertEqual(status, 200)
        self.assertIn(f"URL={self.server.local_origin}/api/method/itgenie.api_utils".encode(), body)
        self.assertIn(b"WEB_PROXY_ERP_ORIGIN=https://erp.example.test", body)
        self.assertEqual((self.root / "assets/.env").read_bytes(), original)

    def test_foreign_origin_and_dns_rebinding_cannot_reach_erp(self):
        with patch("serve_pwa_local.http.client.HTTPSConnection") as upstream:
            for headers in ({"Host": "attacker.test"}, {"Origin": "https://attacker.test"}, {"Origin": "null"}, {"Sec-Fetch-Site": "cross-site"}):
                self.assertEqual(self.request("/api/method/logout", "POST", headers=headers)[0], 403)
            upstream.assert_not_called()

    def test_login_cookie_and_csrf_are_forwarded_without_a_shared_cookie_jar(self):
        with patch("serve_pwa_local.http.client.HTTPSConnection") as upstream:
            response = upstream.return_value.getresponse.return_value
            response.status = 200
            response.getheader.return_value = None
            response.getheaders.return_value = [
                ("Set-Cookie", "sid=test; Domain=erp.example.test; Path=/; Secure; HttpOnly; SameSite=Lax"),
                ("Set-Cookie", "user_id=test; Path=/; Secure"),
                ("Content-Type", "application/json"),
            ]
            response.read.side_effect = [b'{"message":"test"}', b""]
            status, headers, _ = self.request("/api/method/itgenie.api_utils.login", "POST", b"{}", {
                "Cookie": "sid=previous", "X-Frappe-CSRF-Token": "csrf-test",
                "Origin": self.server.local_origin, "Referer": self.server.local_origin + "/genie/",
                "Content-Type": "application/json",
            })
            self.assertEqual(status, 200)
            cookies = [value for key, value in headers if key.lower() == "set-cookie"]
            self.assertEqual(len(cookies), 2)
            self.assertEqual(cookies[0], "sid=test; Path=/; Secure; HttpOnly; SameSite=Lax")
            forwarded = upstream.return_value.request.call_args.args
            self.assertEqual(forwarded[:3], ("POST", "/api/method/itgenie.api_utils.login", b"{}"))
            self.assertEqual(forwarded[3]["Cookie"], "sid=previous")
            self.assertEqual(forwarded[3]["X-Frappe-CSRF-Token"], "csrf-test")
            self.assertEqual(forwarded[3]["Origin"], "https://erp.example.test")
            self.assertEqual(forwarded[3]["Referer"], "https://erp.example.test/genie/")

    def test_static_traversal_is_rejected_and_local_worker_does_not_cache(self):
        self.assertEqual(self.request("/genie/%2e%2e/index.html")[0], 404)
        status, _, body = self.request("/genie/pwa-sw.js")
        self.assertEqual(status, 200)
        self.assertNotIn(b"caches.open", body)
        self.assertNotIn(b"'fetch'", body)

    def test_upstream_failure_returns_a_safe_gateway_error(self):
        with patch("serve_pwa_local.http.client.HTTPSConnection") as upstream:
            upstream.return_value.request.side_effect = OSError("sensitive internal detail")
            status, _, body = self.request("/api/method/ping")
            self.assertEqual(status, 502)
            self.assertNotIn(b"sensitive", body)


if __name__ == "__main__":
    unittest.main()
