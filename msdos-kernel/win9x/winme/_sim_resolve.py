#!/usr/bin/env python3
"""Simulate the kernel's pe_parse/pe_rva_to_fileoff/pe_resolve_imports against hello.exe."""
import struct, sys

d = open(r"c:\Users\bnna7\workspace\msdos-kernel\win9x\winme\build\hello.exe", "rb").read()
print(f"file len = {len(d)} (0x{len(d):X})")

# --- pe_parse ---
assert d[0:2] == b'MZ'
e_lfanew = struct.unpack_from('<I', d, 0x3C)[0]
print(f"e_lfanew = {e_lfanew:#x}")
assert d[e_lfanew:e_lfanew+4] == b'PE\x00\x00'
coff = e_lfanew + 4
nsec = struct.unpack_from('<H', d, coff+2)[0]
optsize = struct.unpack_from('<H', d, coff+16)[0]
opt = coff + 20
entry = struct.unpack_from('<I', d, opt+16)[0]
imagebase = struct.unpack_from('<I', d, opt+28)[0]
datadir_off = coff + 116
sectable_off = coff + 20 + optsize
print(f"nsec={nsec} optsize={optsize} entry={entry:#x} imagebase={imagebase:#x}")
print(f"datadir_off={datadir_off:#x} sectable_off={sectable_off:#x}")

imp_rva, imp_size = struct.unpack_from('<II', d, datadir_off+8)
print(f"DataDirectory[1] Import: RVA={imp_rva:#x} size={imp_size:#x}")

sections = []
for i in range(nsec):
    s = sectable_off + i*40
    name = d[s:s+8].rstrip(b'\0').decode()
    vsize, va, rawsize, rawoff = struct.unpack_from('<IIII', d, s+8)
    sections.append((name, va, vsize, rawoff, rawsize))
    print(f"  section {name}: VA={va:#x} VSize={vsize:#x} RawOff={rawoff:#x} RawSize={rawsize:#x}")

def rva_to_fileoff(rva):
    for name, va, vsize, rawoff, rawsize in sections:
        if va <= rva < va + vsize:
            return rawoff + (rva - va)
    return 0xFFFFFFFF

# --- pe_resolve_imports ---
fo = rva_to_fileoff(imp_rva)
print(f"import dir fileoff = {fo:#x}" if fo != 0xFFFFFFFF else "import dir MAP FAIL")
if fo == 0xFFFFFFFF:
    sys.exit(1)

desc = fo
while True:
    oft, ts, fc, name_rva, ft = struct.unpack_from('<IIIII', d, desc)
    if oft == 0 and ts == 0 and fc == 0 and name_rva == 0 and ft == 0:
        print("descriptor terminator")
        break
    print(f"desc@{desc:#x}: OFT={oft:#x} Name={name_rva:#x} FT={ft:#x}")
    src = oft if oft else ft
    tfo = rva_to_fileoff(src)
    if tfo == 0xFFFFFFFF:
        print(f"  thunk table RVA {src:#x} MAP FAIL -> .rim_fail"); sys.exit(1)
    idx = 0
    while True:
        thunk = struct.unpack_from('<I', d, tfo + idx*4)[0]
        if thunk == 0:
            print(f"  thunk[{idx}] = NULL -> next import")
            break
        if thunk & 0x80000000:
            print(f"  thunk[{idx}] = ordinal {thunk:#x} (skip)")
        else:
            nfo = rva_to_fileoff(thunk)
            if nfo == 0xFFFFFFFF:
                print(f"  thunk[{idx}] RVA {thunk:#x} MAP FAIL (skip)")
            else:
                fname = d[nfo+2:nfo+2+20].split(b'\0')[0].decode(errors='replace')
                print(f"  thunk[{idx}] RVA={thunk:#x} fileoff={nfo:#x} name='{fname}'")
                # simulate dispatch: name[16]+dd, C-string compare
                stub_ok = fname == "ExitProcess"
                print(f"    dispatch match ExitProcess: {stub_ok}")
        idx += 1
    desc += 20

# stub table layout check (name[16]+handler[4])
names = ["ExitProcess", "GetModuleHandleA", "GetModuleHandleW", "GetProcAddress",
         "GetTickCount", "GetStdHandle", "WriteFile", "ReadFile", "printf"]
print("\nstub table entry sizes (should be <=16 name bytes + 4):")
for n in names:
    ln = len(n)
    flag = "OK " if ln <= 15 else "BAD(>=16 chars, needs 17 bytes before dd -> misaligned)"
    print(f"  '{n}' len={ln} {flag}")
