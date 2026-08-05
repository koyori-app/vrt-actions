#!/usr/bin/env python3
"""Minimal fake of the VRT CI REST API for the screenshots-mode e2e test.

Binds 127.0.0.1 on an ephemeral port, prints the port on stdout, then serves
until killed. Every uploaded screenshot is recorded as a JSON line in
$RECORD_FILE: {"name_b64": ..., "sha256": ..., "size": ...}. The name is
base64-encoded so names containing newlines survive the line-oriented log.

The first status poll returns "processing" so the poll loop itself is
exercised; subsequent polls return $FINAL_STATUS (default "passed").
"""

import base64
import hashlib
import json
import os
import re
import socketserver
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, HTTPServer

RECORD_FILE = os.environ.get("RECORD_FILE", "/dev/null")
FINAL_STATUS = os.environ.get("FINAL_STATUS", "passed")
BUILD_ID = "00000000-0000-4000-8000-000000000001"
# Optional: a JSON file containing an array of pages (each an array of GitHub
# release objects). Enables GET /repos/<owner>/<repo>/releases with paging.
RELEASES_FILE = os.environ.get("RELEASES_FILE")
# Optional: append each releases request's Authorization header (or an empty
# line when absent) to this file, so tests can assert how the token was sent.
AUTH_LOG = os.environ.get("AUTH_LOG")


class Handler(BaseHTTPRequestHandler):
    poll_count = 0

    def log_message(self, *args):
        pass

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length)

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if re.fullmatch(r"/v1/ci/projects/[^/]+/[^/]+/builds", self.path):
            self._read_body()
            self._json(201, {"id": BUILD_ID, "number": 7, "status": "pending"})
        elif self.path == f"/v1/ci/builds/{BUILD_ID}/screenshots":
            body = self._read_body()
            # Re-wrap the multipart body so the email parser can walk it;
            # the cgi module is gone in Python 3.13.
            content_type = self.headers["Content-Type"].encode()
            msg = BytesParser(policy=policy.default).parsebytes(
                b"Content-Type: " + content_type + b"\r\n\r\n" + body
            )
            record = {}
            for part in msg.iter_parts():
                field = part.get_param("name", header="content-disposition")
                payload = part.get_payload(decode=True) or b""
                if field == "name":
                    record["name_b64"] = base64.b64encode(payload).decode()
                elif field == "file":
                    record["sha256"] = hashlib.sha256(payload).hexdigest()
                    record["size"] = len(payload)
            with open(RECORD_FILE, "a") as f:
                f.write(json.dumps(record) + "\n")
            self._json(200, {})
        elif self.path == f"/v1/ci/builds/{BUILD_ID}/finalize":
            self._read_body()
            self._json(200, {"status": "processing"})
        else:
            self._json(404, {"error": f"unexpected POST {self.path}"})

    def do_GET(self):
        from urllib.parse import parse_qs, urlparse

        parsed = urlparse(self.path)
        if RELEASES_FILE and re.fullmatch(
            r"/repos/[^/]+/[^/]+/releases", parsed.path
        ):
            if AUTH_LOG:
                with open(AUTH_LOG, "a") as f:
                    f.write((self.headers.get("Authorization") or "") + "\n")
            with open(RELEASES_FILE) as f:
                pages = json.load(f)
            page = int(parse_qs(parsed.query).get("page", ["1"])[0])
            body = pages[page - 1] if 1 <= page <= len(pages) else []
            self._json(200, body)
            return
        if self.path == f"/v1/ci/builds/{BUILD_ID}":
            Handler.poll_count += 1
            status = FINAL_STATUS if Handler.poll_count >= 2 else "processing"
            self._json(200, {"status": status})
        else:
            self._json(404, {"error": f"unexpected GET {self.path}"})


class QuietHTTPServer(HTTPServer):
    def server_bind(self):
        # Skip HTTPServer.server_bind: its socket.getfqdn() call can block for
        # tens of seconds on macOS runners (reverse-DNS timeout), delaying the
        # port announcement past the test's startup deadline. server_name is
        # never used by these tests.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


def main():
    server = QuietHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
