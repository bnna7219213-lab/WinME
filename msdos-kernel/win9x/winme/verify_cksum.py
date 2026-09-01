
def cksum(data):
    if len(data) % 2 == 1:
        data += b'\0'
    s = sum(int.from_bytes(data[i:i+2], 'big') for i in range(0, len(data), 2))
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return ~s & 0xffff

syn_hex = "4500002800004000400600000A00020F0A000202"
ip_header = bytes.fromhex(syn_hex)
print(f"IP Checksum (BE): {cksum(ip_header):04x}")

tcp_pseudo = bytes.fromhex("0A00020F0A00020200060014")
tcp_header = bytes.fromhex("C3501F9000000001000000005002FFFF00000000")
print(f"TCP Checksum (BE): {cksum(tcp_pseudo + tcp_header):04x}")
