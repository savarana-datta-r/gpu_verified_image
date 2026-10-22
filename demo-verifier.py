#!/usr/bin/env python3
"""Minimal verifier for the gpu-verified-image login gate.

Run it on the GPU machine itself. The gate calls it over loopback as each
interactive login opens, and the login is printed here, so the whole round
trip is visible on one screen.

    python3 demo-verifier.py       # listens on 127.0.0.1:8080

Then point the gate at it:

    GPU_VERIFY_URL=http://127.0.0.1:8080/verify
    GPU_RUN_TOKEN=demo

Demo only. It records nothing, checks nothing and admits every login: a real
verifier resolves the fingerprint to the person the key was installed for and
writes the session down. See "The verifier API" in README.md.
"""
import json
import sys
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080


def stamp():
    return datetime.now().strftime("%H:%M:%S")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # the prints below are the log

    def reply(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self.reply(400, {"error": "body must be JSON"})

        # The token names the machine. A real verifier looks it up; this one
        # only insists that the gate sent one, since a gate with no token is
        # misconfigured and that is worth seeing on screen.
        auth = self.headers.get("Authorization") or ""
        if not auth.startswith("Bearer "):
            print(f"[{stamp()}] refused: no run token")
            return self.reply(401, {"error": "missing run token"})

        fingerprint = body.get("fingerprint") or "(none)"
        os_user = body.get("osUser") or "(unknown)"
        source_ip = body.get("sourceIp") or "(unknown)"
        if not body.get("fingerprint"):
            # Without one there is nothing to attribute the login to. The gate
            # sends it for every interactive session, so its absence is a
            # fault rather than a login to wave through.
            print(f"[{stamp()}] refused: no fingerprint")
            return self.reply(400, {"error": "fingerprint is required"})

        print(f"[{stamp()}] login  user={os_user}  from={source_ip}  key={fingerprint}")
        # `verified: true` is what the gate looks for to open the session. A
        # `step` field may be present; this verifier answers the same way
        # whatever it says, which is what keeps a gate built against the older
        # two-call protocol from prompting for a code nobody issues.
        self.reply(200, {"verified": True})


if __name__ == "__main__":
    print(f"demo verifier on 127.0.0.1:{PORT}  (admits every login, records nothing)")
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
