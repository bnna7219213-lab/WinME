import socket, json, time, sys

host = '127.0.0.1'
port = 4555
out_png = r'C:\Users\bnna7\workspace\msdos-kernel\win9x\winme\_screenshot.png'

try:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect((host, port))
    def recv_line():
        data = b""
        while b"\n" not in data:
            chunk = s.recv(4096)
            if not chunk:
                return None
            data += chunk
        return data.decode().strip()

    greeting = json.loads(recv_line())
    print("Greeting:", greeting)

    s.sendall(b'{"execute": "qmp_capabilities"}\n')
    resp = json.loads(recv_line())
    print("Capabilities:", resp)

    cmd = json.dumps({"execute": "screendump", "arguments": {"path": out_png}}) + "\n"
    s.sendall(cmd.encode())
    time.sleep(1)
    resp = json.loads(recv_line())
    print("Response:", resp)
    s.close()
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)