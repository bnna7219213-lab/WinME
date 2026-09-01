#!/usr/bin/env python3
"""Serve the real PE32 EXE to a QEMU guestfwd-connected VM."""
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
PE_PATH = os.path.join(ROOT, "build", "hello.exe")
LOG_PATH = os.path.join(ROOT, "_serve_a4.log")

with open(PE_PATH, "rb") as f:
    payload = f.read()

# Read whatever the guest sends (HTTP request)
try:
    req = sys.stdin.buffer.read()
except Exception:
    req = b""

# Build HTTP response with explicit Content-Length
resp = (
    b"HTTP/1.0 200 OK\r\n"
    b"Content-Type: application/octet-stream\r\n"
    b"Content-Length: " + str(len(payload)).encode() + b"\r\n"
    b"Connection: close\r\n"
    b"\r\n" +
    payload
)

sys.stdout.buffer.write(resp)
sys.stdout.buffer.flush()

# Log for external verification
with open(LOG_PATH, "a") as log:
    log.write("Served %d bytes to guestfwd (req %d bytes)\n" % (len(payload), len(req)))
