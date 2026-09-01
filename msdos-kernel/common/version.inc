; ============================================================================
; version.inc — Unified kernel version structure and printing macro
; ----------------------------------------------------------------------------
;  Usage:  %include "common/version.inc"
;          KERNEL_VERSION_MAJOR  equ 5
;          KERNEL_VERSION_MINOR  equ 0
;          KERNEL_VERSION_BUILD  equ 2195
;          KERNEL_VERSION_SP    equ 0
;          ver_print            ; prints "5.0.2195 SP0" to 0xE9 + VGA
;
;  Each axis overrides the *_equ* constants before calling ver_print.
; ============================================================================

; --- Default values (overridable per-axis) ----------------------------------
KERNEL_VERSION_MAJOR  equ 0      ; override!
KERNEL_VERSION_MINOR  equ 1      ; override!
KERNEL_VERSION_BUILD  equ 0      ; override!
KERNEL_VERSION_SP     equ 0      ; override!
KERNEL_VERSION_NAME   equ "MS-DOS Kernel"  ; override!

; --- VersionInfo structure (in-memory, for B/C/D lines) --------------------
struc VersionInfo
    .major  resb 1
    .minor  resb 1
    .build  resw 1
    .sp     resb 1
    .name   resb 32               ; zero-terminated name string
endstruc

; --- ver_print : print version string to 0xE9 debug port -------------------
;  Outputs: "<NAME> v<major>.<minor>.<build> SP<sp>"
;  Uses: AL, SI. Does not clobber segment registers (16-bit) or ESI (32-bit).
;  The string is built inline.
%macro ver_print 0
    jmp     %%skip
%%ver_str:
    db      KERNEL_VERSION_NAME, " v", 0
    db      "0123456789ABCDEF"        ; digit lookup table
%%skip:
    ; print name + " v"
%if __BITS__ == 32
    push    esi
    mov     esi, %%ver_str
%%.name_loop:
    lodsb
    or      al, al
    jz      %%.major
    out     0xE9, al
    jmp     %%.name_loop
%%.major:
    ; print major (decimal)
    mov     al, '0' + KERNEL_VERSION_MAJOR
    out     0xE9, al
    ; print "."
    mov     al, '.'
    out     0xE9, al
    ; print minor
    mov     al, '0' + KERNEL_VERSION_MINOR
    out     0xE9, al
    ; print "."
    mov     al, '.'
    out     0xE9, al
    ; print build (up to 5 digits, hardcoded positions)
    mov     eax, KERNEL_VERSION_BUILD
    mov     esi, 10000
%%.b_loop:
    xor     edx, edx
    div     esi
    add     al, '0'
    out     0xE9, al
    mov     eax, edx
    push    edx
    mov     edx, esi
    shr     edx, 1
    jz      %%sp
    mov     esi, edx
    pop     edx
    jmp     %%.b_loop
%%sp:
    pop     edx
    ; print " SP"
    mov     al, ' '
    out     0xE9, al
    mov     al, 'S'
    out     0xE9, al
    mov     al, 'P'
    out     0xE9, al
    mov     al, '0' + KERNEL_VERSION_SP
    out     0xE9, al
    mov     al, 13
    out     0xE9, al
    mov     al, 10
    out     0xE9, al
    pop     esi
%else
    ; 16-bit version (simpler, for M0 compatibility)
    push    si
    mov     si, %%ver_str
%%.name_loop:
    lodsb
    or      al, al
    jz      %%.major
    push    ax
    mov     ah, 0x0E
    xor     bx, bx
    int     0x10
    pop     ax
    out     0xE9, al
    jmp     %%.name_loop
%%.major:
    mov     al, '0' + KERNEL_VERSION_MAJOR
    call    %%putc
    mov     al, '.'
    call    %%putc
    mov     al, '0' + KERNEL_VERSION_MINOR
    call    %%putc
    mov     al, '.'
    call    %%putc
    ; build number (max 4 digits)
    mov     ax, KERNEL_VERSION_BUILD
    mov     cx, 1000
%%.b_loop:
    xor     dx, dx
    div     cx
    add     al, '0'
    call    %%putc
    mov     ax, dx
    push    dx
    mov     dx, cx
    shr     dx, 1
    jz      %%sp
    mov     cx, dx
    pop     dx
    jmp     %%.b_loop
%%sp:
    pop     dx
    mov     al, ' '
    call    %%putc
    mov     al, 'S'
    call    %%putc
    mov     al, 'P'
    call    %%putc
    mov     al, '0' + KERNEL_VERSION_SP
    call    %%putc
    mov     al, 13
    call    %%putc
    mov     al, 10
    call    %%putc
    pop     si
    jmp     %%.done
%%putc:
    push    ax
    mov     ah, 0x0E
    xor     bx, bx
    int     0x10
    pop     ax
    out     0xE9, al
    ret
%%.done:
%endif
%endmacro
