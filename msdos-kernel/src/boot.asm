; ============================================================================
; boot.asm — MS-DOS Kernel : Stage-1 bootloader (16-bit real mode)
; ----------------------------------------------------------------------------
;  Loader for a toy MS-DOS-style kernel.
;  * Origin  : 0x7C00 (loaded by BIOS at the start of the floppy)
;  * Job     : print a banner, read the kernel image from floppy sector 2
;              into 0x1000:0x0000, then far-jump into it.
;  * Output  : a 512-byte boot sector terminated by the 0x55AA signature.
;  Assemble : nasm -f bin src/boot.asm -o build/boot.bin
; ============================================================================
BITS 16
ORG 0x7C00

start:
    cli
    xor     ax, ax
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x7C00
    sti

    mov     si, msg_boot
    call    puts

    ; ---- load the kernel from floppy (BIOS int 0x13, function 0x02) ----
    ; ES:BX = destination buffer = 0x1000:0x0000
    mov     ax, 0x1000
    mov     es, ax
    xor     bx, bx

    mov     ah, 0x02          ; read sectors
    mov     al, KERNEL_SECTORS
    mov     ch, 0             ; cylinder 0
    mov     cl, 2             ; start sector (1-based); sector 1 is this boot
    mov     dh, 0             ; head 0
    mov     dl, 0x00          ; drive 0 = first floppy
    int     0x13
    jc      disk_err

    mov     si, msg_ok
    call    puts

    ; far jump into the loaded kernel
    jmp     0x1000:0x0000

; ----------------------------------------------------------------------------
; puts : print NUL-terminated string at DS:SI via BIOS teletype (int 0x10)
; ----------------------------------------------------------------------------
puts:
    lodsb
    or      al, al
    jz      .done
    mov     ah, 0x0E
    xor     bx, bx
    int     0x10
    jmp     puts
.done:
    ret

disk_err:
    mov     si, msg_err
    call    puts
    hlt

msg_boot db "MS-DOS Kernel bootloader v0.1 ...", 13, 10, 0
msg_ok   db "kernel loaded.", 13, 10, 0
msg_err  db "disk read error!", 13, 10, 0

KERNEL_SECTORS equ 16

; pad to 510 bytes and emit the boot signature
times 510 - ($ - $$) db 0
dw 0xAA55
