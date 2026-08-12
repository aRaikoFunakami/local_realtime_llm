#!/usr/bin/env python3
"""Stub session broker for VoiceInteractionAppSample.

Mimics backend/local_broker.py's contract (POST /api/realtime/session ->
{clientSecret, expiresAt, sessionConfigVersion}) but skips the call to
OpenAI: our realtime server (speech_to_speech) does no auth, so any
clientSecret value works. Local dev only — no auth on this endpoint either.
"""
import json
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8787
SESSION_CONFIG_VERSION = "local-mlx-1"
TTL = timedelta(hours=1)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/api/realtime/session":
            self.send_response(404)
            self.end_headers()
            return
        body = {
            "clientSecret": f"local-{uuid.uuid4().hex}",
            "expiresAt": (datetime.now(timezone.utc) + TTL).isoformat(),
            "sessionConfigVersion": SESSION_CONFIG_VERSION,
        }
        payload = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        print(f"[broker] {self.address_string()} - {fmt % args}")


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
