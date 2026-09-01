#!/usr/bin/env python3
"""HTTP server that serves a real PE32 EXE to the WinMe kernel."""
import http.server
import os
import socketserver

ROOT = os.path.dirname(os.path.abspath(__file__))
PE_PATH = os.path.join(ROOT, "build", "hello.exe")

with open(PE_PATH, "rb") as f:
    payload = f.read()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ua = self.headers.get('User-Agent', '(no UA)')
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(payload)
        client = self.client_address[0] if self.client_address else "?"
        print("Served %d bytes to %s (UA: %s)" % (len(payload), client, ua))
    def log_message(self, format, *args):
        print("Log: " + (format % args))

PORT = 8080
socketserver.TCPServer.allow_reuse_address = True
httpd = socketserver.TCPServer(("", PORT), Handler)
print("PE HTTP server on port %d" % PORT)
print("Serving %s (%d bytes)" % (PE_PATH, len(payload)))
try:
    httpd.serve_forever()
except KeyboardInterrupt:
    print("\nServer stopped")
    httpd.server_close()
