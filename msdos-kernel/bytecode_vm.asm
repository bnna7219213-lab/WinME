; ============================================================================
; bytecode_vm.asm — Assembleable Bytecode VM for M-B4 32-bit Kernel
; ============================================================================
; Compile: nasm -f bin -o bytecode_vm.bin bytecode_vm.asm
; Size target: < 2048 bytes
;
; This module provides vm_run() which takes:
;   EAX = pointer to bytecode file in memory
;   EBX = size of bytecode file
; And returns when the VM HALTs.
; ============================================================================
; NOTE: This file is designed to be %included or linked into the kernel.
; It references puts32, print_num, and num_buf from the main kernel.
; When standalone, stubs are provided below.
; ============================================================================

BITS 32

; ============================================================================
; OPCODE CONSTANTS
; ============================================================================
OP_HALT     EQU 0x00
OP_NOP      EQU 0x01
OP_PUSH1    EQU 0x02
OP_PUSH2    EQU 0x03
OP_PUSH4    EQU 0x04
OP_LOADM    EQU 0x05
OP_STOROM   EQU 0x06
OP_ADD      EQU 0x07
OP_SUB      EQU 0x08
OP_MUL      EQU 0x09
OP_DIV      EQU 0x0A
OP_CMP      EQU 0x0B
OP_JEQ      EQU 0x0C
OP_JNE      EQU 0x0D
OP_JMP      EQU 0x0E
OP_CALL     EQU 0x0F
OP_RET      EQU 0x10
OP_PRS      EQU 0x11
OP_PRN      EQU 0x12

; ============================================================================
; VM STATE (embedded at fixed addresses in kernel data area)
; These addresses match the M-B4 kernel layout at 0x010C00
; ============================================================================

%ifdef STANDALONE
; For standalone testing, allocate in .bss-like area
section .bss
  vm_pc         resd 1
  vm_esp_base   resd 1
  vm_code_base  resd 1
  vm_data_base  resd 1
  vm_stack_top  resd 1
  vm_code_len   resd 1
  vm_regs       resd 4
  vm_jumptable  resd 256
  num_buf       resb 8
section .text
%else
; Kernel addresses (M-B4 layout)
  vm_pc         equ 0x010C00
  vm_esp_base   equ 0x010C04
  vm_code_base  equ 0x010C08
  vm_data_base  equ 0x010C0C
  vm_stack_top  equ 0x010C10
  vm_code_len   equ 0x010C14
  vm_regs       equ 0x010C18
  vm_jumptable  equ 0x010C20
%endif

; ============================================================================
; vm_run — Entry point for the bytecode VM
; ============================================================================
; Input:  EAX = pointer to .vm file data in memory
;         EBX = size of .vm file data
; Output: returns on HALT instruction
; Clobbers: EAX, EBX, ECX, EDX, ESI, EDI, ESP (temporarily)

vm_run:
    ; Save caller context
    push    ebx
    push    esi
    push    edi

    ; Validate magic bytes
    mov     esi, eax
    cmp     word [esi], "VM"
    jne     .bad_magic

    ; Read header fields
    mov     eax, [esi + 4]       ; code_len
    mov     [vm_code_len], eax
    mov     eax, [esi + 8]       ; code_base
    mov     [vm_code_base], eax
    mov     eax, [esi + 12]      ; data_len
    mov     ecx, eax             ; save for later

    ; Point to first code byte (header is 20 bytes)
    add     esi, 20

    ; Copy CODE segment to vm_code_base
    mov     edi, [vm_code_base]
    mov     eax, [vm_code_len]
    cld
    rep     movsb

    ; Copy DATA segment
    mov     eax, [vm_code_base]
    add     edi, eax             ; edi = code_base + code_len
    mov     [vm_data_base], edi
    mov     eax, ecx             ; data_len
    rep     movsb

    ; Initialize VM state
    mov     dword [vm_pc], 0
    mov     dword [vm_esp_base], esp
    mov     dword [vm_stack_top], esp

    ; ---- DISPATCH LOOP ----
.dispatch:
    ; Fetch opcode
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    movzx   eax, byte [ebx]
    inc     dword [vm_pc]

    ; Dispatch via jump table
    jmp     dword [vm_jumptable + eax*4]

; ============================================================================
; INSTRUCTION HANDLERS
; ============================================================================

; --- HALT (0x00) ---
instr_halt:
    mov     esp, [vm_esp_base]
    pop     edi
    pop     esi
    pop     ebx
    ret

; --- NOP (0x01) ---
instr_nop:
    jmp     .next_fetch

; --- PUSH_1 (0x02) — push 8-bit immediate ---
instr_push1:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    movzx   eax, byte [ebx]
    inc     dword [vm_pc]
    push    eax
    jmp     .next_fetch

; --- PUSH_2 (0x03) — push 16-bit immediate ---
instr_push2:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    movzx   eax, word [ebx]
    add     dword [vm_pc], 2
    push    eax
    jmp     .next_fetch

; --- PUSH_4 (0x04) — push 32-bit immediate ---
instr_push4:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    mov     eax, [ebx]
    add     dword [vm_pc], 4
    push    eax
    jmp     .next_fetch

; --- LOAD_M (0x05) — push [address] ---
instr_load_m:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    mov     eax, [ebx]
    add     dword [vm_pc], 4
    mov     eax, [eax]
    push    eax
    jmp     .next_fetch

; --- STORE_M (0x06) — [address] = pop() ---
instr_store_m:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    mov     edi, [ebx]
    add     dword [vm_pc], 4
    pop     eax
    mov     [edi], eax
    jmp     .next_fetch

; --- ADD (0x07) ---
instr_add:
    pop     eax
    pop     ebx
    add     eax, ebx
    push    eax
    jmp     .next_fetch

; --- SUB (0x08) ---
instr_sub:
    pop     eax
    pop     ebx
    sub     eax, ebx
    push    eax
    jmp     .next_fetch

; --- MUL (0x09) ---
instr_mul:
    pop     eax
    pop     ebx
    imul    eax, ebx
    push    eax
    jmp     .next_fetch

; --- DIV (0x0A) ---
instr_div:
    pop     eax
    pop     ebx
    xor     edx, edx
    idiv    eax
    push    eax
    jmp     .next_fetch

; --- CMP (0x0B) ---
instr_cmp:
    pop     eax
    pop     ebx
    cmp     ebx, eax
    jmp     .next_fetch

; --- JEQ (0x0C) ---
instr_jeq:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    mov     eax, [ebx]
    add     dword [vm_pc], 4
    jz      .jeq_taken
    jmp     .next_fetch
.jeq_taken:
    mov     [vm_pc], eax
    jmp     .next_fetch

; --- JNE (0x0D) ---
instr_jne:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    mov     eax, [ebx]
    add     dword [vm_pc], 4
    jnz     .jne_taken
    jmp     .next_fetch
.jne_taken:
    mov     [vm_pc], eax
    jmp     .next_fetch

; --- JMP (0x0E) ---
instr_jmp:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    mov     eax, [ebx]
    add     dword [vm_pc], 4
    mov     [vm_pc], eax
    jmp     .next_fetch

; --- CALL (0x0F) ---
instr_call:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    mov     eax, [ebx]
    add     dword [vm_pc], 4
    push    dword [vm_pc]
    mov     [vm_pc], eax
    jmp     .next_fetch

; --- RET (0x10) ---
instr_ret:
    pop     eax
    mov     [vm_pc], eax
    jmp     .next_fetch

; --- PRINT_S (0x11) ---
instr_print_s:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    mov     esi, [ebx]
    add     dword [vm_pc], 4
    push    eax
    push    esi
    call    _vm_puts
    pop     esi
    pop     eax
    jmp     .next_fetch

; --- PRINT_N (0x12) ---
instr_print_n:
    pop     eax
    push    eax
    call    _vm_print_num
    pop     eax
    jmp     .next_fetch

; ============================================================================
; NEXT FETCH (shared code for all handlers)
; ============================================================================
.next_fetch:
    mov     ebx, [vm_code_base]
    add     ebx, [vm_pc]
    movzx   eax, byte [ebx]
    inc     dword [vm_pc]
    jmp     dword [vm_jumptable + eax*4]

; ============================================================================
; ERROR: Bad magic
; ============================================================================
.bad_magic:
    pop     edi
    pop     esi
    pop     ebx
    ret

; ============================================================================
; VM PRINT STR — internal helper (replaces kernel puts32)
; Input: ESI = pointer to null-terminated string
; ============================================================================
_vm_puts:
    push    eax
.vp_loop:
    mov     al, [esi]
    or      al, al
    jz      .vp_done
    out     0xE9, al
    inc     esi
    jmp     .vp_loop
.vp_done:
    pop     eax
    ret

; ============================================================================
; VM PRINT NUM — internal helper (replaces kernel print_num)
; Input: EAX = 32-bit signed integer
; ============================================================================
_vm_print_num:
    push    ebx
    push    ecx
    push    edx
    push    esi
    xor     ebx, ebx
    mov     ecx, 10

    ; Handle sign
    test    eax, eax
    jns     .pnn_pos
    neg     eax
    mov     bl, '-'
.pnn_pos:
    test    bl, bl
    jz      .pnn_no_sign

    ; Print sign char
    out     0xE9, bl
    mov     bl, 0
.pnn_no_sign:

    ; Convert to decimal string (stack-based, no num_buf needed)
    xor     edx, edx
    push    edx              ; end marker (0 count)
.pnn_divloop:
    xor     edx, edx
    div     ecx
    add     dl, '0'
    push    edx
    test    eax, eax
    jnz     .pnn_divloop

    ; Pop and print digits (top of stack is count)
    pop     ecx
    add     ecx, ecx         ; count * 2 (each digit is a push)
.pnn_print:
    test    ecx, ecx
    jz      .pnn_done
    pop     eax
    mov     al, ah
    out     0xE9, al
    sub     ecx, 2
    jmp     .pnn_print
.pnn_done:
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; JUMP TABLE — 256 entries, each 4 bytes
; ============================================================================
; Unimplemented opcodes (0x13-0xFF) default to HALT for safety.
;
; This is a data structure, not code. Placed at vm_jumptable address.
; When %included in the kernel, the addresses are absolute.

; The jump table is initialized by vm_init_jumptable() called during boot.
; Alternatively, it can be initialized inline here as a data block.

vm_init_jumptable:
    push    ebx
    push    ecx
    push    edi

    mov     edi, vm_jumptable
    ; Initialize all entries to HALT
    mov     ecx, 256
    mov     eax, instr_halt
    rep     stosd

    ; Populate used entries
    mov     eax, instr_nop
    mov     [vm_jumptable + OP_NOP*4], eax
    mov     eax, instr_push1
    mov     [vm_jumptable + OP_PUSH1*4], eax
    mov     eax, instr_push2
    mov     [vm_jumptable + OP_PUSH2*4], eax
    mov     eax, instr_push4
    mov     [vm_jumptable + OP_PUSH4*4], eax
    mov     eax, instr_load_m
    mov     [vm_jumptable + OP_LOADM*4], eax
    mov     eax, instr_store_m
    mov     [vm_jumptable + OP_STOROM*4], eax
    mov     eax, instr_add
    mov     [vm_jumptable + OP_ADD*4], eax
    mov     eax, instr_sub
    mov     [vm_jumptable + OP_SUB*4], eax
    mov     eax, instr_mul
    mov     [vm_jumptable + OP_MUL*4], eax
    mov     eax, instr_div
    mov     [vm_jumptable + OP_DIV*4], eax
    mov     eax, instr_cmp
    mov     [vm_jumptable + OP_CMP*4], eax
    mov     eax, instr_jeq
    mov     [vm_jumptable + OP_JEQ*4], eax
    mov     eax, instr_jne
    mov     [vm_jumptable + OP_JNE*4], eax
    mov     eax, instr_jmp
    mov     [vm_jumptable + OP_JMP*4], eax
    mov     eax, instr_call
    mov     [vm_jumptable + OP_CALL*4], eax
    mov     eax, instr_ret
    mov     [vm_jumptable + OP_RET*4], eax
    mov     eax, instr_print_s
    mov     [vm_jumptable + OP_PRS*4], eax
    mov     eax, instr_print_n
    mov     [vm_jumptable + OP_PRN*4], eax

    ; Note: OP_HALT (0x00) already set to instr_halt by memset

    pop     edi
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; SAMPLE PROGRAM DATA — Hello World + 2+3
; ============================================================================
; This can be loaded directly into the kernel to test the VM.
; The data is the raw .vm file bytes.

hello_vm_data:
    ; Header (20 bytes)
    db      "VM"              ; magic
    dw      1                 ; version
    dd      hello_code_end - hello_code   ; code_len
    dd      0x010400          ; code_base
    dd      hello_data_end - hello_data   ; data_len
    dd      128               ; stack hint

    ; CODE (19 bytes)
hello_code:
    ; Print "Hello"
    db      OP_PUSH4          ; PUSH_4
    dd      0x010413          ; address of data string
    db      OP_PRS            ; PRINT_S
    dd      0x010413          ; address of data string

    ; Compute 2+3
    db      OP_PUSH1
    db      2
    db      OP_PUSH1
    db      3
    db      OP_ADD

    ; Print result
    db      OP_PRN

    ; Halt
    db      OP_HALT
hello_code_end:

    ; DATA (6 bytes)
hello_data:
    db      "Hello", 0
hello_data_end:

hello_vm_end:
hello_vm_size   equ hello_vm_end - hello_vm_data

; ============================================================================
; VM RUN HELPER — loads and runs the built-in hello world sample
; ============================================================================
vm_run_hello:
    mov     eax, hello_vm_data
    mov     ebx, hello_vm_size
    call    vm_run
    ret

; ============================================================================
; END OF BYTECODE VM
; ============================================================================
