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
    mov     si, msg
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
    ; Build IDT (exact same as strip2)
    mov     edi, idt_table
    mov     ecx, 256 * 2
    xor     eax, eax
    rep     stosd
    ; int 0x0D
    lea     eax, [idt_default_handler]
    mov     ebx, eax
    shr     ebx, 16
    mov     ecx, 0x08
    mov     edx, 0x0E00       ; <-- EXACT same as strip2
    mov     esi, 0x0D
    call    set_idt_entry
    ; int 0x08
    mov     esi, 0x08
    call    set_idt_entry
    ; int 0x00
    mov     esi, 0x00
    call    set_idt_entry
    ; int 0x0E
    mov     esi, 0x0E
    call    set_idt_entry
    ; int 0x31
    lea     eax, [dpmi_handler]
    mov     ebx, eax
    shr     ebx, 16
    mov     ecx, 0x08
    mov     edx, 0x0E03       ; DPL=3 variant
    mov     esi, 0x31
    call    set_idt_entry
    lidt    [idt_descriptor]
    mov     esi, pm_msg
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

; EXACT same set_idt_entry as strip2
set_idt_entry:
    push    edi
    mov     edi, idt_table
    shl     esi, 3
    add     edi, esi
    mov     word [edi + 0], ax
    mov     word [edi + 2], cx
    mov     al, dl
    mov     byte [edi + 4], al
    shr     edx, 8
    mov     byte [edi + 5], dl
    mov     word [edi + 6], bx
    pop     edi
    ret

idt_default_handler:
    cli
    jmp     $

dpmi_handler:
    iret

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

msg       db "Test IDT strip2", 13, 10, 0
pm_msg    db "[PM] IDT OK", 13, 10, 0
back_msg  db "Back", 13, 10, 0

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