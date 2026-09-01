; ============================================================================
; debug.inc — QEMU 0xE9 debug port output macros (shared by all axes)
; ----------------------------------------------------------------------------
;  Usage:  %include "common/debug.inc"
;          dbg_puts "hello", 13, 10, 0
;
;  Works in both 16-bit and 32-bit code (uses out instruction, no BIOS).
;  The QEMU flag -debugcon file:dbg.log captures all 0xE9 output.
; ============================================================================

; --- dbg_putc : write AL to port 0xE9 (16-bit) ------------------------------
%macro dbg_putc 0
    out     0xE9, al
%endmacro

; --- dbg_puts : emit a NUL-terminated string literal to 0xE9 ----------------
;  Accepts 1 or more arguments (all collected into %1 as a single token list).
;  Usage:  dbg_puts "hello", 13, 10, 0
;  Works in BITS 16 and BITS 32 (detected via __BITS__).
%macro dbg_puts 1+
    jmp     %%skip
%%str   db  %1
%%skip:
%if __BITS__ == 32
    push    esi
    mov     esi, %%str
%%.loop:
    lodsb
    or      al, al
    jz      %%.done
    out     0xE9, al
    jmp     %%.loop
%%.done:
    pop     esi
%else
    push    si
    mov     si, %%str
%%.loop:
    lodsb
    or      al, al
    jz      %%.done
    out     0xE9, al
    jmp     %%.loop
%%.done:
    pop     si
%endif
%endmacro

; --- dbg_nl : emit CR+LF to 0xE9 --------------------------------------------
%macro dbg_nl 0
    mov     al, 13
    out     0xE9, al
    mov     al, 10
    out     0xE9, al
%endmacro

; --- dbg_hex8 : print AL as 2 hex digits to 0xE9 ---------------------------
%macro dbg_hex8 0
    push    ax
    mov     ah, al
    shr     al, 4
    call    %%hex_nibble
    mov     al, ah
    and     al, 0x0F
    call    %%hex_nibble
    pop     ax
    jmp     %%done
%%hex_nibble:
    add     al, '0'
    cmp     al, '9'
    jbe     %%ok
    add     al, 7        ; 'A' - '0' - 10 = 7
%%ok:
    out     0xE9, al
    ret
%%done:
%endmacro

; --- dbg_hex32 : print EAX as 8 hex digits to 0xE9 (32-bit only) -----------
;  The previous implementation only emitted 4 digits: its helper printed the
;  two nibbles of AL and was called twice on a rotated EAX, so bytes 1 and 3
;  were silently dropped.  Shift out all 8 nibbles instead.
%macro dbg_hex32 0
    push    eax
    push    ecx
    mov     ecx, 28
%%loop:
    push    eax
    shr     eax, cl
    and     eax, 0x0F
    add     al, '0'
    cmp     al, '9'
    jbe     %%ok2
    add     al, 7            ; 'A' - '0' - 10 = 7
%%ok2:
    out     0xE9, al
    pop     eax
    sub     ecx, 4
    jns     %%loop
    pop     ecx
    pop     eax
%endmacro
