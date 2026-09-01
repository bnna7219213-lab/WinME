#!/usr/bin/env python3
"""
gdb_inject.py — GDB-assisted HTTP response injection for real network download test.

QEMU 11.0.50 has a bug where E1000 TCTL (TX Control) MMIO writes are silently
dropped, making the guest unable to transmit packets. This script works around
the issue by:

  1. Fetching a REAL HTTP response from the Python HTTP server (serve_a4.py)
  2. Injecting it into the guest's http_buf via the QEMU GDB server
  3. Setting tcp_state=2 (ESTABLISHED) and tcp_rx_state=1 (data ready)
  4. The kernel's REAL http_parse() and WEX VM then process the data

This exercises the full download→parse→execute pipeline with a real HTTP
response; only the TX/RX packet transport is bypassed (due to the QEMU bug).
"""
import socket
import struct
import sys
import time

# --- Guest variable addresses (from kernel32.bin, ORG 0x100000) ---
TCP_STATE     = 0x00105B59  # byte: 0=closed, 1=SYN_SENT, 2=ESTABLISHED
TCP_RX_STATE  = 0x00105BA8  # byte: 0=idle, 1=data received
TCP_RX_LEN    = 0x00105BA9  # word: received payload length
HTTP_BUF      = 0x00105F12  # 256-byte buffer for HTTP request/response
NET_DL_STATE  = 0x00106055  # byte: download state machine state
DL_VALID      = 0x0010517F  # byte: 1 = dl_code holds valid downloaded bytecode

GDB_HOST = '127.0.0.1'
GDB_PORT = 1234
HTTP_HOST = '127.0.0.1'
HTTP_PORT = 8080
HTTP_PATH = '/a4.exe'


class GdbClient:
    """Minimal GDB remote serial protocol client."""

    def __init__(self, host, port):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.settimeout(5.0)
        self.sock.connect((host, port))
        # Consume any initial data (QEMU may send a stop reply on connect)
        self._drain()
        # Ensure CPU is running
        self.continue_exec()
        time.sleep(0.1)

    def _drain(self):
        """Drain any pending data from the socket."""
        self.sock.settimeout(0.3)
        try:
            while True:
                data = self.sock.recv(4096)
                if not data:
                    break
        except socket.timeout:
            pass
        finally:
            self.sock.settimeout(5.0)

    def _checksum(self, payload):
        return '%02x' % (sum(payload.encode('ascii')) % 256)

    def _send_packet(self, payload):
        msg = '$' + payload + '#' + self._checksum(payload)
        for attempt in range(3):
            self.sock.sendall(msg.encode('ascii'))
            # Wait for ack
            try:
                ack = self.sock.recv(1)
                if ack == b'+':
                    return True
            except socket.timeout:
                pass
        return False

    def _recv_packet(self):
        """Receive a $...#cc packet. Returns the payload string."""
        buf = b''
        # Wait for '$'
        while True:
            b = self.sock.recv(1)
            if not b:
                raise ConnectionError("Connection closed")
            if b == b'$':
                break
            # Ignore '+' and other chars
        # Read until '#'
        while True:
            b = self.sock.recv(1)
            if not b:
                raise ConnectionError("Connection closed")
            if b == b'#':
                break
            buf += b
        # Read 2-byte checksum
        self.sock.recv(2)
        # Send ack
        self.sock.sendall(b'+')
        return buf.decode('ascii')

    def read_mem(self, addr, length):
        """Read memory: returns bytes."""
        payload = 'm%08x,%x' % (addr, length)
        self._send_packet(payload)
        hex_str = self._recv_packet()
        if hex_str.startswith('E'):
            raise RuntimeError(f'GDB read error at 0x{addr:08x}: {hex_str}')
        return bytes.fromhex(hex_str)

    def write_mem(self, addr, data):
        """Write memory: data is bytes."""
        hex_data = data.hex()
        payload = 'M%08x,%x:%s' % (addr, len(data), hex_data)
        self._send_packet(payload)
        resp = self._recv_packet()
        return resp == 'OK'

    def continue_exec(self):
        """Continue CPU execution."""
        self._send_packet('vCont;c')
        # Don't wait for response — CPU is running

    def interrupt(self):
        """Interrupt CPU (send Ctrl-C / break)."""
        self.sock.sendall(b'\x03')
        # Server sends a stop reply
        try:
            self._recv_packet()
        except:
            pass

    def close(self):
        self.sock.close()


def main():
    print('[gdb_inject] Connecting to QEMU GDB server at %s:%d...' % (GDB_HOST, GDB_PORT))
    gdb = GdbClient(GDB_HOST, GDB_PORT)
    print('[gdb_inject] Connected.')

    # Step 1: Wait for kernel to reach net_dl_state == 3 (TCP phase)
    print('[gdb_inject] Waiting for net_dl_state == 3 (TCP phase)...')
    found = False
    for i in range(120):  # up to 36 seconds
        time.sleep(0.3)
        gdb.interrupt()
        try:
            state_bytes = gdb.read_mem(NET_DL_STATE, 1)
            state = state_bytes[0]
            if i % 10 == 0:
                print('[gdb_inject]   net_dl_state = %d' % state)
            if state == 3:
                print('[gdb_inject]   net_dl_state = 3 (TCP phase reached)')
                found = True
                break
            if state >= 4:
                print('[gdb_inject]   net_dl_state = %d (already past TCP)' % state)
                found = True
                break
        except Exception as e:
            print('[gdb_inject]   read error: %s' % e)
        gdb.continue_exec()

    if not found:
        print('[gdb_inject] FAIL: kernel never reached TCP phase')
        gdb.close()
        sys.exit(1)

    # Step 1b: If at state 3, set tcp_state=2 to trigger the 3→4 transition.
    # The kernel will build an HTTP GET request into http_buf and try to send it
    # (TX fails, but that's OK). We must wait for state 4 BEFORE writing our
    # response, otherwise the kernel overwrites our data with the GET request.
    if state == 3:
        print('[gdb_inject] Setting tcp_state=2 to trigger TCP→HTTP transition...')
        gdb.write_mem(TCP_STATE, b'\x02')
        gdb.continue_exec()
        # Wait for state 4 (HTTP phase — GET request built and "sent")
        print('[gdb_inject] Waiting for net_dl_state == 4 (HTTP phase)...')
        for i in range(30):
            time.sleep(0.2)
            gdb.interrupt()
            s = gdb.read_mem(NET_DL_STATE, 1)
            if s[0] >= 4:
                print('[gdb_inject]   net_dl_state = %d (HTTP phase reached)' % s[0])
                break
            gdb.continue_exec()
        else:
            print('[gdb_inject] FAIL: kernel never reached HTTP phase')
            gdb.close()
            sys.exit(1)

    # Step 2: Fetch real HTTP response from the Python HTTP server
    # Use a raw socket to get the COMPLETE response (headers + \r\n\r\n + body)
    # because the kernel's http_parse needs to find \r\n\r\n to split headers.
    print('[gdb_inject] Fetching real HTTP response from %s:%d%s ...' % (HTTP_HOST, HTTP_PORT, HTTP_PATH))
    try:
        hsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        hsock.settimeout(5.0)
        hsock.connect((HTTP_HOST, HTTP_PORT))
        request = ('GET %s HTTP/1.0\r\nHost: %s:%d\r\n\r\n' % (HTTP_PATH, HTTP_HOST, HTTP_PORT)).encode()
        hsock.sendall(request)
        http_response = b''
        while True:
            data = hsock.recv(4096)
            if not data:
                break
            http_response += data
        hsock.close()
        print('[gdb_inject] Fetched %d bytes from HTTP server' % len(http_response))
        print('[gdb_inject] Response preview: %s' % repr(http_response[:120]))
    except Exception as e:
        print('[gdb_inject] FAIL: cannot fetch HTTP response: %s' % e)
        gdb.close()
        sys.exit(1)

    if len(http_response) > 250:
        print('[gdb_inject] WARN: response too long (%d), truncating to 250' % len(http_response))
        http_response = http_response[:250]

    # Step 3: Inject the HTTP response into the guest's http_buf
    # CPU is currently stopped (from the interrupt above)
    print('[gdb_inject] Writing HTTP response into http_buf (0x%08X)...' % HTTP_BUF)
    ok = gdb.write_mem(HTTP_BUF, http_response)
    if not ok:
        print('[gdb_inject] FAIL: write_mem http_buf failed')
        gdb.close()
        sys.exit(1)
    print('[gdb_inject] http_buf written (%d bytes)' % len(http_response))

    # Verify the write by reading back
    verify = gdb.read_mem(HTTP_BUF, len(http_response))
    if verify != http_response:
        print('[gdb_inject] WARN: read-back mismatch!')
        print('[gdb_inject]   expected: %s' % repr(http_response[:40]))
        print('[gdb_inject]   got:      %s' % repr(verify[:40]))
    else:
        print('[gdb_inject] Read-back verified OK')

    # Step 4: Set tcp_rx_len = response length
    rx_len = len(http_response)
    len_bytes = struct.pack('<H', rx_len)
    gdb.write_mem(TCP_RX_LEN, len_bytes)
    print('[gdb_inject] tcp_rx_len = %d' % rx_len)

    # Step 5: Set tcp_rx_state = 1 (data received)
    gdb.write_mem(TCP_RX_STATE, b'\x01')
    print('[gdb_inject] tcp_rx_state = 1')

    # Note: tcp_state was already set to 2 in step 1b to trigger the 3→4
    # transition. The kernel is now at state 4, polling tcp_rx_state.
    # Setting tcp_rx_state=1 here will cause it to process our injected data.

    # Step 6: Continue CPU — kernel will process the HTTP response
    gdb.continue_exec()
    print('[gdb_inject] CPU resumed. Waiting for dl_valid == 1...')

    # Step 8: Wait for dl_valid == 1 (download complete)
    for i in range(60):  # up to 18 seconds
        time.sleep(0.3)
        gdb.interrupt()
        try:
            valid_bytes = gdb.read_mem(DL_VALID, 1)
            valid = valid_bytes[0]
            if i % 10 == 0:
                print('[gdb_inject]   dl_valid = %d' % valid)
            if valid == 1:
                print('[gdb_inject] SUCCESS: dl_valid = 1 — downloaded bytecode accepted!')
                break
        except Exception as e:
            print('[gdb_inject]   read error: %s' % e)
        gdb.continue_exec()
    else:
        print('[gdb_inject] WARN: dl_valid did not reach 1')
        # Debug: read back key variables to diagnose the failure
        print('[gdb_inject] --- Diagnostic dump ---')
        try:
            # Read net_dl_state
            nds = gdb.read_mem(NET_DL_STATE, 1)
            print('[gdb_inject]   net_dl_state = %d' % nds[0])
            # Read http_body (dword pointer)
            hb = gdb.read_mem(0x106014, 4)
            hb_val = struct.unpack('<I', hb)[0]
            print('[gdb_inject]   http_body = 0x%08X' % hb_val)
            # Read http_body_len (word)
            hbl = gdb.read_mem(0x106018, 2)
            hbl_val = struct.unpack('<H', hbl)[0]
            print('[gdb_inject]   http_body_len = %d' % hbl_val)
            # Read http_len (word)
            hl = gdb.read_mem(0x106012, 2)
            hl_val = struct.unpack('<H', hl)[0]
            print('[gdb_inject]   http_len = %d' % hl_val)
            # Read tcp_rx_state and tcp_rx_len
            trs = gdb.read_mem(TCP_RX_STATE, 1)
            trl = gdb.read_mem(TCP_RX_LEN, 2)
            print('[gdb_inject]   tcp_rx_state = %d' % trs[0])
            print('[gdb_inject]   tcp_rx_len = %d' % struct.unpack('<H', trl)[0])
            # Read first 40 bytes of http_buf
            buf = gdb.read_mem(HTTP_BUF, 40)
            print('[gdb_inject]   http_buf[0:40] = %s' % repr(buf))
            # If http_body is non-zero, read the first few bytes at that address
            if hb_val != 0:
                body = gdb.read_mem(hb_val, 20)
                print('[gdb_inject]   *http_body[0:20] = %s' % repr(body))
        except Exception as e:
            print('[gdb_inject]   diagnostic error: %s' % e)

    gdb.close()
    print('[gdb_inject] Done.')


if __name__ == '__main__':
    main()
