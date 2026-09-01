# Pseudo-header memory layout (exactly as in net_tx_buf+26..33)
pseudo_mem = bytes.fromhex("0A00020F0A00020200060014")
tcp_hdr = bytes.fromhex("C3501F9000000001000000005002FFFF00000000")

def le_sum(b): return sum((b[i+1]<<8)|b[i] for i in range(0,len(b),2))
def be_sum(b): return sum((b[i]<<8)|b[i+1] for i in range(0,len(b),2))

# Kernel (LE summation): reads pseudo_mem via lodsw
le_pseudo = le_sum(pseudo_mem)
le_tcp = le_sum(tcp_hdr)
le_total = le_pseudo + le_tcp
while le_total >> 16: le_total = (le_total & 0xFFFF) + (le_total >> 16)
le_cksum = le_total ^ 0xFFFF
print(f"LE cksum = 0x{le_cksum:04X}, wire bytes = {le_cksum & 0xFF:02X} {(le_cksum>>8)&0xFF:02X}")
print(f"Wire BE reading = 0x{((le_cksum & 0xFF)<<8)|((le_cksum>>8)&0xFF):04X}")

# Verifier (BE summation)
be_pseudo = be_sum(pseudo_mem)
be_tcp = be_sum(tcp_hdr)
be_total = be_pseudo + be_tcp
while be_total >> 16: be_total = (be_total & 0xFFFF) + (be_total >> 16)
be_cksum = be_total ^ 0xFFFF
print(f"\nBE cksum = 0x{be_cksum:04X}")

# Original observed wire: B4 F0 = 0xB4F0 BE reading
# That means tcp_cksum result was ax = 0xF0B4
# Verify:
print(f"\nOriginal wire BE cksum = 0xB4F0")
print(f"0xB4F0 BE cksum corresponds to LE cksum = 0x{0xB4F0 ^ 0xFFFF ^ 0xFFFF ^ 0xFFFF & 0xFFFF:04X}")

# Correct TCP checksum: compute manually
# Pseudo-header in BE: 0A00 020F 0A00 0202 0006 0014
# IP addrs in pseudo-header should be the WIRE bytes
# Wire src IP = 0A 00 02 0F → BE words 0A00, 020F
# Wire dst IP = 0A 00 02 02 → BE words 0A00, 0202
be_pseudo2 = 0x0A00+0x020F+0x0A00+0x0202+0x0006+0x0014
print(f"\nManual BE pseudo: 0x{be_pseudo2:04X}")
be_total2 = be_pseudo2 + be_tcp
while be_total2 >> 16: be_total2 = (be_total2 & 0xFFFF) + (be_total2 >> 16)
be_cksum2 = be_total2 ^ 0xFFFF
print(f"BE cksum (manual) = 0x{be_cksum2:04X}")

# verify_cksum.py said 0xB4F0. Let me replicate exactly:
syn_pseudo = bytes.fromhex("0A00020F0A00020200060014")
syn_tcp = bytes.fromhex("C3501F9000000001000000005002FFFF00000000")
s = be_sum(syn_pseudo) + be_sum(syn_tcp)
while s >> 16: s = (s & 0xFFFF) + (s >> 16)
print(f"\nverify_cksum style: BE cksum = 0x{s ^ 0xFFFF:04X}")
