"""Serve the PWA and proxy ERP on one loopback origin for local Chrome testing.

Run: python tool/serve_pwa_local.py --build
Production .env and build artifacts are never rewritten by this server.
"""
import argparse
import http.client
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import mimetypes
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit

from build_pwa import ROOT, public_environment

APP_PATH = "/genie/"
HOP_HEADERS = {"connection", "keep-alive", "proxy-authenticate",
               "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade"}


class LocalPwaServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port, output, values):
        site, api = urlsplit(values["SITE_URL"]), urlsplit(values["URL"])
        if site.scheme != "https" or site.path not in ("", "/") or site.username or site.password:
            raise ValueError("SITE_URL must be an HTTPS ERP origin without credentials.")
        if api.scheme != "https" or api.netloc != site.netloc or not api.path.startswith("/api/method/") or api.query or api.fragment:
            raise ValueError("URL must name an API method module on SITE_URL.")
        self.output = Path(output).resolve()
        self.upstream = site
        self.erp_origin = f"https://{site.netloc}"
        super().__init__(("127.0.0.1", port), LocalPwaHandler)
        self.local_origin = f"http://localhost:{self.server_port}"
        local_values = dict(values, SITE_URL=self.local_origin + "/",
                            URL=self.local_origin + api.path,
                            WEB_PROXY_ERP_ORIGIN=self.erp_origin)
        self.environment = "".join(f"{key}={value}\n" for key, value in local_values.items()).encode()


class LocalPwaHandler(SimpleHTTPRequestHandler):
    # No request bodies, cookies, tokens, usernames, or query strings in logs.
    def log_message(self, *_args):
        pass

    def _reply(self, status, body=b"", content_type="text/plain; charset=utf-8", location=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if location:
            self.send_header("Location", location)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _handle(self):
        server = self.server
        local = urlsplit(server.local_origin)
        # Reject DNS rebinding and requests initiated by unrelated websites.
        if self.headers.get("Host") != local.netloc:
            return self._reply(403, b"Use the printed localhost URL.")
        origin = self.headers.get("Origin")
        if origin and origin != server.local_origin:
            return self._reply(403, b"Cross-origin requests are not allowed.")
        if self.headers.get("Sec-Fetch-Site") == "cross-site":
            return self._reply(403, b"Cross-site requests are not allowed.")
        parsed = urlsplit(self.path)
        if parsed.scheme or parsed.netloc or not self.path.startswith("/") or self.path.startswith("//"):
            return self._reply(400, b"An origin-relative path is required.")
        if parsed.path == "/":
            return self._reply(302, location=APP_PATH)
        if parsed.path.startswith(APP_PATH):
            if self.command not in ("GET", "HEAD"):
                return self._reply(405)
            name = unquote(parsed.path[len(APP_PATH):]) or "index.html"
            if name == "assets/.env":
                return self._reply(200, server.environment)
            if name == "pwa-sw.js":
                # Local testing must not retain a stale environment in shell caches.
                body = ("self.addEventListener('install',()=>self.skipWaiting());"
                        "self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));").encode()
                return self._reply(200, body, "application/javascript")
            path = (server.output / name).resolve()
            if not path.is_relative_to(server.output) or not path.is_file():
                return self._reply(404)
            return self._reply(200, path.read_bytes(), mimetypes.guess_type(path.name)[0] or "application/octet-stream")
        self._proxy()

    def _proxy(self):
        server = self.server
        if self.headers.get("Transfer-Encoding"):
            return self._reply(400, b"Chunked request bodies are not supported.")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self._reply(400)
        if not 0 <= length <= 64 * 1024 * 1024:
            return self._reply(413)
        body = self.rfile.read(length) if length else None
        excluded = HOP_HEADERS | {"host", "accept-encoding"}
        excluded.update(part.strip().lower() for part in self.headers.get("Connection", "").split(","))
        headers = {key: value for key, value in self.headers.items() if key.lower() not in excluded}
        headers["Host"] = server.upstream.netloc
        headers["Accept-Encoding"] = "identity"
        # Map only this local origin. Frappe still validates the real CSRF token.
        for key in list(headers):
            if key.lower() in ("origin", "referer"):
                value = headers[key]
                if value == server.local_origin or value.startswith(server.local_origin + "/"):
                    headers[key] = server.erp_origin + value[len(server.local_origin):]
        connection = http.client.HTTPSConnection(server.upstream.hostname, server.upstream.port, timeout=45)
        started = False
        try:
            connection.request(self.command, self.path, body, headers)
            response = connection.getresponse()
            self.send_response(response.status)
            started = True
            excluded = HOP_HEADERS | {"content-length", "cache-control"}
            excluded.update(part.strip().lower() for part in (response.getheader("Connection") or "").split(","))
            for key, value in response.getheaders():
                if key.lower() in excluded:
                    continue
                if key.lower() == "set-cookie":
                    # Browser-owned localhost cookies; preserve Secure/HttpOnly/SameSite.
                    value = re.sub(r";\s*Domain=[^;]*", "", value, flags=re.I)
                elif key.lower() == "location":
                    if value == server.erp_origin or value.startswith(server.erp_origin + "/"):
                        value = server.local_origin + value[len(server.erp_origin):]
                self.send_header(key, value)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if self.command != "HEAD":
                while chunk := response.read(64 * 1024):
                    self.wfile.write(chunk)
        except (OSError, http.client.HTTPException):
            # Do not log credentials or disclose upstream exception details.
            if not started:
                self._reply(502, b"ERP could not be reached. Check your connection and retry.")
            self.close_connection = True
        finally:
            connection.close()

    do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = _handle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--build", action="store_true", help="Rebuild the PWA before serving.")
    args = parser.parse_args()
    values = public_environment(ROOT / ".env")
    if args.build:
        subprocess.run([sys.executable, str(ROOT / "tool/build_pwa.py")], check=True)
    output = ROOT / "build/web"
    index = output / "index.html"
    if not index.is_file() or '<base href="/genie/">' not in index.read_text(encoding="utf-8"):
        parser.error("Build is missing or uses another base path. Run again with --build.")
    with LocalPwaServer(args.port, output, values) as server:
        print(f"Open {server.local_origin}{APP_PATH}", flush=True)
        print(f"ERP requests go to {server.erp_origin}; use your normal ERP account.", flush=True)
        print("Local Chrome testing only. Ctrl+C stops the server. Production .env is unchanged.", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
