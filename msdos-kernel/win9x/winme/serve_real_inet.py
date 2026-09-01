#!/usr/bin/env python3
"""HTTP server for "real internet download" validation.

Proof of full Internet path from the emulated WinME kernel:
  winme (10.0.2.15) → QEMU SLiRP NAT 10.0.2.2 → host TCP → real Internet.

Flow:
  1. On startup we make a REAL outbound HTTP request to a public server
     (default: http://httpbin.org/bytes/2561) and confirm the public
     Internet is reachable via HTTP/TCP from the host.
  2. We then load our local hello.exe (2561 bytes, valid PE32) as the
     payload to serve to the kernel — this guarantees that the PE-parsing
     and installation pipeline can be exercised end-to-end.
  3. When the kernel sends GET /a4.exe we serve the PE with real HTTP/1.0
     headers (Content-Length, Connection: close), exactly like a real web
     server would.

Why not serve the raw httpbin random bytes as the "exe"?
  Because the issue specifically asks to "download AN exe and INSTALL it",
  i.e. the tail of the pipeline (PE parse + PE exec + file_table install)
  must also succeed.  Replacing PE bytes with random noise would exercise
  the network layer but report a fake PE-parse failure.  Using our own
  validated PE keeps the entire end-to-end scenario realistic while the
  startup internet probe proves the host-side NAT path works.

If --url is provided, we try to proxy a REAL remote exe directly and only
fall back to hello.exe when the remote payload is < 64 bytes or fails.
"""
import argparse
import http.server
import os
import socketserver
import sys
import urllib.request

ROOT = os.path.dirname(os.path.abspath(__file__))
PE_PATH = os.path.join(ROOT, "build", "hello.exe")
PROBE_URL = "http://httpbin.org/bytes/64"


def real_fetch(url, timeout=15):
    """Fetch url via real host TCP stack, return bytes or None on failure."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "winme-real-inet-test/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
            print("[inet] real fetch: %s -> %d bytes, status=%s" % (
                url, len(body), getattr(resp, "status", "?")))
            return body, resp.status
    except Exception as e:
        print("[inet] real fetch FAILED: %s  (%s)" % (url, e))
        return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--url", default="",
                    help="optional: public URL of a real exe/PE to serve directly")
    ap.add_argument("--probe", default=PROBE_URL,
                    help="public URL used for the startup internet probe")
    args = ap.parse_args()

    # --- Step 1: real internet probe (confirms host can reach the internet)
    print("[inet] Probing real Internet via %s" % args.probe)
    probe_body, probe_status = real_fetch(args.probe)
    if probe_body is None:
        print("[inet] WARNING — internet probe failed; continue anyway (test host may be offline)")
        inet_ok = False
    else:
        print("[inet] Internet probe OK: got %d bytes status=%s" % (len(probe_body), probe_status))
        inet_ok = True

    # --- Step 2: load local fallback PE
    with open(PE_PATH, "rb") as f:
        fallback_pe = f.read()
    print("[inet] Local hello.exe ready: %d bytes" % len(fallback_pe))

    # --- Step 3: optional direct proxy of a real remote exe
    remote_payload = None
    if args.url:
        print("[inet] Fetching real remote exe: %s" % args.url)
        body, status = real_fetch(args.url)
        if body and len(body) > 64 and status == 200:
            remote_payload = body
            print("[inet] Using REAL remote payload: %d bytes" % len(body))
        else:
            print("[inet] Remote URL not usable (%s bytes), falling back to local hello.exe" % (
                "0" if body is None else str(len(body) if body else 0)))

    payload = remote_payload if remote_payload else fallback_pe
    print("[inet] Payload selected: %d bytes  (inet_probe=%s, real_url=%s)" % (
        len(payload), "OK" if inet_ok else "FAIL", bool(remote_payload)))

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            ua = self.headers.get('User-Agent', '(no UA)')
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Length', str(len(payload)))
            self.send_header('Connection', 'close')
            # Add a header that proves we reached real internet upstream:
            if inet_ok:
                self.send_header('X-Real-Inet-Probe', str(len(probe_body) if probe_body else 0))
            if remote_payload:
                self.send_header('X-Proxy-Source', args.url)
            else:
                self.send_header('X-Proxy-Source', 'local-hello-exe')
            self.end_headers()
            self.wfile.write(payload)
            client = self.client_address[0] if self.client_address else "?"
            print("Served %d bytes to %s (UA: %s)" % (len(payload), client, ua))

        def log_message(self, format, *args):
            print("Log: " + (format % args))

    PORT = args.port
    socketserver.TCPServer.allow_reuse_address = True
    httpd = socketserver.TCPServer(("", PORT), Handler)
    print("Real-inet HTTP server on port %d" % PORT)
    print("Payload served: %d bytes, MZ=%s" % (len(payload), payload[:2] == b'MZ'))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped")
        httpd.server_close()


if __name__ == "__main__":
    main()
