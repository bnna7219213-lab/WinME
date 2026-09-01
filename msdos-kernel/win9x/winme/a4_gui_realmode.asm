; ============================================================================
; a4_gui.asm - M-A4: VDD (Virtual Display Device) + Win9x-style GUI
; ----------------------------------------------------------------------------
;  Tribute to Windows 9x's display driver model:
;    - VDD      : Virtual Display Device (a VxD that owns the framebuffer)
;    - mode 13h : 320x200x256 planar->chunky VGA graphics mode
;    - VMM/VTD  : the GUI "System VM" is driven by the VTD timer interrupt
;                 (cursor blink + clock = the animation)
;
;  Built on the A3-verified path: src/boot.asm loads this kernel to 0x1000:0
;  (physical 0x10000) as a 16-bit real-mode image (ORG 0). The real-mode stub
;  sets VGA mode 13h + programs the DAC palette, then we flip to protected mode
;  with a flat GDT and draw through the VDD primitives into 0xA0000.
;
;  VDD primitives implemented here:
;    vdd_pixel, vdd_fill (rect), vdd_frame3d (bevel), vdd_char, vdd_text (8x8)
;    Plus a framebuffer self-check (read-back) and a serial PPM dump.
; ============================================================================
BITS 16
ORG 0x0000

%include "common/debug.inc"
%include "common/gdt.inc"

KBASE           equ 0x10000     ; physical load address of this kernel

; --- selectors (GDT built below) ---
SEL_CODE0       equ 0x08        ; flat code,  base=KBASE
SEL_DATA0       equ 0x10        ; flat data,  base=KBASE
SEL_VGA         equ 0x18        ; flat data,  base=0      (framebuffer)
SEL_CODE16      equ 0x20        ; 16-bit code, base=KBASE
SEL_DATA16      equ 0x30        ; 16-bit data, base=KBASE

; --- VGA / mode 13h ---
SCREEN_W        equ 320
SCREEN_H        equ 200
VGA_FB          equ 0xA0000

; ============================================================================
; Real-mode stub
; ============================================================================
start:
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x9000

    dbg_puts "M-A4 Win9x VDD + GUI (boot.asm path)", 13, 10, 0

    ; --- set VGA mode 13h (320x200, 256 colors, chunky) ---
    mov     ax, 0x0013
    int     0x10
    dbg_puts "[A4] VGA mode 13h (320x200x256) set", 13, 10, 0

    ; --- program the DAC palette with Win9x-ish colors ---
    call    palette_init
    dbg_puts "[A4] DAC palette programmed (Win9x colors)", 13, 10, 0

    ; --- probe: write a pixel to the framebuffer in real mode + read it back ---
    mov     ax, 0xA000
    mov     es, ax
    mov     byte [es:0], 0x0F
    mov     al, [es:0]
    cmp     al, 0x0F
    je      .fbok
    dbg_puts "[A4] FB probe FAIL (0xA0000 not r/w in RM)", 13, 10, 0
    jmp     .fbcont
.fbok:
    dbg_puts "[A4] FB probe ok (0xA0000 r/w in RM)", 13, 10, 0
.fbcont:

    call    enter_pm

.halt:
    cli
    hlt
    jmp     .halt

; ----------------------------------------------------------------------------
; palette_init - 6-bit VGA DAC values (index auto-increments after 3 writes)
;   idx 0 black   1 teal(desktop)  2 gray(taskbar/button)  3 navy(title)
;   4 shadow(dark bevel)  5 white(client/text)  6 yellow(cursor)
; ----------------------------------------------------------------------------
;   NOTE: this MUST be a table + loop.  Writing the triplets as
;   "mov al,0; out dx,al; out dx,al" on one source line silently degrades to a
;   NASM comment (';' starts a comment) and no DAC byte is ever emitted, which
;   leaves mode 13h on the default VGA palette.
palette_init:
    mov     dx, 0x3C8
    xor     al, al
    out     dx, al                  ; start at DAC index 0
    mov     dx, 0x3C9
    mov     si, pal_data
    mov     cx, PAL_ENTRIES * 3
.l:
    lodsb
    out     dx, al                  ; R/G/B, index auto-increments every 3 writes
    loop    .l
    ret

PAL_ENTRIES     equ 7
pal_data:
    db  0,  0,  0       ; 0 black          (button/clock text)
    db  0, 32, 32       ; 1 teal           (desktop background)
    db 48, 48, 48       ; 2 light gray     (taskbar / button face)
    db  0,  0, 32       ; 3 navy           (title bar)
    db 32, 32, 32       ; 4 dark gray      (3D shadow edge)
    db 63, 63, 63       ; 5 white          (client area / title text)
    db 63, 63,  0       ; 6 yellow         (blinking cursor)

; ----------------------------------------------------------------------------
; enter_pm - switch to 32-bit protected mode (flat GDT, base=KBASE)
; ----------------------------------------------------------------------------
enter_pm:
    cli
    ; DS must point at the kernel base so lgdt reads the right descriptor
    mov     ax, KBASE >> 4
    mov     ds, ax
    lgdt    [gdt_descriptor]
    in      al, 0x92
    or      al, 2
    out     0x92, al
    mov     eax, cr0
    or      eax, 1
    mov     cr0, eax
    jmp     SEL_CODE0:pm32_entry

; ============================================================================
; 32-bit protected mode
; ============================================================================
BITS 32
pm32_entry:
    mov     ax, SEL_DATA0
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     ss, ax
    mov     ax, SEL_VGA
    mov     gs, ax
    mov     esp, 0x20000

    ; --- PM byte-test: is [gs:0] (physical 0xA0000) writable/readback? ---
    mov     byte [gs:0], 0x0F
    mov     al, [gs:0]
    cmp     al, 0x0F
    je      .gsok
    dbg_puts "[A4] PM gs@0xA0000 byte-test FAIL", 13, 10, 0
    jmp     .gscont
.gsok:
    dbg_puts "[A4] PM gs@0xA0000 byte-test ok", 13, 10, 0
.gscont:

    dbg_puts "[A4] protected mode ON - VDD drawing", 13, 10, 0

    call    build_idt
    lidt    [idt_descriptor]

    ; --- draw the Win9x desktop ---
    call    draw_desktop

    ; --- draw the cursor in its initial (visible) state ---
    mov     dword [cursor_on], 1
    call    draw_cursor

    ; --- self-check: read back key pixels from the framebuffer ---
    call    vdd_verify

    ; --- screenshot is captured by the test harness via QEMU monitor screendump ---

    ; --- hand control to the VMM; the VTD timer drives the animation ---
    call    vmm_init
    call    vtd_init
    dbg_puts "[A4] VMM + VTD armed - GUI animation loop", 13, 10, 0
    call    vmm_start
    ; does not return

; ============================================================================
; VDD - Virtual Display Device primitives
;   framebuffer addressed via GS (selector SEL_VGA, base 0) -> [gs:offset]
;   drawing parameters live in the vdd_* memory variables
; ============================================================================
vdd_pixel:
    push    edi
    push    edx
    push    ecx
    mov     edi, ecx
    imul    edi, SCREEN_W
    add     edi, edx
    mov     [gs:edi], al
    pop     ecx
    pop     edx
    pop     edi
    ret

; NOTE: the colour byte must never be loaded into AL while EAX still carries a
; coordinate - that self-corruption was the original M-A4 blocker.  All the
; primitives below keep the colour in BL and the running offset in EDI.
h_line:
    pushad
    mov     ecx, [vdd_w]
    test    ecx, ecx
    jz      .done
    mov     edi, [vdd_y]
    imul    edi, SCREEN_W
    add     edi, [vdd_x]
    mov     bl, [vdd_col]
.l: mov     [gs:edi], bl
    inc     edi
    loop    .l
.done:
    popad
    ret

v_line:
    pushad
    mov     ecx, [vdd_h]
    test    ecx, ecx
    jz      .done
    mov     edi, [vdd_y]
    imul    edi, SCREEN_W
    add     edi, [vdd_x]
    mov     bl, [vdd_col]
.l: mov     [gs:edi], bl
    add     edi, SCREEN_W
    loop    .l
.done:
    popad
    ret

vdd_fill:
    pushad
    mov     ecx, [vdd_h]
    test    ecx, ecx
    jz      .done
    mov     edx, [vdd_w]
    test    edx, edx
    jz      .done
    mov     edi, [vdd_y]
    imul    edi, SCREEN_W
    add     edi, [vdd_x]
    mov     bl, [vdd_col]
.y:
    push    ecx
    push    edi
    mov     ecx, edx
.x: mov     [gs:edi], bl
    inc     edi
    loop    .x
    pop     edi
    pop     ecx
    add     edi, SCREEN_W
    loop    .y
.done:
    popad
    ret

; 3D beveled border: light (vdd_col) top/left, dark (vdd_col2) bottom/right
vdd_frame3d:
    pushad
    mov     eax, [vdd_x]
    mov     ebx, [vdd_y]
    mov     esi, [vdd_col]            ; light
    mov     edi, [vdd_col2]           ; dark
    call    h_line                    ; top    (light)
    call    v_line                    ; left   (light)
    mov     [vdd_col], edi            ; switch to the dark shade
    mov     ecx, ebx
    add     ecx, [vdd_h]
    dec     ecx
    mov     [vdd_y], ecx
    call    h_line                    ; bottom (dark)
    mov     [vdd_y], ebx
    mov     ecx, eax
    add     ecx, [vdd_w]
    dec     ecx
    mov     [vdd_x], ecx
    call    v_line                    ; right  (dark)
    mov     [vdd_x], eax
    mov     [vdd_col], esi
    popad
    ret

; draw one 8x8 glyph. char in vdd_ch, base x/y in vdd_x/vdd_y, color vdd_col
;   FONT is indexed by the raw ASCII code (the table already contains the
;   0x00..0x1F blank padding), so no 0x20 bias may be applied here.
vdd_char:
    pushad
    movzx   eax, byte [vdd_ch]
    cmp     eax, 0x7F
    jae     .done
    shl     eax, 3
    lea     esi, [FONT + eax]         ; glyph rows
    mov     edi, [vdd_y]
    imul    edi, SCREEN_W
    add     edi, [vdd_x]              ; framebuffer offset of the glyph origin
    mov     dl, [vdd_col]
    xor     ecx, ecx                  ; row 0..7
.row:
    mov     bl, [esi + ecx]
    xor     eax, eax                  ; column 0..7
.bit:
    test    bl, 0x80
    jz      .nb
    mov     [gs:edi + eax], dl
.nb:
    shl     bl, 1
    inc     eax
    cmp     eax, 8
    jb      .bit
    add     edi, SCREEN_W
    inc     ecx
    cmp     ecx, 8
    jb      .row
.done:
    popad
    ret

; draw a NUL-terminated string. ptr in vdd_str, base x/y/col in vdd_*
vdd_text:
    pushad
    mov     esi, [vdd_str]
    mov     ebx, [vdd_x]              ; pen x
    mov     ebp, [vdd_y]              ; pen y
.ch:
    mov     al, [esi]
    inc     esi
    test    al, al
    jz      .done
    mov     [vdd_ch], al
    mov     [vdd_x], ebx
    mov     [vdd_y], ebp
    call    vdd_char
    add     ebx, 8
    jmp     .ch
.done:
    popad
    ret

; ============================================================================
; Scene: Win9x desktop + taskbar + start button + window
; ============================================================================
draw_desktop:
    pushad
    ; --- desktop fill (teal) ---
    mov     dword [vdd_x], 0
    mov     dword [vdd_y], 0
    mov     dword [vdd_w], SCREEN_W
    mov     dword [vdd_h], SCREEN_H
    mov     dword [vdd_col], 1
    call    vdd_fill

    ; --- taskbar (gray) bottom 20px ---
    mov     dword [vdd_x], 0
    mov     dword [vdd_y], 180
    mov     dword [vdd_w], SCREEN_W
    mov     dword [vdd_h], 20
    mov     dword [vdd_col], 2
    call    vdd_fill

    ; --- start button (gray face) + 3D bevel ---
    mov     dword [vdd_x], 4
    mov     dword [vdd_y], 182
    mov     dword [vdd_w], 60
    mov     dword [vdd_h], 16
    mov     dword [vdd_col], 2
    call    vdd_fill
    call    draw_start_frame
    mov     dword [vdd_x], 9
    mov     dword [vdd_y], 184
    mov     dword [vdd_col], 0
    mov     dword [vdd_str], start_label
    call    vdd_text

    ; --- window (client + title bar + 3D border) ---
    call    draw_window

    ; --- initial clock text on the taskbar ---
    call    draw_clock
    popad
    ret

draw_start_frame:
    pushad
    mov     dword [vdd_col], 2        ; light
    mov     dword [vdd_col2], 4       ; dark
    call    vdd_frame3d
    popad
    ret

draw_window:
    pushad
    ; client + title background (white) covering the whole window rect
    mov     dword [vdd_x], 40
    mov     dword [vdd_y], 30
    mov     dword [vdd_w], 240
    mov     dword [vdd_h], 140
    mov     dword [vdd_col], 5
    call    vdd_fill
    ; title bar (navy) 18px tall
    mov     dword [vdd_x], 40
    mov     dword [vdd_y], 30
    mov     dword [vdd_w], 240
    mov     dword [vdd_h], 18
    mov     dword [vdd_col], 3
    call    vdd_fill
    ; title text "MS-DOS" (white)
    mov     dword [vdd_x], 46
    mov     dword [vdd_y], 33
    mov     dword [vdd_col], 5
    mov     dword [vdd_str], title_label
    call    vdd_text
    ; 3D window border: light=white, dark=shadow
    mov     dword [vdd_x], 40
    mov     dword [vdd_y], 30
    mov     dword [vdd_w], 240
    mov     dword [vdd_h], 140
    mov     dword [vdd_col], 5
    mov     dword [vdd_col2], 4
    call    vdd_frame3d
    popad
    ret

; draw the blinking cursor. cursor_on=1 -> yellow block, else teal erase
draw_cursor:
    pushad
    mov     eax, [cursor_x]
    mov     [vdd_x], eax
    mov     eax, [cursor_y]
    mov     [vdd_y], eax
    mov     dword [vdd_w], 8
    mov     dword [vdd_h], 12
    mov     eax, [cursor_on]
    test    eax, eax
    jz      .erase
    mov     dword [vdd_col], 6
    jmp     .go
.erase:
    mov     dword [vdd_col], 1
.go:
    call    vdd_fill
    popad
    ret

; format MM:SS (anim_seconds) into clock_str and draw it on the taskbar
draw_clock:
    pushad
    mov     eax, [anim_seconds]
    xor     edx, edx
    mov     ecx, 60
    div     ecx                 ; eax = minutes, edx = seconds
    mov     edi, clock_str
    mov     ebx, eax
    add     bl, '0'
    mov     [edi], bl
    inc     edi
    mov     byte [edi], ':'
    inc     edi
    mov     eax, edx
    mov     cl, 10
    div     cl                  ; al = tens, ah = ones
    add     al, '0'
    mov     [edi], al
    inc     edi
    add     ah, '0'
    mov     [edi], ah
    inc     edi
    mov     byte [edi], 0
    ; erase the clock area (gray) then draw text
    mov     dword [vdd_x], 248
    mov     dword [vdd_y], 184
    mov     dword [vdd_w], 44
    mov     dword [vdd_h], 10
    mov     dword [vdd_col], 2
    call    vdd_fill
    mov     dword [vdd_x], 248
    mov     dword [vdd_y], 184
    mov     dword [vdd_col], 0
    mov     dword [vdd_str], clock_str
    call    vdd_text
    popad
    ret

; ============================================================================
; VMM + VTD - the GUI "System VM" is driven by the timer interrupt
; ============================================================================
vdd_anim_tick:
    pushad
    inc     dword [anim_seconds]
    ; toggle the cursor
    mov     eax, [cursor_on]
    xor     eax, 1
    mov     [cursor_on], eax
    call    draw_cursor
    ; advance the clock
    call    draw_clock
    popad
    ret

; --- self-check: read back framebuffer pixels at known spots ----------------
vdd_verify:
    pushad
    mov     esi, verify_msg
    call    dbg32_puts
    xor     ebx, ebx            ; mismatch count
    ; (5,5)      desktop  -> teal (1)
    mov     edi, 5*SCREEN_W + 5
    mov     al, [gs:edi]
    movzx   eax, al
    dbg_hex32
    cmp     al, 1
    je      .c1
    inc     ebx
.c1:
    ; (160,190)  taskbar  -> gray (2)
    mov     edi, 190*SCREEN_W + 160
    mov     al, [gs:edi]
    movzx   eax, al
    dbg_hex32
    cmp     al, 2
    je      .c2
    inc     ebx
.c2:
    ; (60,195)   start btn face (clear of the "START" glyphs) -> gray (2)
    mov     edi, 195*SCREEN_W + 60
    mov     al, [gs:edi]
    movzx   eax, al
    dbg_hex32
    cmp     al, 2
    je      .c3
    inc     ebx
.c3:
    ; (120,39)   title    -> navy (3)
    mov     edi, 39*SCREEN_W + 120
    mov     al, [gs:edi]
    movzx   eax, al
    dbg_hex32
    cmp     al, 3
    je      .c4
    inc     ebx
.c4:
    ; (120,110)  client   -> white (5)
    mov     edi, 110*SCREEN_W + 120
    mov     al, [gs:edi]
    movzx   eax, al
    dbg_hex32
    cmp     al, 5
    je      .c5
    inc     ebx
.c5:
    ; build result "DTSWCV" (pass) or "DTSWCF" (fail) and emit via dbg32_puts
    mov     byte [vresult], 'D'
    mov     byte [vresult+1], 'T'
    mov     byte [vresult+2], 'S'
    mov     byte [vresult+3], 'W'
    mov     byte [vresult+4], 'C'
    mov     byte [vresult+5], 'V'
    cmp     ebx, 0
    je      .ok
    mov     byte [vresult+5], 'F'
.ok:
    mov     byte [vresult+6], 0
    mov     esi, vresult
    call    dbg32_puts
    ; 32-bit checksum over the whole framebuffer (extra assertion channel)
    call    fb_checksum
    mov     esi, vok_msg
    call    dbg32_puts
    popad
    ret

fb_checksum:
    xor     eax, eax
    xor     edi, edi
.l: add     al, [gs:edi]
    adc     eax, 0
    inc     edi
    cmp     edi, SCREEN_W*SCREEN_H
    jb      .l
    dbg_hex32
    ret

; ============================================================================
; Serial PPM dump (COM1) - produces an exact 320x200 screenshot for the test
; ============================================================================
dump_ppm:
    pushad
    mov     esi, ppm_hdr
.h: lodsb
    or      al, al
    jz      .hb
    call    serial_putc
    jmp     .h
.hb:
    xor     edi, edi
.l: mov     al, [gs:edi]
    call    serial_putc
    inc     edi
    cmp     edi, SCREEN_W*SCREEN_H
    jb      .l
    popad
    ret

serial_putc:
    push    edx
    push    ecx
.sp:
    mov     dx, 0x3FD
    in      al, dx
    test    al, 0x20
    jz      .sp
    mov     dx, 0x3F8
    out     dx, al
    pop     ecx
    pop     edx
    ret

; ============================================================================
; 32-bit debug helpers
; ============================================================================
dbg32_puts:
    push    esi
.l: lodsb
    or      al, al
    jz      .d
    out     0xE9, al
    jmp     .l
.d: pop     esi
    ret

; ============================================================================
; VMM - virtual machine manager (single System VM)
; ============================================================================
VM_ESP          equ 0
VM_STATE        equ 4
VM_ID           equ 8
VM_TICKS        equ 12
VM_NAME         equ 16
VM_CB_SIZE      equ 20

VM_STATE_FREE   equ 0
VM_STATE_READY  equ 1
VM_STATE_RUN    equ 2

MAX_VMS         equ 1
VM_STACK_SIZE   equ 1024
VM_QUANTUM      equ 2
MAX_TICKS       equ 220
VTD_ANIM        equ 20

vmm_init:
    mov     esi, vmm_init_msg
    call    dbg32_puts

    ; --- System VM (id 0) ---
    mov     edi, vm_table
    mov     dword [edi + VM_ID],    0
    mov     dword [edi + VM_STATE], VM_STATE_READY
    mov     dword [edi + VM_TICKS], 0
    mov     dword [edi + VM_NAME],  'SYS '
    mov     eax, sysvm_stack_top + KBASE
    mov     ebx, sysvm_entry
    call    vm_bootstrap_frame

    mov     dword [current_vm], 0
    mov     dword [total_ticks], 0
    mov     dword [quantum_left], VM_QUANTUM

    mov     esi, vmm_ready_msg
    call    dbg32_puts
    ret

; build the synthetic interrupt frame for a VM that has never run.
; EDI = VM_CB, EAX = stack top (linear), EBX = entry EIP
vm_bootstrap_frame:
    push    edi
    sub     eax, KBASE              ; convert to segment-relative offset
    mov     edi, eax
    sub     edi, 4
    mov     dword [edi], 0x0202     ; EFLAGS: IF=1
    sub     edi, 4
    mov     dword [edi], SEL_CODE0  ; CS
    sub     edi, 4
    mov     [edi], ebx              ; EIP = VM entry
    mov     ecx, 8
.zero:
    sub     edi, 4
    mov     dword [edi], 0
    loop    .zero
    mov     eax, edi
    pop     edi
    mov     [edi + VM_ESP], eax
    ret

vmm_start:
    mov     eax, [current_vm]
    imul    eax, VM_CB_SIZE
    add     eax, vm_table
    mov     dword [eax + VM_STATE], VM_STATE_RUN
    mov     esp, [eax + VM_ESP]
    popad
    iretd

vmm_shutdown:
    cli
    mov     esi, shutdown_msg
    call    dbg32_puts
    ; per-VM tick statistics
    xor     ebx, ebx
.sloop:
    cmp     ebx, MAX_VMS
    jae     .sdone
    mov     esi, stat_pre
    call    dbg32_puts
    mov     eax, ebx
    imul    eax, VM_CB_SIZE
    add     eax, vm_table
    push    eax
    mov     esi, eax
    add     esi, VM_NAME
    mov     ecx, 4
.sname:
    lodsb
    out     0xE9, al
    loop    .sname
    mov     esi, stat_mid
    call    dbg32_puts
    pop     eax
    mov     eax, [eax + VM_TICKS]
    call    dbg32_dec
    mov     esi, nl
    call    dbg32_puts
    inc     ebx
    jmp     .sloop
.sdone:
    mov     esi, total_pre
    call    dbg32_puts
    mov     eax, [total_ticks]
    call    dbg32_dec
    mov     esi, nl
    call    dbg32_puts
    mov     esi, done_msg
    call    dbg32_puts
    mov     al, 0xFF
    out     0x21, al
    cli
    hlt
    jmp     $

; print EAX as unsigned decimal
dbg32_dec:
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     ebx, 10
    xor     ecx, ecx
.div:
    xor     edx, edx
    div     ebx
    add     dl, '0'
    push    edx
    inc     ecx
    test    eax, eax
    jnz     .div
.emit:
    pop     eax
    out     0xE9, al
    loop    .emit
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

sysvm_entry:
    sti
.loop:
    hlt
    jmp     .loop

; ============================================================================
; VTD - Virtual Timer Device (a VxD bound to PIT IRQ0)
; ============================================================================
vtd_init:
    mov     esi, vtd_init_msg
    call    dbg32_puts

    ; remap the 8259 PICs: IRQ0..7 -> vectors 0x20..0x27
    mov     al, 0x11
    out     0x20, al
    out     0xA0, al
    mov     al, 0x20
    out     0x21, al
    mov     al, 0x28
    out     0xA1, al
    mov     al, 0x04
    out     0x21, al
    mov     al, 0x02
    out     0xA1, al
    mov     al, 0x01
    out     0x21, al
    out     0xA1, al

    ; unmask IRQ0 only
    mov     al, 0xFE
    out     0x21, al
    mov     al, 0xFF
    out     0xA1, al

    ; PIT channel 0, mode 3, ~100 Hz
    mov     al, 0x36
    out     0x43, al
    mov     ax, 11932
    out     0x40, al
    mov     al, ah
    out     0x40, al

    mov     dword [vtd_ticks], 0
    mov     esi, vtd_ready_msg
    call    dbg32_puts
    ret

vtd_isr:
    pushad

    inc     dword [vtd_ticks]
    inc     dword [total_ticks]

    ; charge the tick to the VM that was running when the timer fired
    mov     eax, [current_vm]
    imul    eax, VM_CB_SIZE
    add     eax, vm_table
    inc     dword [eax + VM_TICKS]

    ; EOI to the master PIC
    mov     al, 0x20
    out     0x20, al

    ; terminate the demo after MAX_TICKS
    mov     eax, [total_ticks]
    cmp     eax, MAX_TICKS
    jb      .no_exit
    mov     esp, 0x20000
    jmp     vmm_shutdown
.no_exit:

    ; every VTD_ANIM ticks, advance the GUI animation
    mov     eax, [vtd_ticks]
    xor     edx, edx
    mov     ecx, VTD_ANIM
    div     ecx
    test    edx, edx
    jnz     .skip
    call    vdd_anim_tick
.skip:

    popad
    iretd

; ============================================================================
; IDT
; ============================================================================
build_idt:
    mov     edi, idt_table
    mov     ecx, 256 * 2
    xor     eax, eax
    rep     stosd

    ; CPU exception handlers (DPL=0 interrupt gates)
    mov     eax, idt_default_handler
    mov     ebx, eax
    shr     ebx, 16
    mov     ecx, SEL_CODE0
    mov     edx, 0x8E
    mov     esi, 0x00
    call    set_idt_entry
    mov     esi, 0x06
    call    set_idt_entry
    mov     esi, 0x08
    call    set_idt_entry
    mov     esi, 0x0D
    call    set_idt_entry
    mov     esi, 0x0E
    call    set_idt_entry

    ; VTD on vector 0x20 (IRQ0 after remap)
    mov     eax, vtd_isr
    mov     ebx, eax
    shr     ebx, 16
    mov     ecx, SEL_CODE0
    mov     edx, 0x8E
    mov     esi, 0x20
    call    set_idt_entry
    ret

set_idt_entry:
    push    eax
    push    esi
    mov     edi, idt_table
    shl     esi, 3
    add     edi, esi
    pop     esi
    pop     eax
    mov     word [edi + 0], ax
    mov     word [edi + 2], cx
    mov     byte [edi + 4], 0
    mov     byte [edi + 5], dl
    mov     word [edi + 6], bx
    ret

idt_default_handler:
    mov     esi, fault_msg
    call    dbg32_puts
    cli
    hlt
    jmp     $

; ============================================================================
; Data
; ============================================================================
verify_msg     db "[A4] self-check framebuffer: ", 0
vok_msg        db " [done]", 13, 10, 0
vmm_init_msg   db "[VMM] init: creating System VM", 13, 10, 0
vmm_ready_msg  db "[VMM] System VM created, state=READY", 13, 10, 0
vtd_init_msg   db "[VTD] init: PIC remap + PIT 100Hz", 13, 10, 0
vtd_ready_msg  db "[VTD] virtual timer device armed on IRQ0", 13, 10, 0
shutdown_msg   db "[VMM] shutdown - VM statistics:", 13, 10, 0
stat_pre       db "  VM ", 0
stat_mid       db " ticks=", 0
total_pre      db "[VTD] total ticks=", 0
fault_msg      db "[FAULT] unhandled exception", 13, 10, 0
done_msg       db "[A4] DONE", 13, 10, 0
nl             db 13, 10, 0

title_label    db "MS-DOS", 0
start_label    db "START", 0
clock_str      times 8 db 0
vresult        times 8 db 0

ALIGN 4
vdd_x          dd 0
vdd_y          dd 0
vdd_w          dd 0
vdd_h          dd 0
vdd_col        dd 0
vdd_col2       dd 0
vdd_ch         dd 0
vdd_str        dd 0

ALIGN 4
cursor_x       dd 300
cursor_y       dd 150
cursor_on      dd 0
anim_seconds   dd 0

ALIGN 4
current_vm     dd 0
total_ticks    dd 0
quantum_left   dd 0
vtd_ticks      dd 0

ALIGN 4
vm_table       times MAX_VMS*VM_CB_SIZE db 0

ALIGN 16
sysvm_stack       times VM_STACK_SIZE db 0
sysvm_stack_top   equ $

; --- 8x8 font (ASCII 0x20..0x7E); only the glyphs we use are non-blank -------
FONT:
    times (0x20)*8 db 0                  ; 0x00..0x1F (control)
    db 0,0,0,0,0,0,0,0                   ; 0x20 space
    times (0x2D-0x21)*8 db 0             ; 0x21..0x2C
    db 0x00,0x00,0x00,0x7E,0x00,0x00,0x00,0x00   ; 0x2D '-'
    times (0x30-0x2E)*8 db 0             ; 0x2E,0x2F
    db 0x3C,0x42,0x42,0x42,0x42,0x42,0x42,0x3C   ; 0x30 '0'
    db 0x08,0x18,0x08,0x08,0x08,0x08,0x08,0x1C   ; 0x31 '1'
    db 0x3C,0x42,0x02,0x04,0x08,0x10,0x20,0x7E   ; 0x32 '2'
    db 0x3C,0x42,0x02,0x1C,0x02,0x02,0x42,0x3C   ; 0x33 '3'
    db 0x04,0x0C,0x14,0x24,0x44,0x7E,0x04,0x04   ; 0x34 '4'
    db 0x7E,0x40,0x7C,0x02,0x02,0x42,0x42,0x3C   ; 0x35 '5'
    db 0x1C,0x20,0x40,0x7C,0x42,0x42,0x42,0x3C   ; 0x36 '6'
    db 0x7E,0x02,0x04,0x08,0x10,0x10,0x10,0x10   ; 0x37 '7'
    db 0x3C,0x42,0x42,0x3C,0x42,0x42,0x42,0x3C   ; 0x38 '8'
    db 0x3C,0x42,0x42,0x42,0x3E,0x02,0x04,0x38   ; 0x39 '9'
    db 0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x00   ; 0x3A ':'
    times (0x41-0x3B)*8 db 0             ; 0x3B..0x40
    db 0x18,0x24,0x42,0x42,0x7E,0x42,0x42,0x00   ; 0x41 'A'
    times (0x44-0x42)*8 db 0             ; 0x42,0x43
    db 0x7C,0x42,0x42,0x42,0x42,0x42,0x42,0x7C   ; 0x44 'D'
    db 0x7E,0x40,0x40,0x7C,0x40,0x40,0x40,0x7E   ; 0x45 'E'
    times (0x4B-0x46)*8 db 0             ; 0x46..0x4A
    db 0x42,0x44,0x48,0x70,0x48,0x44,0x42,0x42   ; 0x4B 'K'
    db 0x40,0x40,0x40,0x40,0x40,0x40,0x40,0x7E   ; 0x4C 'L'
    db 0x42,0x66,0x5A,0x5A,0x42,0x42,0x42,0x42   ; 0x4D 'M'
    db 0x42,0x62,0x52,0x4A,0x46,0x42,0x42,0x42   ; 0x4E 'N'
    db 0x3C,0x42,0x42,0x42,0x42,0x42,0x42,0x3C   ; 0x4F 'O'
    times (0x52-0x50)*8 db 0             ; 0x50,0x51
    db 0x7C,0x42,0x42,0x7C,0x48,0x44,0x42,0x42   ; 0x52 'R'
    db 0x3C,0x42,0x40,0x3C,0x02,0x42,0x42,0x3C   ; 0x53 'S'
    db 0x7E,0x18,0x18,0x18,0x18,0x18,0x18,0x18   ; 0x54 'T'
    times (0x7F-0x55)*8 db 0             ; 0x55..0x7E

; PPM header for the serial dump (P6, 320x200, maxval 255)
ppm_hdr        db "P6", 13, 10, "320 200", 13, 10, "255", 13, 10, 0

; ============================================================================
; GDT
; ============================================================================
ALIGN 8
gdt_data:
    gdt_entry 0, 0, 0, 0                                       ; 0x00 null
    gdt_entry KBASE, 0xFFFFF, ACCESS_RING0_CODE, FLAG_4K_32BIT ; 0x08 code
    gdt_entry KBASE, 0xFFFFF, ACCESS_RING0_DATA, FLAG_4K_32BIT ; 0x10 data
    gdt_entry VGA_FB, 0xFFFFF, ACCESS_RING0_DATA, FLAG_4K_32BIT ; 0x18 VGA (base 0xA0000)
    gdt_entry KBASE, 0x0FFFF, ACCESS_RING0_CODE, 0x00          ; 0x20 code16
    gdt_entry 0, 0, 0, 0                                       ; 0x28 TSS (unused)
    gdt_entry KBASE, 0x0FFFF, ACCESS_RING0_DATA, 0x00          ; 0x30 data16
gdt_descriptor:
    dw      gdt_data_end - gdt_data - 1
    dd      gdt_data + KBASE
gdt_data_end:

; ============================================================================
; IDT (kept last so 'rep stosd' cannot run over the GDT)
; ============================================================================
ALIGN 8
idt_table:
    times 256*8 db 0
idt_descriptor:
    dw      256 * 8 - 1
    dd      idt_table + KBASE
