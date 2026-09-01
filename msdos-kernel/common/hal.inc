; ============================================================================
; hal.inc — Hardware Abstraction Layer interface (shared by B/C/D axes)
; ----------------------------------------------------------------------------
;  Usage:  %include "common/hal.inc"
;
;  The HAL provides a thin abstraction over:
;    - Serial/debug output (hal_putc)
;    - Clock/timer (hal_clock_init, hal_get_tick)
;    - VGA text output (hal_vga_putc)
;    - System initialization (hal_init)
;
;  Each axis implements its own HAL body but keeps the same interface,
;  allowing the same kernel code to run on different "machine" configs.
;
;  In the toy kernel, HAL implementation is mostly direct port I/O since
;  QEMU provides a consistent virtual environment. The value is structural:
;  the kernel code calls hal_* symbols, not raw out/in.
; ============================================================================

; --- HAL function table (call via indirect call in 32-bit) -----------------
;  In 16-bit mode, we just use direct label calls.
;  In 32-bit, the kernel can use a function pointer table at a known address.

struc hal_table_t
    .init          resd 1    ; void hal_init(void)
    .putc          resd 1    ; void hal_putc(char al)
    .vga_putc      resd 1    ; void hal_vga_putc(char al)
    .clock_init    resd 1    ; void hal_clock_init(uint16 hz)
    .get_tick      resd 1    ; uint32 hal_get_tick(void)
    .halt          resd 1    ; void hal_halt(void)
endstruc

; --- Port addresses (QEMU PC architecture) ----------------------------------
PORT_COM1       equ 0x3F8
PORT_VGA_ATTR   equ 0x3C0
PORT_VGA_DATA   equ 0x3C8
PORT_PIT        equ 0x40
PORT_PIT_CTRL   equ 0x43
PORT_KBC        equ 0x64
PORT_E9         equ 0xE9      ; QEMU debug console

; --- I/O convenience macros (32-bit) ---------------------------------------
;  hal_outb  port, value  — write a byte to an I/O port
;  hal_inb   port         — read a byte from an I/O port (result in AL)
%macro hal_outb 2
    mov     dx, (%1)
    mov     al, (%2)
    out     dx, al
%endmacro

%macro hal_inb 1
    mov     dx, (%1)
    in      al, dx
%endmacro

%if __BITS__ == 32
; ============================================================================
; HAL implementation — 32-bit protected mode (for B/C/D axes)
; ============================================================================

; --- hal_init_pm : initialize HAL (set up COM1 if needed) -----------------
hal_init:
    ret

; --- hal_putc_pm : AL → debug port 0xE9 -----------------------------------
hal_putc:
    out     0xE9, al
    ret

; --- hal_vga_putc_pm : AL → VGA text buffer (0xB8000) ---------------------
hal_vga_putc:
    push    eax
    push    ebx
    push    edx
    push    esi

    cmp     al, 10             ; newline
    je      .newline
    cmp     al, 13             ; carriage return
    je      .ret

    movzx   ebx, word [hal_vga_cursor]
    shl     ebx, 1
    mov     byte [0xB8000 + ebx], al
    mov     byte [0xB8000 + ebx + 1], 0x07
    inc     word [hal_vga_cursor]
    jmp     .done

.newline:
    movzx   eax, word [hal_vga_cursor]
    add     eax, 80
    and     ax, 0xFFC0
    mov     [hal_vga_cursor], ax
    jmp     .done
.ret:
    movzx   eax, word [hal_vga_cursor]
    mov     bx, ax
    and     bx, 0xFFC0
    mov     [hal_vga_cursor], bx
    jmp     .done
.done:
    pop     esi
    pop     edx
    pop     ebx
    pop     eax
    ret

; --- hal_clock_init_pm : program PIT channel 0 ----------------------------
hal_clock_init:
    push    eax
    push    ecx
    push    edx
    mov     ecx, eax
    mov     edx, 1193182
    xor     eax, eax
    div     ecx
    mov     ecx, eax
    mov     al, 0x36
    out     0x43, al
    mov     al, cl
    out     0x40, al
    mov     al, ch
    out     0x40, al
    pop     edx
    pop     ecx
    pop     eax
    ret

; --- hal_get_tick_pm : return 32-bit tick counter in EAX -------------------
hal_get_tick:
    mov     eax, [hal_tick_count]
    ret

; --- hal_halt_pm : disable interrupts and halt -----------------------------
hal_halt:
    cli
    hlt
    jmp     hal_halt

; --- HAL data section (32-bit) ---------------------------------------------
hal_vga_cursor:
    dw      0
hal_tick_count:
    dd      0

%else
; ============================================================================
; HAL implementation — 16-bit real mode (for M0 / A-axis compatibility)
; ============================================================================

hal_init:
    ret

hal_putc:
    out     0xE9, al
    ret

hal_vga_putc:
    push    ax
    mov     ah, 0x0E
    xor     bx, bx
    int     0x10
    pop     ax
    ret

hal_clock_init:
    push    ax
    push    cx
    push    dx
    mov     cx, ax
    mov     al, 0x36
    out     0x43, al
    mov     ax, 0xFFFF
    out     0x40, al
    mov     al, ah
    out     0x40, al
    pop     dx
    pop     cx
    pop     ax
    ret

hal_get_tick:
    push    ds
    xor     ax, ax
    mov     ds, ax
    mov     ax, [0x046C]
    pop     ds
    ret

hal_halt:
    cli
    hlt
    jmp     hal_halt

%endif
