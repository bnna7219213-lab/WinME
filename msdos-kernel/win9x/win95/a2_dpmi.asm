; ============================================================================
; a2_dpmi.asm ??? M-A2: DPMI ring3 round-trip (fixed)
; ============================================================================
BITS 16
ORG 0x0000

%include "common/debug.inc"
%include "common/gdt.inc"

start:
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x9000
    mov     si, banner
    call    puts
    mov     si, auto_msg
    call    puts
    call    enter_pm

after_pm_ret:
    mov     si, back_msg
    call    puts
.cmdloop:
    mov     si, prompt
    call    puts
    call    readline
    call    dispatch
    jmp     .cmdloop

enter_pm:
    cli
    ; FIX: DS must point to kernel base (0x10000) so lgdt reads the correct descriptor
    mov ax, 0x1000
    mov ds, ax
    lgdt    [gdt_descriptor]
    mov al, 'L'
    out 0xE9, al        ; DBG: lgdt done
    in      al, 0x92
    or      al, 2
    out     0x92, al
    mov     eax, cr0
    or      eax, 1
    mov al, 'C'
    out 0xE9, al        ; DBG: about to set CR0
    mov     cr0, eax
    jmp     0x08:pm32_entry

BITS 32
pm32_entry:
    mov al, 'P'
    out 0xE9, al        ; DBG: PM entry reached
    mov     ax, 0x10
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    mov     ss, ax
    mov     esp, 0x20000
    mov al, 'S'
    out 0xE9, al        ; DBG: segments set

    ; Build IDT
    call    build_idt
    mov al, 'I'
    out 0xE9, al        ; DBG: build_idt done
    lidt    [idt_descriptor]
    mov al, 'D'
    out 0xE9, al        ; DBG: lidt done

    ; Setup TSS
    call    setup_tss
    mov al, 'T'
    out 0xE9, al        ; DBG: setup_tss done

    ; Set ring3 stack pointer
    mov     eax, ring3_stack_top
    mov     [ring3_stack_ptr], eax

    ; Print PM banner
    mov     esi, pm_banner
    call    dbg32_puts

    ; --- Enter ring3 via IRET ---
    mov     eax, [ring3_stack_ptr]
    push    0x23              ; SS = SEL_DATA3 | 3
    push    eax               ; ESP
    pushfd
    or      dword [esp], 0x3200 ; IF + IOPL=3
    push    0x1B              ; CS = SEL_CODE3 | 3
    push    ring3_entry       ; EIP
    iret

; --- ring3 code (CPL=3) ---
ring3_entry:
    mov     cx, 0x23
    mov     ds, cx
    mov     es, cx
    mov     fs, cx
    mov     gs, cx
    mov     ss, cx
    mov     eax, [ring3_stack_ptr]
    mov     esp, eax

    mov     esi, r3_entered_msg
    call    dbg32_puts

    ; DPMI call: get version
    xor     eax, eax
    int     0x31
    mov     [dpmi_version], ax

    mov     esi, ver_label
    call    dbg32_puts
    movzx   eax, word [dpmi_version]    ; dpmi_version is a word; zero-extend
    call    dbg32_hex32
    mov     esi, nl
    call    dbg32_puts

    ; Write shared buffer
    mov     esi, hello_pm_msg
    mov     edi, dpmi_buf
    mov     ecx, 9
    rep     movsb

    mov     esi, write_msg
    call    dbg32_puts

    ; Signal done
    mov     eax, 0xFF00
    int     0x31
    cli
    hlt

; --- ring0 continuation (from ah=0xFF handler) ---
ring0_after_dpmi:
    mov     esi, r0_back_msg
    call    dbg32_puts

    ; Verify buffer
    mov     esi, buf_label
    call    dbg32_puts
    mov     esi, dpmi_buf
    call    dbg32_print_cstr

    mov     esi, dpmi_buf
    mov     edi, hello_pm_verify
    mov     ecx, 8
    repe    cmpsb
    je      .ok
    mov     esi, fail_msg
    call    dbg32_puts
    jmp     .after
.ok:
    mov     esi, ok_msg
    call    dbg32_puts
.after:
    cli
    ; Reload the real-mode IVT descriptor before leaving PM, otherwise the
    ; first interrupt after 'sti' would be dispatched through the PM IDT.
    lidt    [rm_idt_descriptor]
    ; Enter a 16-bit code segment so CS gets a 16-bit descriptor cached.
    jmp     0x28:rm_16

BITS 16
rm_16:
    ; Load a 16-bit data descriptor into every data segment BEFORE clearing PE,
    ; so their cached limits/attributes are real-mode compatible.
    mov     ax, 0x38
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    mov     ss, ax
    mov     eax, cr0
    and     eax, 0xFFFFFFFE
    mov     cr0, eax
    jmp     0x1000:rm_back

BITS 16
rm_back:
    mov     ax, 0x1000
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x9000
    sti
    jmp     after_pm_ret

BITS 32
; ============ TSS ============
setup_tss:
    mov     eax, tss
    add     eax, 0x10000
    mov     edi, gdt_data + 6*8
    mov     word [edi + 0], 103
    mov     word [edi + 2], ax
    shr     eax, 16
    mov     byte [edi + 4], al
    mov     byte [edi + 5], 0x89
    mov     byte [edi + 6], 0
    mov     byte [edi + 7], ah
    ; TSS fields
    mov     eax, ring0_stack_top
    add     eax, 0x10000
    mov     [tss + 4], eax
    mov     word [tss + 8], 0x10
    ; Load TR
    mov     ax, 0x30
    ltr     ax
    ret

ring0_stack     times 512 db 0
ring0_stack_top equ $ - 4

; ============ IDT ============
build_idt:
    ; Zero the whole IDT
    mov     edi, idt_table
    mov     ecx, 256 * 2
    xor     eax, eax
    rep     stosd
    ; Default handlers (DPL=0)
    ; NOTE: EAX holds the handler offset for set_idt_entry; never clobber AL
    ; (e.g. with a debug 'out 0xE9' marker) between here and the call.
    mov     eax, idt_default_handler
    mov     ebx, eax
    shr     ebx, 16
    mov     ecx, 0x08
    mov     edx, 0x8E       ; P=1, DPL=0, 32-bit interrupt gate
    mov     esi, 0x0D
    call    set_idt_entry
    mov     esi, 0x08
    call    set_idt_entry
    mov     esi, 0x00
    call    set_idt_entry
    mov     esi, 0x0E
    call    set_idt_entry
    ; int 0x31 (DPMI, DPL=3)
    mov     eax, dpmi_handler
    mov     ebx, eax
    shr     ebx, 16
    mov     ecx, 0x08
    mov     edx, 0xEE       ; DPL=3, interrupt gate
    mov     esi, 0x31
    call    set_idt_entry
    ret

set_idt_entry:
    ; EAX = handler 32-bit offset, EBX = handler>>16, ECX = selector,
    ; DL  = access byte (P|DPL|type), ESI = interrupt vector.
    ;
    ; 32-bit interrupt/trap gate layout:
    ;   +0 word  offset[15:0]
    ;   +2 word  selector
    ;   +4 byte  reserved (must be 0)
    ;   +5 byte  access byte (P | DPL | type)
    ;   +6 word  offset[31:16]
    push    eax
    push    esi
    mov     edi, idt_table
    shl     esi, 3
    add     edi, esi
    pop     esi
    pop     eax
    mov     word [edi + 0], ax      ; offset low
    mov     word [edi + 2], cx      ; selector
    mov     byte [edi + 4], 0       ; reserved
    mov     byte [edi + 5], dl      ; access byte (P|DPL|type)
    mov     word [edi + 6], bx      ; offset high
    ret

idt_default_handler:
    cli
    jmp     $

dpmi_handler:
    cmp     ah, 0x00
    je      .get_version
    cmp     ah, 0xFF
    je      .signal_done
    mov     eax, 0xFFFF
    iret
.get_version:
    mov     eax, 0x0103
    iret
.signal_done:
    jmp     ring0_after_dpmi

; ============ Debug ============
dbg32_puts:
    push    esi
.l: lodsb
    or      al, al
    jz      .d
    out     0xE9, al
    jmp     .l
.d: pop     esi
    ret

dbg32_hex32:
    push    ebx
    push    ecx
    mov     ecx, 8
    mov     ebx, eax
.l: mov     eax, ebx
    shr     eax, 28
    and     eax, 0x0F
    add     al, '0'
    cmp     al, '9'
    jbe     .h
    add     al, 7
.h: out     0xE9, al
    shl     ebx, 4
    dec     ecx
    jnz     .l
    pop     ecx
    pop     ebx
    ret

dbg32_print_cstr:
    push    esi
.l: lodsb
    or      al, al
    jz      .d
    out     0xE9, al
    jmp     .l
.d: pop     esi
    ret

; ============ 16-bit helpers ============
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
.l: mov     ah, 0x00
    int     0x16
    cmp     al, 0x0D
    je      .done
    cmp     al, 0x08
    je      .bs
    cmp     si, buf+64
    jae     .l
    mov     [si], al
    inc     si
    mov     ah, 0x0E
    xor     bx, bx
    int     0x10
    jmp     .l
.bs:cmp     si, buf
    je      .l
    dec     si
    mov     ah, 0x0E
    mov     al, 0x08
    int     0x10
    mov     al, ' '
    int     0x10
    mov     al, 0x08
    int     0x10
    jmp     .l
.done:
    mov     byte [si], 0
    ret

dispatch:
    mov     si, buf
    mov     di, cmd_help
    call    cmd_match
    jc      .help
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
.halt:
    cli
    hlt

cmd_match:
    push    si
    push    di
.l: mov     al, [di]
    or      al, al
    jz      .end
    cmp     al, [si]
    jne     .no
    inc     si
    inc     di
    jmp     .l
.end:
    mov     al, [si]
    cmp     al, 0x20
    je      .yes
    or      al, al
    jz      .yes
.no:pop     di
    pop     si
    clc
    ret
.yes:
    pop     di
    pop     si
    stc
    ret

; ============ Data ============
banner       db "Win9x Axis ??? M-A2 (DPMI demo)", 13, 10, 0
auto_msg     db "[AUTO] DPMI round-trip demo...", 13, 10, 0
pm_banner    db "[M-A2] PM ON ??? ring3 via IRET+TSS", 13, 10, 0
r3_entered_msg db "[M-A2] <<< ENTERED RING3 (CPL=3) >>>", 13, 10, 0
ver_label    db "[M-A2] DPMI version: 0x", 0
nl           db 13, 10, 0
write_msg    db "[M-A2] ring3 wrote buffer, signaling done...", 13, 10, 0
r0_back_msg  db "[M-A2] <<< BACK IN RING0 (CPL=0) >>>", 13, 10, 0
buf_label    db "[M-A2] buffer: '", 0
ok_msg       db "', match OK ??? round-trip VERIFIED", 13, 10, 0
fail_msg     db "', MISMATCH!", 13, 10, 0
back_msg     db "BACK IN REAL MODE ??? DPMI complete", 13, 10, 0
prompt       db "C:\>", 0
help_txt     db "commands: help, halt", 13, 10, 0
msg_unknown  db "?", 13, 10, 0
cmd_help     db "help", 0
cmd_halt     db "halt", 0

hello_pm_msg   db "HELLO PM", 0
hello_pm_verify db "HELLO PM", 0
dpmi_version   dw 0
ring3_stack_ptr dd 0
dpmi_buf       times 128 db 0
ring3_stack    times 512 db 0
ring3_stack_top equ $ - 4
buf            times 65 db 0

; ============ GDT ============
ALIGN 8
gdt_data:
    gdt_entry 0, 0, 0, 0                                    ; 0x00 null
    gdt_entry 0x10000, 0xFFFFF, ACCESS_RING0_CODE, FLAG_4K_32BIT  ; 0x08 ring0 code
    gdt_entry 0x10000, 0xFFFFF, ACCESS_RING0_DATA, FLAG_4K_32BIT  ; 0x10 ring0 data
    gdt_entry 0x10000, 0xFFFFF, ACCESS_RING3_CODE, FLAG_4K_32BIT  ; 0x18 ring3 code
    gdt_entry 0x10000, 0xFFFFF, ACCESS_RING3_DATA, FLAG_4K_32BIT  ; 0x20 ring3 data
    gdt_entry 0x10000, 0x0FFFF, ACCESS_RING0_CODE, 0x00           ; 0x28 16-bit code
    gdt_entry 0, 0, 0, 0                                    ; 0x30 TSS placeholder
    gdt_entry 0x10000, 0x0FFFF, ACCESS_RING0_DATA, 0x00           ; 0x38 16-bit data
gdt_descriptor:
    dw      gdt_data_end - gdt_data - 1
    dd      gdt_data + 0x10000
gdt_data_end:

ALIGN 8
tss:
    dd 0, 0, 0, 0, 0, 0, 0
    times 76 db 0

; IDT at the very end (rep stosd won't overlap GDT/TSS)
ALIGN 8
idt_table:
    times 256*8 db 0
idt_descriptor:
    dw      256 * 8 - 1
    dd      idt_table + 0x10000

; Real-mode IVT pseudo-descriptor (base 0, limit 0x3FF), used when leaving PM
rm_idt_descriptor:
    dw      0x3FF
    dd      0