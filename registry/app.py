#!/usr/bin/env python3
"""Minimal Device Registry (stdlib HTTP, no Flask)."""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

DEVICES = json.load(open('/app/devices.json'))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path

        # Fault-injection knobs (designed in for the demo).
        if '?refuse=1' in path:
            self.send_response(503)
            self.end_headers()
            return
        if '?delay_ms=' in path:
            ms = int(path.split('?delay_ms=')[1].split('&')[0])
            time.sleep(ms / 1000.0)

        parts = path.split('?')[0].strip('/').split('/')
        if len(parts) >= 2 and parts[0] == 'devices':
            device_id = parts[1]
            if device_id in DEVICES:
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(DEVICES[device_id]).encode())
                return

        self.send_response(404)
        self.end_headers()


if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    server = HTTPServer(('0.0.0.0', port), Handler)
    print(f"registry listening on :{port}", flush=True)
    server.serve_forever()