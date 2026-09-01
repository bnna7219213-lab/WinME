import struct

def cksum(data):
    if len(data) % 2 == 1:
        data += b'\0'
    s = sum(struct.unpack('!%dH' % (len(data) // 2), data))
    s = (s >> 16) + (s & 0xffff)
    s += s >> 16
    return ~s & 0xffff

hex_dump = "52550A000202525400123456080045000028000040004006C0220A00020F0A000202C3501F9000000001000000005002FFFFF0B40000"
data = bytes.fromhex(hex_dump)

# IP header
ip_hdr = data[14:34]
print(f"IP Header Checksum: {cksum(ip_hdr):04x}")
# Note: cksum should return 0 if the header (including checksum) is valid
# But my cksum function calculates it for the data provided.
# To verify, we set the checksum field to 0.
ip_hdr_no_cksum = ip_hdr[:10] + b'\0\0' + ip_hdr[12:]
print(f"Calculated IP Checksum: {cksum(ip_hdr_no_cksum):04x}")

# TCP header
tcp_hdr = data[34:54]
src_ip = data[26:30]
dst_ip = data[30:34]
pseudo_hdr = src_ip + dst_ip + struct.pack('!HH', 6, len(tcp_hdr))
tcp_hdr_no_cksum = tcp_hdr[:16] + b'\0\0' + tcp_hdr[18:]
print(f"Calculated TCP Checksum: {cksum(pseudo_hdr + tcp_hdr_no_cksum):04x}")
