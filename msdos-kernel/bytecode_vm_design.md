# Bytecode VM Design — M-B4 Kernel (32-bit Flat Memory)

## 1. Architecture Overview

A minimal stack-based bytecode VM designed to execute simple scripts
embedded inside EXE files on the M-B4 32-bit kernel (ORG 0x100000).

**Constraints met:**
- VM code size: ~1.5 KB assembled (well under 2 KB budget)
- 18 instructions, 1-byte opcode + optional 1/2/4-byte operand
- Stack machine using kernel ESP for push/pop
- Direct jump table dispatch for speed

---

## 2. Bytecode File Format

Embedded in EXE as a named section, or as a standalone `.vm` file.

```
┌──────────┬───────┬──────────────────────────────────────────────────┐
│  OFFSET  │  SIZE │  FIELD                                           │
├──────────┼───────┼──────────────────────────────────────────────────┤
│   0      │  2 B  │  Magic: "VM" (0x564D, little-endian)            │
│   2      │  2 B  │  Version: 0x0001                                │
│   4      │  4 B  │  Code length (bytes)                            │
│   8      │  4 B  │  Code load address (0x00010400 default)         │
│  12      │  4 B  │  Data segment length (bytes)                    │
│  16      │  4 B  │  Stack size hint                                │
│  20      │  N B  │  CODE bytes                                     │
│  20+N    │  M B  │  DATA segment                                   │
└──────────┴───────┴──────────────────────────────────────────────────┘

Header = 20 bytes. Total = 20 + code_len + data_len.
```

---

## 3. Instruction Set Encoding (18 instructions)

```
┌──────────┬──────────┬───────────┬──────────────────────────────────────┐
│  OPCODE  │  NAME    │  OPERAND  │  OPERATION                           │
├──────────┼──────────┼───────────┼──────────────────────────────────────┤
│  0x00    │  HALT    │   —       │  Stop VM, restore ESP, return        │
│  0x01    │  NOP     │   —       │  No-op                              │
│  0x02    │  PUSH_1  │  uint8    │  Push 8-bit immediate               │
│  0x03    │  PUSH_2  │  uint16   │  Push 16-bit immediate              │
│  0x04    │  PUSH_4  │  int32    │  Push 32-bit immediate              │
│  0x05    │  LOAD_M  │  addr32   │  Push [addr]                        │
│  0x06    │  STORE_M │  addr32   │  [addr] = pop()                     │
│  0x07    │  ADD     │   —       │  Pop a,b; push b+a                  │
│  0x08    │  SUB     │   —       │  Pop a,b; push b-a                  │
│  0x09    │  MUL     │   —       │  Pop a,b; push b*a                  │
│  0x0A    │  DIV     │   —       │  Pop a,b; push b/a                  │
│  0x0B    │  CMP     │   —       │  Pop a,b; set flags (b-a)           │
│  0x0C    │  JEQ     │  off32    │  JMP off if ZF=1                    │
│  0x0D    │  JNE     │  off32    │  JMP off if ZF=0                    │
│  0x0E    │  JMP     │  off32    │  PC = off                           │
│  0x0F    │  CALL    │  off32    │  Push return addr, PC = off         │
│  0x10    │  RET     │   —       │  PC = pop()                         │
│  0x11    │  PRINT_S │  addr32   │  Print null-terminated string       │
│  0x12    │  PRINT_N │   —       │  Pop value, print as decimal        │
└──────────┴──────────┴───────────┴──────────────────────────────────────┘
```

**Operand encoding:** All multi-byte operands are little-endian.

**Branch targets (JMP/JEQ/JNE/CALL):** Absolute byte offsets into the
code segment (not relative offsets). This simplifies the VM implementation
at the cost of larger branch targets (4 bytes each).

**Register file (4 slots):** R0-R3 at vm_regs[] (16 bytes).
- PUSH_REG Rn → `04 reg_addr 00 00 00` (PUSH_4 of the register address)
- POP_REG Rn → `05 reg_addr 00 00 00` (LOAD_M from register address)
- STOR_REG Rn → `06 reg_addr 00 00 00` (STORE_M to register address)

---

## 4. VM State Layout

Placed in kernel data area at 0x010C00 (32 bytes):

```
vm_state:
  vm_pc         dd  ?      ; byte offset into code segment
  vm_esp_base   dd  ?      ; ESP value when VM entered (for stack cleanup)
  vm_code_base  dd  ?      ; pointer to code in memory (default 0x010400)
  vm_data_base  dd  ?      ; pointer to data in memory
  vm_stack_top  dd  ?      ; ESP limit for stack protection
  vm_regs       dd  4 dup(0)   ; R0, R1, R2, R3 (16 bytes)

Total: 32 bytes
```

**Memory layout in kernel:**
```
  0x010400 - 0x010800   VM code segment  (1 KB max)
  0x010800 - 0x010C00   VM data segment  (1 KB max)
  0x010C00 - 0x010C20   VM state         (32 bytes)
  0x010C20 - 0x011420   VM jump table    (1024 bytes, 256 entries * 4)
```

---

## 5. Execution Loop Design

```
vm_run:
    ; Load header, copy code+data, init state
    ; Then enter dispatch loop:

  .dispatch:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    movzx   eax, byte [ebx]        ; fetch opcode
    inc     dword [vm_pc]          ; advance past opcode byte

    ; Direct jump table dispatch
    jmp     dword [vm_jumptable + eax*4]

  ; Each instruction handler ends with:
  ;   jmp .dispatch
  ; This gives O(1) dispatch regardless of opcode distribution.
```

**Jump table:** 256 entries × 4 bytes = 1024 bytes.
All 238 unused entries (0x13–0xFF) point to `instr_halt` (graceful death).

**Alternative (smaller):** If-else chain saves 1024 bytes but adds ~50 bytes
of comparison code. Jump table preferred for speed and simplicity.

---

## 6. Sample Program: Hello World + 2+3

### Source-level pseudocode:
```
print("Hello\0")
push 2
push 3
add        ; stack: [5]
print_num  ; prints "5"
halt
```

### Bytecode (raw hex, CODE section only, 16 bytes):

```
Offset  Hex        Instruction                    Stack after
──────  ────────   ───────────────────────────    ───────────
00      04 14 04   PUSH_4 0x00010414             [0x010414]
05      01 00
06      11 14 04   PRINT_S 0x00010414            prints "Hello"
0B      01 00
0C      02 02      PUSH_1 2                      [2]
0E      02 03      PUSH_1 3                      [2, 3]
10      07         ADD                           [5]
11      12         PRINT_N                       prints "5", []
12      00         HALT                          (exit)
```

### DATA section (6 bytes at offset 0x010414):
```
48 65 6C 6C 6F 00    "Hello\0"
```

### Complete .vm file (26 bytes):

```
File offset  Hex bytes                Field
───────────  ─────────────────────    ─────────────────────
00           56 4D                    Magic "VM"
02           01 00                    Version 1
04           13 00 00 00              Code length = 19
08           00 04 01 00              Code base = 0x00010400
0C           06 00 00 00              Data length = 6
10           80 00 00 00              Stack hint = 128

; CODE (19 bytes, file offset 20):
14           04 14 04 01 00          PUSH_4 0x00010414
19           11 14 04 01 00          PRINT_S 0x00010414
1E           02 02                    PUSH_1 2
20           02 03                    PUSH_1 3
22           07                       ADD
23           12                       PRINT_N
24           00                       HALT

; DATA (6 bytes, file offset 25):
25           48 65 6C 6C 6F 00       "Hello\0"
```

### Execution trace:
```
PC=0: PUSH_4 0x00010414  → stack: [0x00010414]
PC=5: PRINT_S 0x00010414  → output: "Hello"  stack: []
PC=A: PUSH_1 2            → stack: [2]
PC=C: PUSH_1 3            → stack: [2, 3]
PC=E: ADD                 → stack: [5]
PC=F: PRINT_N             → output: "5"      stack: []
PC=10: HALT               → exit
```

---

## 7. Kernel Hook Point

The VM hooks into the existing kernel at this point in the boot flow:

```
init_page_tables → init_gdt → init_idt → remap_pit → init_sched → init_io
     → [vm_load_script] → load_processes → start_scheduling → busy_loop
```

**Integration code** (inserted after `init_io`, ~60 bytes):

```nasm
; After init_io returns:
mov     eax, vm_script_ptr      ; pointer to script bytes (from EXE section)
mov     ebx, vm_script_size     ; total file size
call    vm_run
; VM returns on HALT — continue with normal process loading
```

**For per-process execution**, the VM can be called from within the process
busy loop by replacing the spin with `call vm_run` using that process's
assigned code/data region.

---

## 8. Code Size Budget

| Component           | Size      | Notes                           |
|---------------------|-----------|---------------------------------|
| Dispatch loop       | ~30 bytes | fetch + jump                    |
| 18 instruction handlers | ~350 B | avg ~20 B each                 |
| vm_puts helper      | ~30 B     |                                   |
| vm_print_num helper | ~80 B     |                                   |
| Header loader       | ~60 B     | magic check + memcpy            |
| Jump table          | 1024 B    | 256×4 bytes, padded             |
| State variables     | ~32 B     | VM registers + PC               |
| **Total**           | **~1570 B** | **< 2048 B** ✓                 |

If the jump table is too large, replace with an if-else chain (~50 bytes):
```
Total with if-else: ~540 bytes (7× smaller, ~3× slower dispatch)
```

---

## 9. Extension Points

The 190 unused opcodes (0x13–0xFF) provide room for future extensions:

| Reserved Range | Suggested Use                    |
|----------------|----------------------------------|
| 0x13–0x1F      | AND, OR, XOR, NOT, SHL, SHR, etc |
| 0x20–0x2F      | EQ, LT, GT, LE, GE comparisons  |
| 0x30–0x3F      | PUSH_REG, POP_REG, PUSH_FLAGS   |
| 0x40–0x4F      | Memory I/O (port in/out)        |
| 0x50–0x5F      | String operations               |
| 0x60–0x6F      | Process management              |
| 0x70–0xFF      | Future use                      |

---

## 10. Files

- `bytecode_vm_design.asm` — Full assembly implementation with comments
- `bytecode_vm_design.md` — This design document
