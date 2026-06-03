#!/usr/bin/env python3
# ──────────────────────────────────────────────────────────────────────────────
# Local webhook receiver — for testing merchant webhook delivery.
#
# Quick:
#   python3 scripts/dev/webhook-receiver.py --log /tmp/webhooks.jsonl
#
# Important: BroPay rejects http://localhost as a webhook URL (SSRF guard).
# Pair this with a cloudflared quick-tunnel and register the public URL
# returned by:
#
#   npx cloudflared tunnel --url http://localhost:9000
#
# Full workflow + signature-verification snippet: scripts/dev/README.md
#
# Stdlib only — no pip install. Each incoming request is pretty-printed
# to stdout, and --log appends a JSONL record of headers + body for
# replay / grep / jq.
# ──────────────────────────────────────────────────────────────────────────────

import argparse
import datetime as dt
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GREEN = "\033[0;32m"
CYAN = "\033[0;36m"
YELLOW = "\033[0;33m"
DIM = "\033[2m"
NC = "\033[0m"

# Headers worth surfacing (case-insensitive). Everything else is collapsed.
HEADERS_OF_INTEREST = {
    "x-bropay-signature",
    "x-bropay-timestamp",
    "x-bropay-event",
    "x-bropay-event-id",
    "x-bropay-delivery",
    "x-bropay-attempt",
    "user-agent",
    "content-type",
    "webhook-signature",
    "webhook-timestamp",
    "webhook-id",
}


class Handler(BaseHTTPRequestHandler):
    # Silence the default access log; we render our own pretty output.
    def log_message(self, *_a, **_k):
        return

    def _read_body(self):
        length = int(self.headers.get("content-length", "0") or 0)
        return self.rfile.read(length).decode("utf-8", errors="replace") if length else ""

    def _emit(self, method: str, path: str, body: str):
        ts = dt.datetime.now().isoformat(timespec="milliseconds")
        try:
            parsed = json.loads(body) if body else None
        except Exception:
            parsed = None

        evt = (parsed or {}).get("event_type") or (parsed or {}).get("event") or "?"
        print(f"\n{CYAN}━━ {ts}  {method} {path}  event={GREEN}{evt}{NC}")
        for k, v in self.headers.items():
            if k.lower() in HEADERS_OF_INTEREST:
                print(f"  {DIM}{k:24s}{NC} {v}")
        if parsed is not None:
            print(json.dumps(parsed, indent=2, ensure_ascii=False))
        else:
            print(body if body else "(empty body)")

        if self.server.log_file:
            with open(self.server.log_file, "a") as f:
                f.write(json.dumps({
                    "ts": ts,
                    "method": method,
                    "path": path,
                    "headers": dict(self.headers.items()),
                    "body": parsed if parsed is not None else body,
                }) + "\n")

    def _ok(self):
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"received":true}')

    def do_POST(self):
        body = self._read_body()
        self._emit("POST", self.path, body)
        self._ok()

    def do_PUT(self):
        body = self._read_body()
        self._emit("PUT", self.path, body)
        self._ok()

    def do_GET(self):
        self.send_response(200)
        self.send_header("content-type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(b"webhook-receiver: POST any payload here, it'll be logged.\n")


def main():
    ap = argparse.ArgumentParser(description="Local webhook receiver")
    ap.add_argument("--port", type=int, default=9000)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--log", default=None, help="optional JSONL append log path")
    args = ap.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.log_file = args.log

    print(f"{YELLOW}↪ webhook-receiver listening on http://{args.host}:{args.port}/{NC}")
    if args.log:
        print(f"{YELLOW}↪ logging JSONL to {args.log}{NC}")
    print(f"{DIM}Ctrl+C to stop. Register http://localhost:{args.port}/ as a webhook endpoint URL.{NC}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print(f"\n{YELLOW}stopped.{NC}")
        sys.exit(0)


if __name__ == "__main__":
    main()
