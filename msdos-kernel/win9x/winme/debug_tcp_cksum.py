# Pseudo-header as the kernel sees it in memory
# src IP bytes in net_tx_buf+26: 0A 00 02 0F (BE wire format of 10.0.2.15)
# dst IP bytes in net_tx_buf+30: 0A 00 02 02 (BE wire format of 10.0.2.2)
src_ip = bytes.fromhex("0A00020F")
dst_ip = bytes.fromhex("0A000202")
proto_zero = bytes.fromhex("0006")  # proto=6, zero
tcp_len = bytes.fromhex("0014")  # 20 bytes in BE

# TCP header bytes on wire (with checksum zeroed)
tcp_hdr = bytes.fromhex("C3501F9000000001000000005002FFFF00000000")

# What tcp_cksum computes (LE summation on memory bytes)
def le_sum(b):
    return sum((b[i+1]<<8)|b[i] for i in range(0,len(b),2))

# Pseudo-header memory layout: src_ip + dst_ip + proto_zero + tcp_len
pseudo_mem = src_ip + dst_ip + proto_zero + tcp_len
print(f"Pseudo-header memory: {pseudo_mem.hex()}")

# TCP length is a register value (20), added directly
tcp_len_val = 20

pseudo_le_sum = le_sum(src_ip) + le_sum(dst_ip) + le_sum(proto_zero)
print(f"Pseudo LE sum (IP+proto): 0x{pseudo_le_sum:04X}")
pseudo_le_sum += tcp_len_val
print(f"  + TCP length 20: 0x{pseudo_le_sum:04X}")

tcp_le_sum = le_sum(tcp_hdr)
print(f"TCP header LE sum: 0x{tcp_le_sum:04X}")

total = pseudo_le_sum + tcp_le_sum
print(f"Total LE sum: 0x{total:04X}")
# Fold
while total >> 16:
    total = (total & 0xFFFF) + (total >> 16)
print(f"Folded: 0x{total:04X}")
cksum = total ^ 0xFFFF
print(f"LE cksum = 0x{cksum:04X}")
# Wire bytes (mov [mem], ax stores al then ah)
print(f"Wire bytes = {cksum & 0xFF:02X} {(cksum >> 8) & 0xFF:02X}")
print(f"Wire BE reading = 0x{(cksum >> 8) | ((cksum & 0xFF) << 8):04X}")

print()
# BE calculation (verifier)
def be_sum(b):
    return sum((b[i]<<8)|b[i+1] for i in range(0,len(b),2))

be_pseudo = be_sum(pseudo_mem) + 20  # TCP length as plain integer
print(f"BE pseudo-header sum: 0x{be_pseudo:04X}")
be_tcp = be_sum(tcp_hdr)
print(f"BE TCP header sum: 0x{be_tcp:04X}")
be_total = be_pseudo + be_tcp
while be_total >> 16:
    be_total = (be_total & 0xFFFF) + (be_total >> 16)
be_cksum = be_total ^ 0xFFFF
print(f"BE cksum = 0x{be_cksum:04X}")
print(f"Expected wire: {be_cksum >> 8:02X} {be_cksum & 0xFF:02X}")

print()
print(f"Match? LE wire = BE wire: {((cksum >> 8) | ((cksum & 0xFF) << 8)) == be_cksum}")
