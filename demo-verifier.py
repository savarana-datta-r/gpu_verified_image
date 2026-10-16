#!/usr/bin/env python3
"""Minimal verifier for the gpu-verified-image login gate.

Run it on the GPU machine itself. The gate calls it over loopback, and the
code is printed here instead of emailed, so the whole round trip is visible
on one screen.

    python3 verifier.py            # listens on 127.0.0.1:8080

Then point the gate at it:

    GPU_VERIFY_URL=http://127.0.0.1:8080/verify
    GPU_RUN_TOKEN=demo

Demo only. No persistence, no key ownership, no rate limiting.
"""
import json
import random
import sys
from datetime import datetime, timedelta
from http.server import BaseHTTPRequestHandler, HTTPServer

TTL = timedelta(minutes=5)
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

# fingerprint -> (code, issued_at)
ISSUED = {}


def now():
    return datetime.now()


def stamp():
    return now().strftime("%H:%M:%S")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # the prints below are the log

    def _send(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return self._send(401, {"error": "missing bearer token"})

        try:
            raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            body = json.loads(raw or b"{}")
        except Exception:
            return self._send(400, {"error": "bad json"})

        step = body.get("step")
        fp = body.get("fingerprint") or "(no fingerprint)"
        who = body.get("osUser", "?")
        ip = body.get("sourceIp", "?")

        if step == "request":
            prev = ISSUED.get(fp)
            if prev and now() - prev[1] < TTL:
                code = prev[0]
                print(f"\n[{stamp()}] login attempt  user={who}  from={ip}")
                print(f"           key {fp}")
                print(f"           code still valid:  >>>  {code}  <<<\n", flush=True)
                # 429 tells the gate a code is already out: prompt, do not resend.
                return self._send(429, {"error": "code already issued"})

            code = f"{random.randint(0, 999999):06d}"
            ISSUED[fp] = (code, now())
            print(f"\n[{stamp()}] login attempt  user={who}  from={ip}")
            print(f"           key {fp}")
            print(f"           CODE:  >>>  {code}  <<<   (valid 5 minutes)\n", flush=True)
            return self._send(202, {"sent": True})

        if step == "verify":
            got = "".join(ch for ch in str(body.get("code", "")) if ch.isdigit())
            rec = ISSUED.get(fp)
            ok = bool(rec and rec[0] == got and now() - rec[1] < TTL)
            print(f"[{stamp()}] code entered: {got or '(empty)'}  ->  "
                  f"{'VERIFIED' if ok else 'REJECTED'}", flush=True)
            if ok:
                ISSUED.pop(fp, None)   # one use per code
            return self._send(200 if ok else 401, {"verified": ok})

        return self._send(400, {"error": "unknown step"})


if __name__ == "__main__":
    print(f"verifier listening on 127.0.0.1:{PORT}")
    print(f"  point the gate at  http://127.0.0.1:{PORT}/verify")
    print("  codes appear below as logins are attempted. Ctrl-C to stop.\n", flush=True)
    try:
        HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
