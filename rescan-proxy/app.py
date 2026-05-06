#!/usr/bin/env python3
"""Tiny proxy between Paperless workflows and paperless-ai-next.

Paperless workflow webhook URLs cannot be templated — only the body field
supports {{ doc_url }} substitution. paperless-ai-next's rescan endpoint
is POST /api/history/<id>/rescan, which needs the ID in the path.

This service bridges the gap: Workflow 2 POSTs {"doc_url": "..."} here,
we extract the ID and call the rescan endpoint. Purpose: clear the
processed_documents dedup cache whenever a user applies `ocr-pending`,
so re-OCR'd documents get re-classified from scratch.
"""

import json
import os
import re
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

AI_BASE = os.environ["PAPERLESS_AI_NEXT_BASE"]
API_KEY = os.environ["PAPERLESS_AI_NEXT_API_KEY"]
PORT = int(os.environ.get("PORT", "3100"))

DOC_ID_RE = re.compile(r"/documents/(\d+)/?")


def log(msg: str) -> None:
    print(msg, flush=True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log(f"{self.address_string()} - {fmt % args}")

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_error(404, "Not found")

    def do_POST(self):
        if self.path != "/rescan":
            self.send_error(404, "Not found")
            return

        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(raw or b"{}")
        except json.JSONDecodeError as e:
            self.send_error(400, f"Invalid JSON: {e}")
            return

        doc_url = payload.get("doc_url") or ""
        m = DOC_ID_RE.search(doc_url)
        if not m:
            self.send_error(400, f"No /documents/<id>/ in doc_url: {doc_url!r}")
            return
        doc_id = m.group(1)

        req = urllib.request.Request(
            f"{AI_BASE}/api/history/{doc_id}/rescan",
            method="POST",
            headers={"x-api-key": API_KEY, "Content-Type": "application/json"},
            data=b"{}",
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                body = resp.read()
                log(f"[rescan] doc {doc_id}: {resp.status}")
                self.send_response(resp.status)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)
        except urllib.error.HTTPError as e:
            err_body = e.read() if hasattr(e, "read") else b""
            log(f"[rescan] doc {doc_id}: HTTP {e.code} {e.reason} {err_body!r}")
            self.send_error(e.code, e.reason)
        except urllib.error.URLError as e:
            log(f"[rescan] doc {doc_id}: upstream error {e.reason}")
            self.send_error(502, f"Upstream error: {e.reason}")


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    log(f"[rescan-proxy] listening on 0.0.0.0:{PORT} → {AI_BASE}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("[rescan-proxy] shutting down")
