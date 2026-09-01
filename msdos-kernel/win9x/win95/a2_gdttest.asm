; Minimal test: does the full M-A2 code work with strip2's GDT (no ring3)?
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
    mov     esi, pm_msg
    call    dbg32_puts
    jmp     0x18:rm_16

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

banner       db "Test", 13, 10, 0
pm_msg       db "[PM] OK", 13, 10, 0
back_msg     db "Back", 13, 10, 0

; Test with MORE entries (like M-A2 full)
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