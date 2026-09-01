; ============================================================================
; boot32_vga.asm — 32-bit boot loader with Mode 13h setup
; Based on common/boot32.asm with mode 13h added in stage 1
; ============================================================================
BITS 16
ORG 0x7C00

%include "common/debug.inc"

PTE_KERNEL  equ 3
BOOT_SECTORS equ 2

start:
    cli
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x7C00

    mov     [boot_drive], dl

    ; === SET MODE 13h (320x200x256) in real mode ===
    mov     ah, 0
    mov     al, 0x13
    int     0x10
    ; Verify: write red pixel to top-left
    mov     ax, 0xA000
    mov     es, ax
    mov     byte [es:0x0000], 0xFF
    mov     ah, byte [es:0x0000]
    cmp     ah, 0xFF
    jne     .mode13fail
    mov     al, 'V'   ; V=mode13 verified
    out     0xE9, al
    jmp     .mode13ok
.mode13fail:
    mov     al, 'X'   ; X=mode13 failed
    out     0xE9, al
.mode13ok:

    ; --- Load Stage 2 ---
    mov     ax, 0x0000
    mov     es, ax
    mov     bx, 0x7E00
    mov     ah, 0x02
    mov     al, BOOT_SECTORS - 1
    mov     ch, 0
    mov     cl, 2
    mov     dh, 0
    mov     dl, [boot_drive]
    int     0x13
    jc      disk_err

    ; --- Load kernel to 0x0000:0x8000 ---
    mov     bx, 0x8000
    mov     ah, 0x02
    mov     al, KERNEL_SECTORS
    mov     cl, 2 + (BOOT_SECTORS - 1)
    mov     dl, [boot_drive]
    int     0x13
    jc      disk_err

    ; --- Enable A20 ---
    in      al, 0x92
    or      al, 2
    out     0x92, al

    ; --- Load GDT, enter protected mode ---
    lgdt    [gdt_descriptor]
    mov     eax, cr0
    or      eax, 1
    mov     cr0, eax
    jmp     0x08:stage2_entry

disk_err:
    hlt
    jmp     $

ALIGN 8
gdt_data:
    dd 0, 0
    dd 0x0000FFFF, 0x00CF9A00
    dd 0x0000FFFF, 0x00CF9200
gdt_descriptor:
    dw      gdt_data_end - gdt_data - 1
    dd      gdt_data
gdt_data_end:

boot_drive: db 0
KERNEL_SECTORS equ 64

times 510 - ($ - $$) db 0
dw 0xAA55

; ============================================================================
; Stage 2: 32-bit (loaded at 0x7E00)
; ============================================================================
BITS 32

stage2_entry:
    mov     ax, 0x10
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    mov     ss, ax
    mov     esp, 0x90000

    ; --- Identity paging for first 8MB ---
    mov     edi, 0x70000
    mov     ecx, 3072
    xor     eax, eax
    rep     stosd

    mov     dword [0x70000], 0x71000 | PTE_KERNEL
    mov     dword [0x70004], 0x72000 | PTE_KERNEL

    mov     edi, 0x71000
    xor     ebx, ebx
    mov     ecx, 1024
.pt0:
    mov     dword [edi], ebx
    or      dword [edi], PTE_KERNEL
    add     ebx, 4096
    add     edi, 4
    loop    .pt0

    mov     edi, 0x72000
    mov     ebx, 0x400000
    mov     ecx, 1024
.pt1:
    mov     dword [edi], ebx
    or      dword [edi], PTE_KERNEL
    add     ebx, 4096
    add     edi, 4
    loop    .pt1

    mov     eax, 0x70000
    mov     cr3, eax
    mov     eax, cr0
    or      eax, 0x80000000
    mov     cr0, eax

    ; --- Relocate kernel 0x8000 → 0x100000 ---
    mov     esi, 0x8000
    mov     edi, 0x100000
    mov     ecx, (KERNEL_SECTORS * 512) / 4
    rep     movsd

    ; --- Jump to kernel ---
    jmp     0x08:0x100000

    cli
    hlt
    jmp     $-1