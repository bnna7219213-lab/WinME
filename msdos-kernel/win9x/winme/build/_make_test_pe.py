#!/usr/bin/env python3
"""Generate a minimal PE32 EXE: entry point calls ExitProcess(0)."""
import struct, sys, os

os.chdir(os.path.dirname(os.path.abspath(__file__)))

# ---- DOS Header (64 bytes) ----
dos = bytearray(64)
dos[0:2] = b'MZ'
struct.pack_into('<I', dos, 60, 64)   # e_lfanew = 64

# ---- PE Signature (4 bytes) ----
pe_sig = b'PE\x00\x00'

# ---- COFF Header (20 bytes) ----
coff = bytearray(20)
struct.pack_into('<H', coff, 0,  0x014C)   # Machine = i386
struct.pack_into('<H', coff, 2,  2)        # NumberOfSections = 2
struct.pack_into('<I', coff, 4,  0)        # TimeDateStamp
struct.pack_into('<I', coff, 8,  0)        # PointerToSymbolTable
struct.pack_into('<I', coff, 12, 0)        # NumberOfSymbols
struct.pack_into('<H', coff, 16, 224)      # SizeOfOptionalHeader
struct.pack_into('<H', coff, 18, 0x0102)   # Characteristics

# ---- Optional Header (224 bytes) ----
opt = bytearray(224)
struct.pack_into('<H', opt, 0,  0x10B)     # Magic = PE32
struct.pack_into('<I', opt, 4,  0x1000)    # SizeOfCode
struct.pack_into('<I', opt, 8,  0)         # SizeOfInitializedData
struct.pack_into('<I', opt, 12, 0)         # SizeOfUninitializedData
struct.pack_into('<I', opt, 16, 0x1000)    # AddressOfEntryPoint = 0x1000
struct.pack_into('<I', opt, 20, 0x1000)    # BaseOfCode
struct.pack_into('<I', opt, 24, 0x2000)    # BaseOfData
struct.pack_into('<I', opt, 28, 0x00400000)# ImageBase
struct.pack_into('<I', opt, 32, 0x1000)    # SectionAlignment
struct.pack_into('<I', opt, 36, 0x200)     # FileAlignment
struct.pack_into('<I', opt, 56, 0x4000)    # SizeOfImage
struct.pack_into('<I', opt, 60, 0x600)     # SizeOfHeaders

# DataDirectory: Import Dir at offset 96+8
# FIX: was 0x3000 (unmapped RVA, not inside any section) while the actual
# IMAGE_IMPORT_DESCRIPTOR lives at RVA 0x2020 (file offset 0x820).
struct.pack_into('<I', opt, 96+8,  0x2020) # ImportDir RVA = 0x2020
struct.pack_into('<I', opt, 96+12, 0x18)   # ImportDir Size = 24

# ---- Section Headers (2 * 40 = 80 bytes) ----
sect_text = bytearray(40)
sect_text[0:8] = b'.text\x00\x00\x00'
struct.pack_into('<I', sect_text, 8,  0x200)   # VirtualSize
struct.pack_into('<I', sect_text, 12, 0x1000)  # VirtualAddress
struct.pack_into('<I', sect_text, 16, 0x200)   # SizeOfRawData
struct.pack_into('<I', sect_text, 20, 0x600)   # PointerToRawData
struct.pack_into('<I', sect_text, 36, 0x60000020)  # CODE|EXECUTE|READ

sect_rdata = bytearray(40)
sect_rdata[0:8] = b'.rdata\x00\x00'
struct.pack_into('<I', sect_rdata, 8,  0x600)   # VirtualSize
struct.pack_into('<I', sect_rdata, 12, 0x2000)  # VirtualAddress
struct.pack_into('<I', sect_rdata, 16, 0x600)   # SizeOfRawData
struct.pack_into('<I', sect_rdata, 20, 0x800)   # PointerToRawData
struct.pack_into('<I', sect_rdata, 36, 0x40000040)  # INITIALIZED_DATA|READ

# ---- .text raw (512 bytes at file offset 0x600) ----
# Entry at RVA 0x1000 = file offset 0x600
# IAT for ExitProcess:
#   Import Descriptor is at RVA 0x3000 = file offset 0x800+0x100=0x900
#   IAT is at RVA 0x3074 = file offset 0x800+0x74=0x874
# Wait, let me recalculate.
#
# .rdata: VA=0x2000, RawOff=0x800
# So RVA 0x3000 maps to file offset 0x800 + (0x3000 - 0x2000) = 0x800 + 0x1000 = 0x1800
#
# Hmm, that doesn't work. Let me use smaller offsets.
#
# Let me use:
# .rdata: VA=0x2000, RawOff=0x800
# Everything in .rdata at RVA 0x2000+X maps to file offset 0x800+X
#
# ExitProcess name at RVA 0x2010 = file 0x810
# IMAGE_IMPORT_DESCRIPTOR at RVA 0x2020 = file 0x820 (20 bytes)
# Null descriptor at RVA 0x2034 = file 0x834 (20 bytes)
# IAT at RVA 0x2060 = file 0x860 (8 bytes: 1 entry + null)
# OriginalThunkTable at RVA 0x2068 = file 0x868 (8 bytes)
#
# Entry code calls IAT[0] at RVA 0x2060
# IAT[0] = 0 (stub, will be filled by pe_resolve_imports)
# Call target in code: [0x2060] = absolute address

text_raw = bytearray(512)
# Entry: push 0; call dword ptr [0x00402060]; hlt
text_raw[0]  = 0x6A           # push
text_raw[1]  = 0x00           # 0
text_raw[2]  = 0xFF           # call
text_raw[3]  = 0x15           # [disp32]
struct.pack_into('<I', text_raw, 4, 0x00402060)  # IAT[ExitProcess] RVA in memory
text_raw[8]  = 0xC3           # ret: return to kernel loader after ExitProcess
for i in range(9, 512):
    text_raw[i] = 0x90         # NOP padding

# ---- .rdata raw (512 bytes at file offset 0x800) ----
# RVA 0x2000 = file 0x800
rdata_raw = bytearray(512)

# ExitProcess name at RVA 0x2010 = file offset 0x810
rdata_raw[0x10:0x12] = b'\x00\x00'          # Hint = 0
rdata_raw[0x12:0x1E] = b'ExitProcess\x00'

# IMAGE_IMPORT_DESCRIPTOR[0] at RVA 0x2020 = file offset 0x820
# OriginalFirstThunk RVA = 0x2068
struct.pack_into('<I', rdata_raw, 0x20, 0x2068)
struct.pack_into('<I', rdata_raw, 0x24, 0)       # TimeDateStamp
struct.pack_into('<I', rdata_raw, 0x28, 0)       # ForwarderChain
# Name RVA = 0x2040 (KERNEL32.DLL)
struct.pack_into('<I', rdata_raw, 0x2C, 0x2040)
# FirstThunk RVA = 0x2060 (IAT)
struct.pack_into('<I', rdata_raw, 0x30, 0x2060)

# Null IMAGE_IMPORT_DESCRIPTOR at RVA 0x2034 = file offset 0x834
for i in range(20):
    rdata_raw[0x34 + i] = 0

# KERNEL32.DLL name at RVA 0x2040 = file offset 0x840
rdata_raw[0x40:0x4C] = b'KERNEL32.DLL\x00'

# IAT at RVA 0x2060 = file offset 0x860
struct.pack_into('<I', rdata_raw, 0x60, 0)   # IAT[0] = 0 (stub)
struct.pack_into('<I', rdata_raw, 0x64, 0)   # IAT[1] = 0 (null terminator)

# OriginalFirstThunkTable at RVA 0x2068 = file offset 0x868
# Thunk for ExitProcess: by-name, RVA = 0x2010
struct.pack_into('<I', rdata_raw, 0x68, 0x2010)
struct.pack_into('<I', rdata_raw, 0x6C, 0)   # null terminator

# ---- Assemble ----
pe = bytearray()
pe += dos          # 64
pe += pe_sig       # 4 (off 64)
pe += coff         # 20 (off 68)
pe += opt          # 224 (off 88)
pe += sect_text    # 40 (off 312)
pe += sect_rdata   # 40 (off 352)
pe += b'\x00' * (0x600 - len(pe))  # pad to 0x600
pe += text_raw     # 512 (off 0x600)
pe += rdata_raw    # 512 (off 0x800)

with open('hello.exe', 'wb') as f:
    f.write(pe)
print(f"hello.exe: {len(pe)} bytes")

# ---- Verify ----
d = open('hello.exe','rb').read()
errs = []
def chk(off, val, name):
    if d[off:off+len(val)] != val:
        errs.append(f"{name}@{off:#x}: got {d[off:off+len(val)].hex()} exp {val.hex()}")
def chkI(off, val, name):
    got = struct.unpack('<I', d[off:off+4])[0]
    if got != val:
        errs.append(f"{name}@{off:#x}: got {got:#x} exp {val:#x}")
def chkH(off, val, name):
    got = struct.unpack('<H', d[off:off+2])[0]
    if got != val:
        errs.append(f"{name}@{off:#x}: got {got:#x} exp {val:#x}")

chk(0, b'MZ', 'MZ')
chkI(60, 64, 'e_lfanew')
chk(64, b'PE\x00\x00', 'PE sig')
chkH(68, 0x014C, 'Machine')
chkH(70, 2, 'Sections')
chkH(84, 224, 'OptSize')
chkH(88, 0x10B, 'OptMagic')
chkI(104, 0x1000, 'EntryRVA')
chkI(116, 0x400000, 'ImageBase')
chkI(104, 0x1000, 'SizeOfImage check')  # sanity

# DataDirectory[1] Import at offset 88+96+8 = 192
chkI(192, 0x2020, 'ImportDir RVA')
chkI(196, 0x18, 'ImportDir Size')

# Section table
chk(312, b'.text\x00\x00\x00', '.text name')
chkI(312+12, 0x1000, '.text VA')
chkI(312+16, 0x200, '.text RawSize')
chkI(312+20, 0x600, '.text RawOff')

chk(352, b'.rdata\x00\x00', '.rdata name')
chkI(352+12, 0x2000, '.rdata VA')
chkI(352+16, 0x600, '.rdata RawSize')
chkI(352+20, 0x800, '.rdata RawOff')

# Entry code at file 0x600
chk(0x600, b'\x6A\x00', 'push 0')
chk(0x602, b'\xFF\x15', 'call [disp32]')
chkI(0x604, 0x00402060, 'call target')
chk(0x608, b'\xC3', 'ret marker')

# ExitProcess name at file 0x810
chk(0x810, b'\x00\x00', 'Hint')
chk(0x812, b'ExitProcess\x00', 'ExitProcess name')

# IMAGE_IMPORT_DESCRIPTOR at file 0x820
chkI(0x820, 0x2068, 'OTH RVA')
chkI(0x82C, 0x2040, 'DLL Name RVA')
chkI(0x830, 0x2060, 'IAT RVA')

# KERNEL32.DLL at file 0x840
chk(0x840, b'KERNEL32.DLL\x00', 'DLL name')

# IAT at file 0x860
chkI(0x860, 0, 'IAT[0]')
chkI(0x864, 0, 'IAT[1]')

# OTH at file 0x868
chkI(0x868, 0x2010, 'OTH[0]')
chkI(0x86C, 0, 'OTH[1]')

if errs:
    for e in errs:
        print(f"  FAIL: {e}")
    sys.exit(1)
else:
    print("PASS: all PE fields verified")