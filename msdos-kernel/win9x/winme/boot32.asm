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

    ; --- Load kernel (sectors after boot32) to physical address 0x8000 ---
    ; Reads KERNEL_SECTORS in chunks of max 16 sectors per int 0x13 call.
    ; This avoids:
    ;   (a) BIOS al-register 63-sector limit (some BIOSes refuse al > 63)
    ;   (b) Floppy CHS head/track wrap inside a single call
    ; Physical destination is 0x8000.  We recompute ES:BX from SI (sector index)
    ; each iteration: linear = 0x8000 + si*512; ES = linear/16; BX = linear%16.
    ; This is trivially correct for any size and never crosses a 64KB boundary
    ; because BX is always 0 (sectors are 512-byte aligned, 512/16=32, ES
    ; increments by 0x20 per sector).  No segment-boundary bugs possible.
    ; Kernel start LBA = 2 (boot sector = LBA 0, stage2 = LBA 1, both within
    ; BOOT_SECTORS = 2).
    xor     si, si                  ; si = current LBA offset from kernel_start
.kr_loop:
    cmp     si, KERNEL_SECTORS      ; all sectors loaded?
    jae     .kr_done
    ; --- Compute ES:BX destination for this chunk ---
    ; linear = 0x8000 + si * 512
    ; ES = linear >> 4, BX = 0 (512 is divisible by 16, so offset within
    ; segment is always 0 when starting from a 512-byte boundary at 0x8000
    ; which is itself 16-byte aligned).
    ; Actually: 0x8000/16 = 0x0800 (segment). si*512/16 = si*32 (offset).
    ; So ES = 0x0800 + si*32, BX = 0.  This keeps BX=0 always — no overflow.
    mov     ax, si
    shl     ax, 5                   ; ax = si * 32 = (si * 512) / 16
    add     ax, 0x0800              ; ax = 0x0800 + si*32 = segment
    mov     es, ax
    xor     bx, bx                  ; BX = 0 (512-aligned, always 0 offset)
.kr_check_chunk:
    ; Chunk size = min(16, remaining)
    mov     cx, KERNEL_SECTORS
    sub     cx, si                  ; cx = remaining
    cmp     cx, 16
    jbe     .kr_chunk
    mov     cx, 16                  ; cap at 16 sectors per call (safe for floppy)
.kr_chunk:
    ; Compute start LBA of this chunk
    mov     ax, 2                   ; kernel starts at LBA 2
    add     ax, si                  ; ax = start LBA for this chunk
    ; Convert LBA in AX to CHS for 1.44MB floppy (18 sectors/track, 2 heads, 80 cyls)
    ;   sector = (LBA % 18) + 1   -> CL bits 0-5
    ;   tmp    = LBA / 18
    ;   head   = tmp % 2          -> DH
    ;   cyl    = tmp / 2          -> CH + CL bits 7-6 (0 for cyl < 64)
    push    cx                      ; save chunk size
    push    bx                      ; save BX destination
    mov     bl, 18
    div     bl                      ; al = LBA/18, ah = LBA%18
    mov     cl, ah
    inc     cl                      ; CL = (LBA%18)+1 (sector number 1-18)
    xor     ah, ah
    mov     bl, 2
    div     bl                      ; al = (LBA/18)/2 = cyl, ah = (LBA/18)%2 = head
    mov     ch, al                  ; CH = cyl
    mov     dh, ah                  ; DH = head
    pop     bx                      ; restore BX
    pop     ax                      ; restore chunk size -> AL (AH was 0 from xor)
    ; int 0x13 ah=02: read sectors
    ;   es:bx already set, CX/DX set above, AL = chunk count
    mov     ah, 0x02
    mov     dl, [boot_drive]
    int     0x13
    jc      disk_err
    ; Advance sector counter: si += sectors_read (BX is always 0, ES recomputed)
    mov     cl, al                  ; save AL chunk count
    xor     ah, ah                  ; ax = chunk count
    add     si, ax                  ; si += sectors_read
    jmp     .kr_loop
.kr_done:

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
KERNEL_SECTORS equ 512     ; ~261KB max kernel (was 288=147KB, raised for larger kernels)
BOOT_SECTORS equ 2           ; boot32.bin fits in 2 sectors (512B stage1 + ~387B stage2)

; --- Boot sector signature (must be at offset 510) ---
times 510 - ($ - $$) db 0
dw 0xAA55

; ============================================================================
; Stage 2: 32-bit code (loaded at 0x7E00 by stage 1, executed after PM switch)
; ============================================================================
BITS 32

stage2_entry:
    cld
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
    mov     al, 'p'
    out     0xE9, al

    mov     dword [0x70000], 0x71000 | PTE_KERNEL
    mov     dword [0x70004], 0x72000 | PTE_KERNEL
    mov     al, 'q'
    out     0xE9, al

; PT0: identity-map first 4MB (linear 0x0-0x3FFFFF → physical 0x0-0x3FFFFF)
    ;   Covers stage2 at 0x7E00, kernel pre-relocate at 0x8000, and kernel
    ;   post-relocate at 0x100000. No remap: a4_gui.asm is assembled ORG 0x100000,
    ;   so its labels (gdt_data=0x108D78, idt_table=0x108DA0, exe_code=0x105B46,
    ;   tcp_dst_ip=0x108700, ...) already resolve to 0x100000-based linear
    ;   addresses that match identity paging. Remapping low pages to 0x100000
    ;   would redirect stage2's own code (0x7E00) to empty memory and crash on PG enable.
    mov     edi, 0x71000
    mov     ebx, 0
    mov     ecx, 1024
.pt0:
    mov     dword [edi], ebx
    or      dword [edi], PTE_KERNEL
    add     ebx, 4096
    add     edi, 4
    loop    .pt0
    mov     al, 'r'
    out     0xE9, al

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
    mov     al, 's'
    out     0xE9, al

    mov     eax, 0x70000
    mov     cr3, eax
    mov     al, 't'
    out     0xE9, al

    mov     eax, cr0
    or      eax, 0x80000000
    mov     cr0, eax
    mov     al, 'u'
    out     0xE9, al

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
