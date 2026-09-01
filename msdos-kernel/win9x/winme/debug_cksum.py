ip_hex = "4500002800004000400600000A00020F0A000202"
ip = bytes.fromhex(ip_hex)

# BE sum (verifier)
be = sum((ip[i]<<8)|ip[i+1] for i in range(0,len(ip),2))
be_sum = be
while be >> 16: be = (be & 0xFFFF) + (be >> 16)
print(f"BE sum = 0x{be_sum:04X}, cksum = 0x{be ^ 0xFFFF:04X}")

# LE sum (what kernel does without xchg)
le = sum((ip[i+1]<<8)|ip[i] for i in range(0,len(ip),2))
le_sum = le
while le >> 16: le = (le & 0xFFFF) + (le >> 16)
print(f"LE sum = 0x{le_sum:04X}, cksum = 0x{le ^ 0xFFFF:04X}")

# What kernel stores via mov [mem], ax: al then ah
# Wire bytes for BE cksum 0x22C0: stored LE = bytes C0 22
# Wire bytes for LE cksum: 0x(le^0xFFFF) stored LE
be_wire = (be ^ 0xFFFF)
print(f"BE wire bytes = {be_wire & 0xFF:02X} {(be_wire >> 8) & 0xFF:02X}")
le_wire = (le ^ 0xFFFF)
print(f"LE wire bytes = {le_wire & 0xFF:02X} {(le_wire >> 8) & 0xFF:02X}")

# Compare with observed wire: 22 C0
print(f"Observed wire: 22 C0 → ax = 0xC022")
print(f"BE ax = 0x{be_wire:04X}, LE ax = 0x{le_wire:04X}")
print(f"Match BE? {be_wire == 0x22C0}")
print(f"Match LE? {le_wire == 0xC022}")
print(f"Match xchg BE? {(be_wire & 0xFF)<<8 | (be_wire >> 8) == 0xC022}")
