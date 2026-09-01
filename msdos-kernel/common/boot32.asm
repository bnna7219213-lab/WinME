; ============================================================================
; boot32.asm — Generic 32-bit protected-mode bootloader (2-sector)
; ----------------------------------------------------------------------------
;  Sector 1 (512B): 16-bit real-mode loader
;    - Reads sectors 2..N from disk to 0x0000:0x7E00 (right after boot sector)
;    - Enables A20, loads GDT, sets CR0.PE, far-jumps to Stage 2
;  Sector 2+ (Stage 2): 32-bit code + data
;    - Sets up segment registers, identity paging, relocates kernel to 1MB
;    - Far-jumps to kernel entry at 0x00100000
;
;  Image layout (pack32.ps1):
;    Offset 0       : boot32.bin (this file, 2+ sectors)
;    Offset boot32  : kernel32.bin
;
;  Assemble: nasm -f bin common/boot32.asm -o build/boot32.bin
; ============================================================================

BITS 16
ORG 0x7C00

%include "common/debug.inc"

; --- Constants ---
PTE_KERNEL  equ 3           ; Present | R/W
BOOT_SECTORS equ 2          ; sectors for boot32 (512B stage1 + 512B stage2)

; ============================================================================
; Stage 1: 512-byte boot sector (real mode)
; ============================================================================
start:
    cli
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x7C00

    mov     [boot_drive], dl

    dbg_puts "boot32: stage1", 13, 10, 0

    ; --- Load Stage 2 (sectors 2..N) to 0x0000:0x7E00 ---
    mov     ax, 0x0000
    mov     es, ax
    mov     bx, 0x7E00

    mov     ah, 0x02
    mov     al, BOOT_SECTORS - 1     ; sectors after boot sector
    mov     ch, 0
    mov     cl, 2
    mov     dh, 0
    mov     dl, [boot_drive]
    int     0x13
    jc      disk_err

    ; --- Load kernel (sectors after boot32) to 0x0000:0x8000 ---
    ; KERNEL_SECTORS is defined at the bottom; we load after boot32's sectors
    mov     bx, 0x8000
    mov     ah, 0x02
    mov     al, KERNEL_SECTORS
    mov     cl, 2 + (BOOT_SECTORS - 1)   ; skip boot32 sectors
    mov     dl, [boot_drive]
    int     0x13
    jc      disk_err

    ; --- Optional BIOS video mode (must happen while still in real mode) ---
    ;  Assemble with e.g. -DVIDEO_MODE=0x0013 to hand the kernel a linear
    ;  320x200x256 framebuffer at 0xA0000.  Undefined => text mode, so every
    ;  existing B/C/D image keeps its current behaviour byte-for-byte.
%ifdef VIDEO_MODE
    mov     ax, VIDEO_MODE
    int     0x10
    dbg_puts "boot32: video mode set", 13, 10, 0
%endif

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
    dbg_puts "disk err!", 13, 10, 0
    hlt
    jmp     $

; --- Compact GDT (must be within 512 bytes) ---
ALIGN 8
gdt_data:
    dd 0, 0                            ; null
    dd 0x0000FFFF, 0x00CF9A00          ; ring0 code (flat 4GB)
    dd 0x0000FFFF, 0x00CF9200          ; ring0 data (flat 4GB)
gdt_descriptor:
    dw      gdt_data_end - gdt_data - 1
    dd      gdt_data
gdt_data_end:

boot_drive: db 0
KERNEL_SECTORS equ 64      ; 32KB max kernel image

; --- Boot sector signature (must be at offset 510) ---
times 510 - ($ - $$) db 0
dw 0xAA55

; ============================================================================
; Stage 2: 32-bit code (loaded at 0x7E00 by stage 1, executed after PM switch)
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

    dbg_puts "boot32: PM ON", 13, 10, 0

    ; --- Identity paging for first 8MB ---
    ; PD at 0x70000, PT0 at 0x71000, PT1 at 0x72000
    mov     edi, 0x70000
    mov     ecx, 3072
    xor     eax, eax
    rep     stosd

    mov     dword [0x70000], 0x71000 | PTE_KERNEL
    mov     dword [0x70004], 0x72000 | PTE_KERNEL

    ; PT0: identity 0x000000-0x3FFFFF
    mov     edi, 0x71000
    xor     ebx, ebx
    mov     ecx, 1024
.pt0:
    mov     dword [edi], ebx
    or      dword [edi], PTE_KERNEL
    add     ebx, 4096
    add     edi, 4
    loop    .pt0

    ; PT1: identity 0x400000-0x7FFFFF
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

    dbg_puts "boot32: paging ON", 13, 10, 0

    ; --- Relocate kernel 0x8000 → 0x100000 ---
    mov     esi, 0x8000
    mov     edi, 0x100000
    mov     ecx, (KERNEL_SECTORS * 512) / 4
    rep     movsd

    dbg_puts "boot32: kernel at 1MB", 13, 10, 0

    ; --- DEBUG: dump first 4 bytes at 0x100000 ---
    dbg_puts "kernel[0..3]=", 0
    mov     eax, [0x100000]
    call    dbg_dump32
    dbg_nl

    ; --- Jump to kernel ---
    jmp     0x08:0x100000

    cli
    hlt
    jmp     $-1

; --- dbg_dump32 : print EAX as 8 hex digits to 0xE9 ---
dbg_dump32:
    push    eax
    push    ebx
    push    ecx
    mov     ebx, eax
    mov     ecx, 28
.ddl:
    mov     eax, ebx
    shr     eax, cl
    and     eax, 0x0F
    add     al, '0'
    cmp     al, '9'
    jbe     .ddok
    add     al, 7
.ddok:
    out     0xE9, al
    sub     ecx, 4
    jns     .ddl
    pop     ecx
    pop     ebx
    pop     eax
    ret
