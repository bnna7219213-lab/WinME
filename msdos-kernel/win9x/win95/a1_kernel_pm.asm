; ============================================================================
; a1_kernel_pm.asm — M-A1: Real mode ↔ Protected mode switching
; ----------------------------------------------------------------------------
;  This kernel extends the M0 shell with the ability to switch to 32-bit
;  protected mode, print a message, and switch back to real mode.
;
;  Loaded at 0x1000:0x0000 by the existing boot.asm (M0 bootloader).
;  Uses the common/ GDT and debug macros.
;
;  Milestone M-A1 (Win9x axis):
;    - Enter PM: lgdt + CR0.PE + far jump
;    - Print "PROTECTED MODE ON" via 0xE9
;    - Return to real mode: clear CR0.PE + far jump
;    - Print "BACK IN REAL MODE" via BIOS
;
;  Assemble: nasm -f bin win9x/src/a1_kernel_pm.asm -o win9x/build/kernel.bin
;  Pack:     copy M0's boot.bin + this kernel.bin → win9x.img
; ============================================================================

BITS 16
ORG 0x0000

; Include shared macros (via relative path from project root)
%include "common/debug.inc"
%include "common/gdt.inc"

start:
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x9000

    ; Install int 0x20 handler (same as M0)
    cli
    xor     ax, ax
    mov     es, ax
    mov     word [0x20*4], int20_handler
    mov     word [0x20*4+2], cs
    mov     es, ax
    sti

    ; Print banner
    mov     si, banner
    call    puts

    ; Self-test: demonstrate PM switch
    mov     si, pm_test_msg
    call    puts

    ; --- Switch to Protected Mode ---
    call    enter_pm

after_pm_ret:
    ; --- Back from PM ---
    mov     si, back_rm_msg
    call    puts

    ; --- Shell loop (same as M0) ---
.cmdloop:
    mov     si, prompt
    call    puts
    call    readline
    call    dispatch
    jmp     .cmdloop

; ============================================================================
; Protected Mode entry/exit
; ============================================================================

enter_pm:
    ; Save real-mode return address
    mov     [rm_ret_offset], ax    ; placeholder

    ; Build GDT in memory (at a known location within our segment)
    ; We use inline GDT since we need it at a known CS-relative address
    cli

    ; Load GDT
    lgdt    [gdt_descriptor]

    ; Enable A20 (fast method)
    in      al, 0x92
    or      al, 2
    out     0x92, al

    ; Set CR0.PE
    mov     eax, cr0
    or      eax, 1
    mov     cr0, eax

    ; Far jump to 32-bit code (flush pipeline, load CS=0x08)
    jmp     0x08:pm32_entry

; --- 32-bit protected mode code ---
BITS 32
pm32_entry:
    mov     ax, 0x10              ; SEL_DATA0
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    mov     ss, ax
    mov     esp, 0x2000            ; stack at linear 0x12000 (0x10000 + 0x2000)

    ; Print "PROTECTED MODE ON" via 0xE9 (direct, no loop)
    mov     esi, pm_on_msg
.pm_print:
    lodsb
    or      al, al
    jz      .pm_done
    out     0xE9, al
    jmp     .pm_print
.pm_done:

    ; --- Return to Real Mode ---
    ; Step 1: Far jump to 16-bit code segment (selector 0x18, D=0). PM still active.
    jmp     0x18:rm_16

; --- 16-bit code stub (PM, D=0 so 16-bit) ---
BITS 16
rm_16:
    ; DEBUG
    mov     al, 'R'
    out     0xE9, al
    ; Step 2: Clear CR0.PE (now in 16-bit PM)
    mov     eax, cr0
    and     eax, 0xFFFFFFFE
    mov     cr0, eax
    ; DEBUG
    mov     al, 'C'
    out     0xE9, al

    ; Step 3: Far jump to real mode. PE=0 so 0x1000 is a real-mode segment.
    jmp     0x1000:rm_back

; --- Back in 16-bit real mode ---
rm_back:
    ; Reload segment registers for real mode
    mov     ax, 0x1000
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    ; sp already set back to 0x9000 by the shell loop
    mov     sp, 0x9000

    ; Restore interrupt flag
    sti

    ; Jump back to the instruction after call enter_pm (in start section)
    jmp     after_pm_ret

.after_pm:

; ============================================================================
; Shell routines (reused from M0)
; ============================================================================

puts:
    lodsb
    or      al, al
    jz      .d
    push    ax
    mov     ah, 0x0E
    xor     bx, bx
    int     0x10
    pop     ax
    out     0xE9, al
    jmp     puts
.d: ret

readline:
    mov     si, buf
.loop:
    mov     ah, 0x00
    int     0x16
    cmp     al, 0x0D
    je      .done
    cmp     al, 0x08
    je      .bs
    cmp     si, buf+64
    jae     .loop
    mov     [si], al
    inc     si
    mov     ah, 0x0E
    xor     bx, bx
    int     0x10
    jmp     .loop
.bs:
    cmp     si, buf
    je      .loop
    dec     si
    mov     ah, 0x0E
    mov     al, 0x08
    int     0x10
    mov     al, ' '
    int     0x10
    mov     al, 0x08
    int     0x10
    jmp     .loop
.done:
    mov     byte [si], 0
    mov     ah, 0x0E
    mov     al, 0x0D
    int     0x10
    mov     al, 0x0A
    int     0x10
    ret

dispatch:
    mov     si, buf
    mov     di, cmd_help
    call    cmd_match
    jc      .help
    mov     si, buf
    mov     di, cmd_ver
    call    cmd_match
    jc      .ver
    mov     si, buf
    mov     di, cmd_cls
    call    cmd_match
    jc      .cls
    mov     si, buf
    mov     di, cmd_echo
    call    cmd_match
    jc      .echo
    mov     si, buf
    mov     di, cmd_pm
    call    cmd_match
    jc      .pm
    mov     si, buf
    mov     di, cmd_halt
    call    cmd_match
    jc      .halt
    mov     si, msg_unknown
    call    puts
    ret
.help:
    mov     si, help_txt
    call    puts
    ret
.ver:
    mov     si, ver_txt
    call    puts
    ret
.cls:
    mov     ah, 0x00
    mov     al, 0x03
    int     0x10
    ret
.echo:
    mov     si, buf+5
    call    puts
    ret
.pm:
    call    enter_pm
    mov     si, back_rm_msg
    call    puts
    ret
.halt:
    mov     si, halt_txt
    call    puts
    cli
    hlt

cmd_match:
    push    si
    push    di
.loop:
    mov     al, [di]
    or      al, al
    jz      .cmd_end
    cmp     al, [si]
    jne     .no
    inc     si
    inc     di
    jmp     .loop
.cmd_end:
    mov     al, [si]
    cmp     al, 0x20
    je      .yes
    or      al, al
    jz      .yes
.no:
    pop     di
    pop     si
    clc
    ret
.yes:
    pop     di
    pop     si
    stc
    ret

; --- int 0x20 handler ---
int20_handler:
    cmp     ah, 0x00
    je      .halt
    cmp     ah, 0x01
    je      .print
    iret
.halt:
    cli
    hlt
.print:
    push    si
    mov     si, dx
    call    puts
    pop     si
    iret

; ============================================================================
; Data
; ============================================================================
banner       db "Win9x Axis — M-A1 (PM switch demo)", 13, 10
             db "Type 'help' for commands, 'pm' to switch to PM.", 13, 10, 0
pm_test_msg  db "[PM test] switching to protected mode...", 13, 10, 0
pm_on_msg    db "PROTECTED MODE ON", 13, 10, 0
cr0_msg      db "CR0=", 0
back_rm_msg  db "BACK IN REAL MODE — PM round-trip OK", 13, 10, 0
prompt       db "C:\>", 0
help_txt     db "commands:", 13, 10
             db "  help    show this help", 13, 10
             db "  ver     show version", 13, 10
             db "  cls     clear screen", 13, 10
             db "  echo <text>  print text", 13, 10
             db "  pm      switch to protected mode and back", 13, 10
             db "  halt    stop the system", 13, 10, 0
ver_txt      db "Win9x Axis M-A1 / 16-bit shell + 32-bit PM switch", 13, 10, 0
halt_txt     db "System halted.", 13, 10, 0
msg_unknown  db "Bad command or file name.", 13, 10, 0
cmd_help     db "help", 0
cmd_ver      db "ver", 0
cmd_cls      db "cls", 0
cmd_echo     db "echo", 0
cmd_pm       db "pm", 0
cmd_halt     db "halt", 0
rm_ret_offset dw 0
buf          times 65 db 0

; --- GDT for PM switch (flat model) ---
ALIGN 8
gdt_data:
    gdt_entry 0, 0, 0, 0
    gdt_entry 0x10000, 0xFFFFF, ACCESS_RING0_CODE, FLAG_4K_32BIT  ; 0x08: 32-bit code, base=0x10000
    gdt_entry 0x10000, 0xFFFFF, ACCESS_RING0_DATA, FLAG_4K_32BIT  ; 0x10: 32-bit data, base=0x10000
    gdt_entry 0x10000, 0x0FFFF, ACCESS_RING0_CODE, 0x00           ; 0x18: 16-bit code, base=0x10000, limit=64KB, D=0
gdt_descriptor:
    dw      gdt_data_end - gdt_data - 1
    dd      gdt_data + 0x10000        ; linear address (segment 0x1000 << 4)
gdt_data_end:
