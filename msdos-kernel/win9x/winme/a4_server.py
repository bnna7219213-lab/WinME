#!/usr/bin/env python3
"""HTTP server that serves a 0xA4-header bytecode EXE to the WinMe kernel."""
import http.server
import socketserver
import sys

# Bytecode program (WinMe VM opcodes):
#   0xA4  = BC_MAGIC (identifies as downloadable EXE)
#   0x03  = PRINT cstring
#   "Hello from A4-EXE!" + 0x00 = string to print
#   0x00  = HALT
payload = bytes([
    0xA4,                          # BC_MAGIC
    0x03,                          # PRINT opcode
    0x48, 0x65, 0x6C, 0x6C, 0x6F, # "Hello"
    0x20, 0x66, 0x72, 0x6F, 0x6D, # " from"
    0x20, 0x41, 0x34, 0x2D, 0x45, # " A4-E"
    0x58, 0x45, 0x21,              # "XE!"
    0x00,                          # null terminator
    0x00,                          # HALT
])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(payload)
        print("Served A4-EXE payload (%d bytes)" % len(payload))
    def log_message(self, format, *args):
        pass

PORT = 8080
socketserver.TCPServer.allow_reuse_address = True
httpd = socketserver.TCPServer(("", PORT), Handler)
print("A4-EXE HTTP server on port %d" % PORT)
print("Payload: %s" % payload.hex())
try:
    httpd.serve_forever()
except KeyboardInterrupt:
    print("\nServer stopped")
    httpd.server_close()