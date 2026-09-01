; ============================================================================
; a2_strip3.asm — M-A2: 加 TSS + IRET ring3 测试
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
    call    enter_pm
after_pm_ret:
    mov     si, back_msg
    call    puts
    hlt

enter_pm:
    cli
    lgdt    [gdt_descriptor]
    in      al, 0x92
    or      al, 2
    out     0x92, al
    mov     eax, cr0
    or      eax, 1
    mov     cr0, eax
    jmp     0x08:pm32_entry

BITS 32
pm32_entry:
    mov     ax, 0x10
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    mov     ss, ax
    mov     esp, 0x20000

    ; Build IDT
    call    build_idt
    lidt    [idt_descriptor]

    ; Setup TSS
    call    setup_tss

    ; Set ring3 stack pointer
    mov     eax, ring3_stack_top
    mov     [ring3_stack_ptr], eax

    ; Print PM banner
    mov     esi, pm_msg
    call    dbg32_puts

    ; Enter ring3 via IRET
    mov     eax, [ring3_stack_ptr]
    push    0x23              ; SS = SEL_DATA3 | 3
    push    eax               ; ESP
    pushfd
    or      dword [esp], 0x3200 ; IF + IOPL=3
    push    0x1B              ; CS = SEL_CODE3 | 3
    push    ring3_entry       ; EIP
    iret

ring3_entry:
    mov     esi, r3_msg
    call    dbg32_puts
    ; Signal done
    mov     eax, 0xFF00
    int     0x31
    ; Should not reach here
    cli
    hlt

ring0_after_dpmi:
    mov     esi, r0_msg
    call    dbg32_puts
    jmp     0x28:rm_16

BITS 16
rm_16:
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

; ============ TSS setup ============
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
    mov     edi, idt_table
    mov     ecx, 256 * 2
    xor     eax, eax
    rep     stosd
    ; int 0x0D, 0x08, 0x00, 0x0E: default, DPL=0
    lea     eax, [idt_default_handler]
    mov     ebx, eax
    shr     ebx, 16
    mov     ecx, 0x08
    mov     edx, 0x8E       ; DPL=0 interrupt gate
    mov     esi, 0x0D
    call    set_idt_entry
    mov     esi, 0x08
    call    set_idt_entry
    mov     esi, 0x00
    call    set_idt_entry
    mov     esi, 0x0E
    call    set_idt_entry
    ; int 0x31: DPMI handler, DPL=3
    lea     eax, [dpmi_handler]
    mov     ebx, eax
    shr     ebx, 16
    mov     ecx, 0x08
    mov     edx, 0xEE       ; DPL=3 interrupt gate
    mov     esi, 0x31
    call    set_idt_entry
    ret

set_idt_entry:
    push    edi
    mov     edi, idt_table
    shl     esi, 3
    add     edi, esi
    mov     word [edi + 0], ax
    mov     word [edi + 2], cx
    mov     byte [edi + 4], dl
    shr     edx, 8
    mov     byte [edi + 5], dl
    mov     word [edi + 6], bx
    pop     edi
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

; ============ Debug output ============
dbg32_puts:
    push    esi
.l: lodsb
    or      al, al
    jz      .d
    out     0xE9, al
    jmp     .l
.d: pop     esi
    ret

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

; ============ Data ============
banner       db "M-A2 strip3 test", 13, 10, 0
pm_msg       db "[PM] PM setup OK, entering ring3...", 13, 10, 0
r3_msg       db "[R3] Entered ring3!", 13, 10, 0
r0_msg       db "[R0] Back in ring0!", 13, 10, 0
back_msg     db "Back in RM", 13, 10, 0

ring3_stack_ptr dd 0
ring3_stack    times 512 db 0
ring3_stack_top equ $ - 4

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
gdt_descriptor:
    dw      gdt_data_end - gdt_data - 1
    dd      gdt_data + 0x10000
gdt_data_end:

ALIGN 8
idt_table:
    times 256*8 db 0
idt_descriptor:
    dw      256 * 8 - 1
    dd      idt_table + 0x10000

; ============ TSS ============
ALIGN 8
tss:
    dd 0            ; link
    dd 0            ; esp0  (runtime)
    dd 0            ; ss0   (runtime)
    dd 0, 0, 0, 0   ; esp1, ss1, esp2, ss2
    times 76 db 0