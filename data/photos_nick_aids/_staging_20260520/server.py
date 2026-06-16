#!/usr/bin/env python3
"""Serve the contact sheet and persist its state to disk live.

The page POSTs its full state (assignments + current selection + deletes) to
/state on every change. We write it to state.json so Claude can read the live
selection at any moment and act on it (no manual export/download step).
"""
import json
import os
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HERE, "state.json")
PORT = 8765


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=HERE, **kw)

    def log_message(self, *a):
        pass  # quiet

    def do_POST(self):
        if self.path != "/state":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            data = json.loads(body)
        except Exception as e:
            self.send_error(400, str(e))
            return
        with open(STATE, "w") as f:
            json.dump(data, f, indent=2)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')


if __name__ == "__main__":
    print(f"serving {HERE} on http://localhost:{PORT}")
    print(f"state -> {STATE}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
