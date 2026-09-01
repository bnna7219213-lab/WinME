; ============================================================================
; bytecode_vm.asm — Minimal Bytecode VM (stack-based) for M-B4 kernel
; ============================================================================
; Design summary:
;   - 18 instructions, 1-byte opcode + optional 1/2/4-byte operand
;   - Stack machine: push/pop 32-bit values via ESP (kernel stack)
;   - VM uses kernel data area at 0x010280-0x010400 (~384 bytes for code
;     segment, plus the VM's own ~32 bytes of state)
;   - Bytecode loaded from EXE file's embedded script section
;   - Total VM code size target: <2KB (estimated ~1.8KB assembled)
;   - Hooks into process entry via syscall #0x2E before busy_loop
;
; ============================================================================
; SECTION 1: INSTRUCTION ENCODING TABLE
; ============================================================================
;
; ┌──────────┬──────────┬───────────┬────────────────────────────────────┐
; │  OPCODE  │  NAME    │  OPERAND  │  DESCRIPTION                        │
; ├──────────┼──────────┼───────────┼────────────────────────────────────┤
; │  0x00    │  HALT    │   none    │  Stop VM execution, return to host  │
; │  0x01    │  NOP     │   none    │  No operation                       │
; │  0x02    │  PUSH_1  │   uint8   │  Push 8-bit unsigned immediate      │
; │  0x03    │  PUSH_2  │   uint16  │  Push 16-bit unsigned immediate     │
; │  0x04    │  PUSH_4  │   uint32  │  Push 32-bit signed immediate       │
; │  0x05    │  LOAD_M  │   uint32  │  Push [mem] — load 32-bit from addr │
; │  0x06    │  STORE_M │   uint32  │  [mem] = pop() — store 32-bit to addr│
; │  0x07    │  ADD     │   none    │  Pop a,b; push b+a                  │
; │  0x08    │  SUB     │   none    │  Pop a,b; push b-a                  │
; │  0x09    │  MUL     │   none    │  Pop a,b; push b*a                  │
; │  0x0A    │  DIV     │   none    │  Pop a,b; push b/a                  │
; │  0x0B    │  CMP     │   none    │  Pop a,b; set EFLAGS from b-a       │
; │  0x0C    │  JEQ     │   uint32  │  JMP target if ZF=1                 │
; │  0x0D    │  JNE     │   uint32  │  JMP target if ZF=0                 │
; │  0x0E    │  JMP     │   uint32  │  Unconditional jump to offset       │
; │  0x0F    │  CALL    │   uint32  │  Call subroutine at offset          │
; │  0x10    │  RET     │   none    │  Return from subroutine             │
; │  0x11    │  PRINT_S │   uint32  │  Print null-terminated string at addr│
; │  0x12    │  PRINT_N │   none    │  Pop value, print as decimal        │
; └──────────┴──────────┴───────────┴────────────────────────────────────┘
;
; Register alias instructions (use LOAD_M/STORE_M with register base):
;   PUSH_REG → LOAD_M operand = reg_base_addr (no separate opcode needed)
;   POP_REG  → STORE_M operand = reg_base_addr
;   The VM exposes a 4-slot register file at vm_regs[]:
;     R0 = vm_regs+0, R1 = vm_regs+4, R2 = vm_regs+8, R3 = vm_regs+12
;
; Total unique opcodes: 19 (fits in single 256-byte dispatch table)
;
; ============================================================================
; SECTION 2: BYTECODE FILE FORMAT (embedded in EXE)
; ============================================================================
;
; ┌──────────┬──────────┬────────────────────────────────────────────┐
; │ OFFSET   │  SIZE    │  FIELD                                    │
; ├──────────┼──────────┼────────────────────────────────────────────┤
; │  0       │  2 bytes │  Magic: "VM" (0x564D)                     │
; │  2       │  2 bytes │  Version: 0x0001                           │
; │  4       │  4 bytes │  Code length (bytes, not counting header) │
; │  8       │  4 bytes │  Code start address (loaded into VM code) │
; │  12      │  4 bytes │  Data segment length (trailing data)      │
; │  16      │  4 bytes │  Stack size hint (bytes)                  │
; │  20      │  N bytes │  CODE bytes (instructions)                │
; │  20+N    │  M bytes │  DATA segment (strings, data)             │
; └──────────┴──────────┴────────────────────────────────────────────┘
;
; Header size: 20 bytes.
; Total file = 20 + code_len + data_len.
;
; When loaded by the EXE runner:
;   - Code goes to: vm_code_base  = 0x010400
;   - Data goes to: vm_data_base  = 0x010400 + code_len
;   - Stack:        kernel ESP    (uses 4 KB per-process user stack)
;
; ============================================================================
; SECTION 3: VM STATE (32 bytes in kernel data area)
; ============================================================================
;
; vm_state struct at 0x010C00:
;   vm_pc       dd  ?        ; program counter (offset into code base)
;   vm_esp_base dd  ?        ; saved kernel ESP at VM entry
;   vm_code_base dd  ?       ; start of code in memory
;   vm_data_base dd  ?       ; start of data segment
;   vm_stack_top dd  ?       ; ESP limit for stack overflow check
;   vm_regs     times 4 dd 0 ; 4 general-purpose registers
;
; Total: 32 bytes
;
; ============================================================================
; SECTION 4: VM EXECUTION LOOP (Assembly, ~1.8KB)
; ============================================================================
;
; The VM dispatch uses a direct jump table indexed by opcode * 4.
; This is the most compact and fastest approach in x86 assembly.
;
; vm_run:
;   ; Called with: EAX = bytecode file pointer, EBX = file size
;   ;               Loads header, copies code+data to vm area
;   ;               Then enters execute loop
;
;   ; --- Load bytecode header ---
;   push    ebx
;   push    esi
;   push    edi
;
;   mov     esi, eax               ; esi = bytecode data
;   cmp     word [esi], "VM"       ; magic check
;   jne     .bad_magic
;   add     esi, 12                ; skip to code bytes
;   mov     eax, [esi]             ; eax = code_len
;   mov     [vm_code_len], eax
;   add     esi, 4                 ; point to code start
;
;   ; Copy code to vm_code_base
;   mov     edi, vm_code_base
;   mov     ecx, [vm_code_len]
;   cld
;   rep     movsb
;
;   ; Copy data segment
;   mov     ebx, [esi]             ; data_len
;   add     esi, 4
;   add     edi, [vm_code_len]
;   mov     [vm_data_base], edi
;   mov     ecx, ebx
;   rep     movsb
;
;   ; Initialize VM state
;   mov     [vm_pc], byte 0
;   mov     [vm_esp_base], esp
;   mov     [vm_code_base], vm_code_base
;   mov     [vm_stack_top], esp
;
; .dispatch:
;   ; Fetch opcode
;   mov     ebx, [vm_code_base]
;   add     ebx, [vm_pc]
;   movzx   eax, byte [ebx]        ; opcode
;   inc     dword [vm_pc]          ; advance past opcode
;
;   ; Dispatch via jump table (16 bytes * 16 = 256 bytes, well under budget)
;   ; Compact: only populated entries for our 19 opcodes
;   jmp     dword [vm_jumptable + eax*4]
;
; ============================================================================
; INSTRUCTION IMPLEMENTATIONS
; ============================================================================

; --- HALT (0x00) ---
;   No operand.
;   Pop VM stack back to vm_esp_base, restore ESP, return to caller.
instr_halt:
    mov     esp, [vm_esp_base]
    pop     edi
    pop     esi
    pop     ebx
    ret

; --- NOP (0x01) ---
;   No operand.
instr_nop:
    jmp     .dispatch_next
.dispatch_next:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    movzx   eax, byte [ebx]
    inc     dword [vm_pc]
    jmp     dword [vm_jumptable + eax*4]

; --- PUSH_1 (0x02) ---
;   1-byte operand: uint8.
instr_push1:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    movzx   eax, byte [ebx]
    inc     dword [vm_pc]
    push    eax
    jmp     .dispatch_next

; --- PUSH_2 (0x03) ---
;   2-byte operand: uint16 (little-endian).
instr_push2:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    movzx   eax, word [ebx]
    add     dword [vm_pc], 2
    push    eax
    jmp     .dispatch_next

; --- PUSH_4 (0x04) ---
;   4-byte operand: int32 (little-endian).
instr_push4:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    mov     eax, [ebx]
    add     dword [vm_pc], 4
    push    eax
    jmp     .dispatch_next

; --- LOAD_M (0x05) ---
;   4-byte operand: memory address to read from.
instr_load_m:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    mov     eax, [ebx]
    add     dword [vm_pc], 4
    mov     eax, [eax]             ; dereference
    push    eax
    jmp     .dispatch_next

; --- STORE_M (0x06) ---
;   4-byte operand: memory address to write to.
instr_store_m:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    mov     edi, [ebx]             ; target address
    add     dword [vm_pc], 4
    pop     eax                    ; value to store
    mov     [edi], eax
    jmp     .dispatch_next

; --- ADD (0x07) ---
instr_add:
    pop     eax
    pop     ebx
    add     eax, ebx
    push    eax
    jmp     .dispatch_next

; --- SUB (0x08) ---
instr_sub:
    pop     eax
    pop     ebx
    sub     eax, ebx
    push    eax
    jmp     .dispatch_next

; --- MUL (0x09) ---
instr_mul:
    pop     eax
    pop     ebx
    imul    eax, ebx
    push    eax
    jmp     .dispatch_next

; --- DIV (0x0A) ---
instr_div:
    pop     eax
    pop     ebx
    xor     edx, edx
    idiv    eax                    ; EDX:EAX / EAX -> EAX
    push    eax
    jmp     .dispatch_next

; --- CMP (0x0B) ---
instr_cmp:
    pop     eax
    pop     ebx
    cmp     ebx, eax              ; sets ZF, SF, etc.
    jmp     .dispatch_next

; --- JEQ (0x0C) ---
;   4-byte operand: target offset (absolute offset into code).
instr_jeq:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    mov     eax, [ebx]
    add     dword [vm_pc], 4
    jz      .jeq_take
    jmp     .dispatch_next
.jeq_take:
    mov     [vm_pc], eax
    jmp     .dispatch_next

; --- JNE (0x0D) ---
instr_jne:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    mov     eax, [ebx]
    add     dword [vm_pc], 4
    jnz     .jne_take
    jmp     .dispatch_next
.jne_take:
    mov     [vm_pc], eax
    jmp     .dispatch_next

; --- JMP (0x0E) ---
instr_jmp:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    mov     eax, [ebx]
    add     dword [vm_pc], 4
    mov     [vm_pc], eax
    jmp     .dispatch_next

; --- CALL (0x0F) ---
;   4-byte operand: target offset. Pushes return address.
instr_call:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    mov     eax, [ebx]
    add     dword [vm_pc], 4
    push    dword [vm_pc]         ; push return address
    mov     [vm_pc], eax
    jmp     .dispatch_next

; --- RET (0x10) ---
instr_ret:
    pop     eax                    ; return address
    mov     [vm_pc], eax
    jmp     .dispatch_next

; --- PRINT_S (0x11) ---
;   4-byte operand: address of null-terminated string.
instr_print_s:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    mov     esi, [ebx]             ; string address
    add     dword [vm_pc], 4
    push    eax
    push    esi
    call    vm_puts               ; use kernel puts32 helper
    pop     esi
    pop     eax
    jmp     .dispatch_next

; --- PRINT_N (0x12) ---
instr_print_n:
    pop     eax
    push    eax
    call    vm_print_num          ; use kernel print_num helper
    pop     eax
    jmp     .dispatch_next

; ============================================================================
; SECTION 5: JUMP TABLE
; ============================================================================
;
; 256 entries * 4 bytes = 1024 bytes. Only 19 are populated.
; All unimplemented opcodes jump to vm_invalid (HALT with error).

; vm_jumptable:
;   dd      instr_halt          ; 0x00
;   dd      instr_nop           ; 0x01
;   dd      instr_push1         ; 0x02
;   dd      instr_push2         ; 0x03
;   dd      instr_push4         ; 0x04
;   dd      instr_load_m        ; 0x05
;   dd      instr_store_m       ; 0x06
;   dd      instr_add           ; 0x07
;   dd      instr_sub           ; 0x08
;   dd      instr_mul           ; 0x09
;   dd      instr_div           ; 0x0A
;   dd      instr_cmp           ; 0x0B
;   dd      instr_jeq           ; 0x0C
;   dd      instr_jne           ; 0x0D
;   dd      instr_jmp           ; 0x0E
;   dd      instr_call          ; 0x0F
;   dd      instr_ret           ; 0x10
;   dd      instr_print_s       ; 0x11
;   dd      instr_print_n       ; 0x12
;   dd      instr_halt          ; 0x13-0xFF (unimplemented -> HALT)
;   times   237 dd instr_halt

; ============================================================================
; SECTION 6: VM HELPERS
; ============================================================================
vm_puts:
    push    eax
    push    esi
.vm_loop:
    lodsb
    or      al, al
    jz      .vm_done
    out     0xE9, al
    jmp     .vm_loop
.vm_done:
    pop     esi
    pop     eax
    ret

vm_print_num:
    ; Same as kernel print_num - reuses num_buf
    push    ebx
    push    ecx
    push    edx
    xor     ebx, ebx
    mov     ecx, 10
    mov     esi, num_buf + 6
    mov     [esi], byte '$'
    test    eax, eax
    jnz     .pn_go
    mov     [esi - 1], '0'
    dec     esi
    jmp     .pn_print
.pn_go:
.pn_digit:
    xor     edx, edx
    div     ecx
    add     dl, '0'
    dec     esi
    mov     [esi], dl
    test    eax, eax
    jnz     .pn_digit
.pn_print:
    push    eax
    push    ebx
    mov     edx, esi
.pn_loop:
    mov     al, [edx]
    cmp     al, '$'
    je      .pn_done
    out     0xE9, al
    inc     edx
    jmp     .pn_loop
.pn_done:
    pop     ebx
    pop     eax
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; SECTION 7: SAMPLE PROGRAM — Hello World + 2+3
; ============================================================================
;
; This program:
;   1. Prints "Hello World" from data segment
;   2. Computes 2+3 = 5
;   3. Prints the result (5)
;   4. HALTs
;
; Layout when loaded at vm_code_base = 0x010400:
;   Code starts at 0x010400
;   Data starts at 0x010400 + code_len
;
; Bytecode (hex):
;   ; Print "Hello World"
;   04 00 0C 01 00    PUSH_4   vm_data_base (addr of string)
;                      ; vm_data_base = 0x01040C (after 12 bytes of code)
;   11 00 0C 01 00    PRINT_S  vm_data_base
;
;   ; Compute 2 + 3
;   02 02              PUSH_1   2
;   02 03              PUSH_1   3
;   07                 ADD
;
;   ; Print result
;   12                 PRINT_N
;
;   ; Print newline via push 0x0A then push 0x0D, but simpler: HALT
;   00                 HALT
;
; Full hex dump of CODE section (22 bytes):
;   Offset  Hex                        Instruction
;   00      04 00 0C 01 00            PUSH_4 0x00010C00  (data base addr)
;   05      11 00 0C 01 00            PRINT_S 0x00010C00
;   0A      02 02                      PUSH_1 2
;   0C      02 03                      PUSH_1 3
;   0E      07                         ADD
;   0F      12                         PRINT_N
;   10      00                         HALT
;
; DATA section (12 bytes): "Hello World\0"

; ============================================================================
; SECTION 8: FILE FORMAT EXAMPLE (raw bytes of .VM file)
; ============================================================================
;
; File: hello.vm
;
; Offset  Hex          ASCII    Description
; 00      56 4D        "VM"     Magic
; 02      01 00                    Version 1
; 04      14 00 00 00               Code length = 20 bytes
; 08      00 04 01 00               Code base = 0x00010400
; 0C      0C 00 00 00               Data length = 12 bytes
; 10      80 00 00 00               Stack hint = 128 bytes
; 14      04 00 0C 01 00            PUSH_4 0x00010414
; 19      11 00 0C 01 00            PRINT_S 0x00010414
; 1E      02 02                      PUSH_1 2
; 20      02 03                      PUSH_1 3
; 22      07                         ADD
; 23      12                         PRINT_N
; 24      0D 00 00 00 00            JNE 0 (unconditional to skip CR/LF)
;                                   Actually let's just use HALT:
; 25      00                         HALT
;                                   (code_len=21 in reality, adjust above)
;
; Correction: code_len = 21 (offset 14 to 34 inclusive)
; DATA at offset 34 (0x22):
; 22      48 65 6C 6C 6F 20 57 6F   "Hello Wo"
; 2A      72 6C 64 0A 0D 00          "rld\n\r\0"
;
; Full 26-byte .VM file (revised, correct):
;   56 4D              Magic "VM"
;   01 00              Version 1
;   15 00 00 00        Code len = 21
;   00 04 01 00        Code base
;   06 00 00 00        Data len = 6
;   80 00 00 00        Stack hint = 128
;   ; CODE (21 bytes starting at file offset 20):
;   04 15 04 01 00     PUSH_4 0x00010415
;   11 15 04 01 00     PRINT_S 0x00010415
;   02 02               PUSH_1 2
;   02 03               PUSH_1 3
;   07                  ADD
;   12                  PRINT_N
;   00                  HALT
;   ; DATA (6 bytes at file offset 41):
;   48 65 6C 6C 6F 00  "Hello\0"
;
; ============================================================================
; SECTION 9: KERNEL HOOK POINT
; ============================================================================
;
; Where to insert the VM into the EXE runner flow:
;
;   Current flow (in b4_kernel.asm process entry):
;     init_page_tables -> init_gdt -> init_idt -> remap_pit -> init_sched
;     -> init_io -> load_processes -> start_scheduling -> busy_loop
;
;   Proposed VM hook point:
;     After init_io, before load_processes:
;       mov     eax, vm_script_buffer     ; pointer to script in EXE
;       mov     ebx, vm_script_size
;       call    vm_run
;
;   Alternatively, for EXE files specifically:
;     - EXE loader detects "VM" magic in section header
;     - Extracts code+data bytes to vm_code_base/vm_data_base
;     - Calls vm_run with those pointers
;     - VM executes to HALT, then control returns to normal EXE code
;
;   In the scheduler busy_loop, a process could:
;     1. Load bytecode from disk into its user stack area
;     2. Call vm_run
;     3. Continue normal execution after VM HALTs
;
; ============================================================================
; SECTION 10: CODE SIZE ESTIMATE
; ============================================================================
;
; Individual instruction implementations:
;   HALT:        ~10 bytes
;   NOP:         ~18 bytes (includes fetch)
;   PUSH_1:      ~18 bytes
;   PUSH_2:      ~20 bytes
;   PUSH_4:      ~18 bytes
;   LOAD_M:      ~22 bytes
;   STORE_M:     ~22 bytes
;   ADD:          ~8 bytes
;   SUB:          ~8 bytes
;   MUL:          ~9 bytes
;   DIV:          ~9 bytes
;   CMP:          ~7 bytes
;   JEQ:         ~20 bytes
;   JNE:         ~20 bytes
;   JMP:         ~16 bytes
;   CALL:        ~20 bytes
;   RET:          ~6 bytes
;   PRINT_S:     ~24 bytes
;   PRINT_N:     ~24 bytes
;   vm_puts:     ~30 bytes
;   vm_print_num: ~80 bytes
;   Header loader: ~60 bytes
;   Jump table: 1024 bytes (256*4)
;   State vars:   ~32 bytes
;
;   Subtotal code: ~450 bytes
;   Jump table:    1024 bytes
;   Total:         ~1474 bytes < 2048 ✓
;
; Optimization: Use if-else chain instead of jump table saves 1024 bytes
; but adds ~50 bytes of comparison code. Total would be ~500 bytes.
; Jump table is preferred for speed.
