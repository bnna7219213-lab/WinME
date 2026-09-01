; ============================================================================
; a4x_gui.asm - M-A4+ Win9x enhanced GUI (boot32+VIDEO_MODE=0x13 pipeline)
;   Uses the SAME boot32 pipeline verified by M-D2:
;     boot32.asm loads kernel at 0x8000, relocates to 0x100000, jumps.
;     Kernel: BITS 32, ORG 0x100000, flat addressing, base 0 for data.
;
;   Features:
;     - LFB double buffer (0x30000 -> 0xA0000)
;     - 64-color palette, blue gradient desktop
;     - Window manager: Z-order, drag, min/max/restore/close
;     - Mouse driver (PS/2 IRQ12) + arrow cursor + hit test
;     - Start menu + right-click context menu + taskbar
;     - VIN virtual input script (deterministic demo)
;     - VMM/VTD (PIT IRQ0) message loop
; ============================================================================
BITS 32
ORG 0x100000
%include "common/debug.inc"
%include "common/gdt.inc"

; -------- constants --------
SW          equ 320
SH          equ 200
VGA_FB      equ 0xA0000
LFB         equ 0x30000           ; off-screen double buffer
SEL_C0      equ 0x08
SEL_D0      equ 0x10
SEL_VGA     equ 0x18

; -------- palette indices --------
PB  equ 0        ; black
PW  equ 1        ; white
PG  equ 2        ; gray (taskbar)
PN0 equ 3        ; navy top
PN1 equ 4        ; navy bottom
PC  equ 5        ; client
PD  equ 6        ; dark bevel
PL  equ 7        ; light bevel
PR  equ 8        ; red close
PGN equ 9        ; green max
PY  equ 10       ; yellow min
MNU equ 11       ; menu bg
MCU equ 32       ; menu cursor

; -------- window layout --------
WAX  equ 40
WAY  equ 10
WAW  equ 240
WAH  equ 130
TH  equ 18        ; title bar height
BS  equ 14        ; button size
CLX  equ WAX+WAW-BS-2 ; close button x
CLY  equ WAY+2
MXX  equ CLX-BS-2
MXY  equ WAY+2
MN2X equ MXX-BS-2
MN2Y equ WAY+2
TBRY equ 180       ; taskbar y
TH2 equ 20
SXT equ 4         ; start button x
SYT equ 182
SXX equ 80
SYX equ 16
MNX equ 4
MNW equ 96
MNH equ 140
MNY equ TBRY-MNH     ; =96
MIH equ 18
CTXW equ 120
CTXH equ 48
CTXI      equ 16
CLKX      equ 272
CLKY      equ 184
TBX       equ 88
TBW       equ 40
TBH       equ 16
ICONX1    equ 12
ICONY1    equ 10
ICONX2    equ 12
ICONY2    equ 74
ICO_W     equ 16
ICO_H     equ 16

; -------- window IDs --------
WT        equ 0
WB        equ 1
WA        equ 2
WM        equ 3
WBN       equ 4
WBM       equ 5
WBC       equ 6
WCT       equ 7
WD        equ 8
WN        equ 9
WA2       equ 10
WSH       equ 11
; Desktop file/browser window
WFL       equ 12
; Network window
WNET      equ 13
; Browser (Internet Explorer)
WBR       equ 14
; Installer
WIN       equ 15
; EXE Runner / Report
WEX       equ 16
MAXW      equ 17
MAXM      equ 16
WSZ       equ 32
MSZ       equ 12
; Browser address bar
BR_ADDR   equ 32

; -------- File system --------
; File entry layout (32 bytes each):
;   0-15:  name[16]
;   16:    type
;   17-20: size (legacy, kept for compatibility)
;   21:    flags (FS_FLG_*)
;   22:    parent
;   23:    reserved (future flags)
;   24-27: content_ptr  (dword: bytecode/data offset inside file_contents_pool)
;                         = 0xFFFFFFFF means use legacy default code path
;   28-31: content_len  (dword: length in bytes of the content)
FS_NAME         equ 16
FS_SZ           equ 32
FS_MAXF         equ 16       ; max file entries = 2KB data
FS_TYPE_FILE    equ 0
FS_TYPE_FOLDER  equ 1
FS_TYPE_COMPUTER equ 2
FS_TYPE_TRASH   equ 3
FS_TYPE_NETWORK equ 4
FS_TYPE_FILE_TXT equ 5
FS_TYPE_FILE_EXE equ 6
FS_FLG_DELETED  equ 0x01
FS_FLG_SYSTEM   equ 0x02
; --- Per-file content pointers ---
FS_CONTENT_OFF  equ 24       ; dword
FS_CONTENT_LEN  equ 28       ; dword
FS_CONTENT_UNSET equ 0xFFFFFFFF
; --- EXE bytecode limits ---
EXE_CONTENT_CHUNK equ 1024   ; 1KB per EXE.  16 entries * 1KB = 16KB pool
FS_MAX_CONTENTS  equ 16
; --- PE loader constants ---
PE_LOAD_BASE      equ 0x400000     ; 标准 Windows PE ImageBase，当前 2.9MB 空闲
PE_MAX_SIZE       equ 0x10000      ; 64KB PE 镜像上限
PE_DOWNLOAD_MAX   equ 0x10000      ; 下载缓冲上限
; --- PE stub arena (bump allocators for HeapAlloc/VirtualAlloc) ---
PE_HEAP_SIZE      equ 0x08000      ;  32KB process heap (sufficient for ~30 PE objects)
PE_VMEM_SIZE      equ 0x10000      ;  64KB virtual memory pool (16 x 4KB pages)

; -------- Net --------
NET_NAME  equ 16
NET_IP    equ 4
NET_SZ    equ 32
NET_MAXH  equ 8         ; max hosts = 256 bytes data

; -------- messages --------
WM_PAINT  equ 1
WM_LDOWN  equ 2
WM_LUP    equ 3
WM_RDOWN  equ 4
WM_CMD    equ 5
WM_MMV    equ 6
WM_KEY    equ 7

; -------- button IDs --------
B_ST equ 1
B_MN equ 2
B_MX equ 3
B_CL equ 4

; -------- window states --------
WS_HID  equ 0
WS_NORM equ 1
WS_MIN  equ 2
WS_MAX  equ 3

; -------- Phase B additions --------
DBLCLK_TICKS equ 10          ; max ticks between two title clicks for dbl-click
BC_MAGIC     equ 0xA4        ; downloaded bytecode magic header byte
DL_CODE_SZ   equ EXE_CONTENT_CHUNK  ; downloaded bytecode buffer = 1KB chunk
; dl_valid state:
;   0 = no download
;   1 = dl_code holds raw downloaded bytecode (transient, only until install)
;   2 = dl_code was INSTALLED into file_table and can be double-clicked as exe

; -------- VIN event types --------
VIN_MM equ 0
VIN_LD equ 1
VIN_LU equ 2
VIN_RD equ 3
VIN_RU equ 4
VIN_WT equ 5
VIN_EN equ 6
VINSZ equ 12

; ============================================================================
; ENTRY
; ============================================================================
global_start:
    cli
    cld
    mov     al, 'A'
    out     0xE9, al
    ; boot32 GDT already valid (code=0x08, data=0x10, both flat 4GB, base=0).
    ; Skip redundant lgdt: the kernel GDT's extra VGA entry (0x18) is unused,
    ; and lgdt here triggers QEMU SMM entry/exit that clobbers GDTR before the
    ; far jump completes, causing #GP. Use a direct far jump to flush CS.
    jmp     SEL_C0:.flush_cs
.flush_cs:
    mov     al, 'B'
    out     0xE9, al
    mov     ax, SEL_D0
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    mov     ss, ax
    mov     al, 'C'
    out     0xE9, al
    call    build_idt
    mov     al, '6'
    out     0xE9, al
    lidt    [idt_desc_local]
    call    pal_init
    mov     al, '7'
    out     0xE9, al
    call    gdi_init
    mov     al, '8'
    out     0xE9, al
    call    usr_init
    mov     al, '9'
    out     0xE9, al
    call    mou_init
    mov     al, ':'
    out     0xE9, al
    call    kbd_init
    mov     al, ';'
    out     0xE9, al
    call    fs_init
    mov     al, '<'
    out     0xE9, al
    call    vtd_init
    sti
    ; Init browser
    mov     edi, br_url
    mov     esi, br_addr_t
    mov     ecx, BR_ADDR
    rep     movsb
    mov     byte [br_page], 1
    mov     dword [CW_HND], WBR
    mov     dword [CW_X], 40
    mov     dword [CW_Y], 30
    mov     dword [CW_W], 240
    mov     dword [CW_H], 110
    mov     byte [CW_WP], 11
    mov     byte [CW_BI], 0
    call    CreateWindow
    mov     dword [CW_HND], WBR
    mov     dword [CW_MSG], WM_PAINT
    call    user_dispatch
    call    demo_run
    cli
    hlt
    jmp     $

; ============================================================================
; build_idt
; ============================================================================
build_idt:
    push    ebx
    push    esi
    push    edi
    mov     edi, idt_table
    mov     ecx, 0x30*2       ; 48 entries * 2 dwords = 96 dwords (matches idt_table)
    xor     eax, eax
    rep     stosd
    mov     eax, fault_0
    mov     ebx, eax
    shr     ebx, 16
    mov     ecx, SEL_C0
    mov     edx, 0x8E
    mov     esi, 0
    call    set_idte
    mov     eax, fault_6
    mov     ebx, eax
    shr     ebx, 16
    mov     esi, 6
    call    set_idte
    mov     eax, fault_8
    mov     ebx, eax
    shr     ebx, 16
    mov     esi, 8
    call    set_idte
    mov     eax, fault_13
    mov     ebx, eax
    shr     ebx, 16
    mov     esi, 13
    call    set_idte
    mov     eax, fault_14
    mov     ebx, eax
    shr     ebx, 16
    mov     esi, 14
    call    set_idte
    mov     eax, vtd_isr
    mov     ebx, eax
    shr     ebx, 16
    mov     ecx, SEL_C0
    mov     edx, 0x8E
    mov     esi, 0x20
    call    set_idte
    mov     eax, mou_isr
    mov     ebx, eax
    shr     ebx, 16
    mov     esi, 0x34        ; PS/2 IRQ12: slave base 0x28 + 12 = 0x34
    call    set_idte
    mov     eax, kbd_isr
    mov     ebx, eax
    shr     ebx, 16
    mov     esi, 0x21
    call    set_idte
    pop     edi
    pop     esi
    pop     ebx
    ret

set_idte:
    push    edi
    mov     edi, idt_table
    shl     esi, 3
    add     edi, esi
    mov     word [edi], ax        ; offset low
    mov     word [edi+2], cx      ; selector
    mov     byte [edi+4], 0
    mov     byte [edi+5], dl      ; type/attr
    mov     word [edi+6], bx      ; offset high
    pop     edi
    ret

idt_def:
    dbg_puts "[A4X] FAULT", 13, 10, 0
    cli
    hlt
    jmp     $

fault_0:
    dbg_puts "[A4X] EX0 #DE", 13, 10, 0
    cli
    hlt
    jmp $
fault_6:
    ; Minimal: just print one char
    mov     al, 'U'
    out     0xE9, al
    cli
    hlt
    jmp $
fault_8:
    dbg_puts "[A4X] EX8 #DF", 13, 10, 0
    cli
    hlt
    jmp $
fault_13:
    cli
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     al, 'G'
    out     0xE9, al
    mov     al, 'P'
    out     0xE9, al
    mov     eax, [esp + 16 + 0]      ; #GP error code
    call    fxdump32
    mov     al, 'E'
    out     0xE9, al
    mov     eax, [esp + 16 + 4]      ; faulting EIP
    call    fxdump32
    mov     al, 'X'
    out     0xE9, al
    mov     eax, [esp + 16 + 12]     ; EFLAGS
    call    fxdump32
    mov     al, 'G'
    out     0xE9, al
    hlt
    jmp $
fault_14:
    cli
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     al, 'P'
    out     0xE9, al
    mov     al, 'F'
    out     0xE9, al
    mov     eax, cr2
    call    fxdump32
    mov     al, 'E'
    out     0xE9, al
    mov     eax, [esp + 16 + 0]
    call    fxdump32
    mov     al, 'I'
    out     0xE9, al
    mov     eax, [esp + 16 + 4]
    call    fxdump32
    mov     al, 'P'
    out     0xE9, al
    mov     eax, [esp + 16 + 12]
    call    fxdump32
    mov     al, 'Z'
    out     0xE9, al
    hlt
    jmp $
fxdump32:
    push    ebx
    push    ecx
    mov     ecx, 28
.fx_lo:
    mov     ebx, eax
    shr     ebx, cl
    and     bl, 0x0F
    add     bl, '0'
    cmp     bl, '9'
    jbe     .fx_ok
    add     bl, 7
.fx_ok:
    push    eax
    mov     eax, ebx
    and     eax, 0xFF
    out     0xE9, al
    pop     eax
    sub     ecx, 4
    jns     .fx_lo
    pop     ecx
    pop     ebx
    ret
fex_dump32:
    push    ebx
    push    ecx
    mov     ecx, 28
.fex_lo:
    mov     ebx, eax
    shr     ebx, cl
    and     bl, 0x0F
    add     bl, '0'
    cmp     bl, '9'
    jbe     .fex_ok
    add     bl, 7
.fex_ok:
    push    eax
    mov     eax, ebx
    and     eax, 0xFF
    out     0xE9, al
    pop     eax
    sub     ecx, 4
    jns     .fex_lo
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; pal_init — 64 entries to DAC
; ============================================================================
pal_init:
    push    eax
    push    ecx
    push    edx
    push    edi
    push    esi
    ; write palette directly from pal_src to DAC
    mov     dx, 0x3C8
    xor     al, al
    out     dx, al
    mov     dx, 0x3C9
    mov     esi, pal_src
    mov     ecx, 64*3
.p3:
    lodsb
    out     dx, al
    loop    .p3
    pop     esi
    pop     edi
    pop     edx
    pop     ecx
    pop     eax
    ret

; ============================================================================
; gdi_init — clear LFB + VGA
; ============================================================================
gdi_init:
    push    edi
    push    ecx
    push    eax
    ; Clear LFB (0x30000). ES=0x10 is the flat 4GB data segment — LFB and
    ; VGA both fit inside it, so we avoid push/pop ES which breaks
    ; ESP alignment when mixed with 32-bit push/pop sequences.
    mov     edi, LFB
    mov     ecx, 320*200/4
    xor     eax, eax
    rep     stosd
    ; Clear VGA (0xA0000) same flat segment
    mov     edi, VGA_FB
    rep     stosd
    pop     eax
    pop     ecx
    pop     edi
    ret

; ============================================================================
; gdi_flip — LFB -> VGA
; ============================================================================
gdi_flip:
    push    esi
    push    edi
    push    ecx
    ; LFB (0x30000) -> VGA (0xA0000) via flat ES=0x10 segment
    mov     esi, LFB
    mov     edi, VGA_FB
    mov     ecx, 320*200/4
    rep     movsd
    pop     ecx
    pop     edi
    pop     esi
    ret

; ============================================================================
; gdi_rect — fill rect. [vd_x..vd_h], al = color
; ============================================================================
gdi_rect:
    push    ebx
    push    ecx
    push    edx
    push    edi
    push    eax
    mov     al, [vd_col]      ; FIX: fill colour comes from vd_col
    mov     ebx, [vd_x]
    mov     ecx, [vd_y]
    mov     edx, [vd_h]
.gr_y:
    test    edx, edx
    jz      .gr_d
    mov     edi, ecx
    imul    edi, SW
    add     edi, ebx
    add     edi, LFB
    push    ecx
    mov     ecx, [vd_w]
    rep     stosb
    pop     ecx
    inc     ecx
    dec     edx
    jmp     .gr_y
.gr_d:
    pop     eax
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; gdi_frame3d — 3D bevel. al=light, ah=dark
;   [vd_ch]=1 raised, =0 sunken
; ============================================================================
gdi_frame3d:
    push    ebx
    push    ecx
    push    edx
    push    edi
    push    eax
    mov     ebx, [vd_x]
    mov     ecx, [vd_y]
    mov     edx, [vd_w]
    ; top
    mov     edi, ecx
    imul    edi, SW
    add     edi, ebx
    add     edi, LFB
    cmp     byte [vd_ch], 1
    jne     .ft_l
    mov     al, ah
.ft_l:
    push    ecx
    mov     ecx, edx
    rep     stosb
    pop     ecx
    ; bottom
    mov     edx, [vd_h]
    mov     edi, ecx
    add     edi, edx
    dec     edi
    imul    edi, SW
    add     edi, ebx
    add     edi, LFB
    cmp     byte [vd_ch], 1
    je      .fb_d
    mov     al, [vd_col]
.fb_d:
    push    ecx
    mov     ecx, [vd_w]
    rep     stosb
    pop     ecx
    ; left
    mov     edi, ecx
    imul    edi, SW
    add     edi, ebx
    add     edi, LFB
    cmp     byte [vd_ch], 1
    jne     .fl_l
    mov     al, ah
.fl_l:
    push    eax
    mov     edx, [vd_h]
.fl_l2:
    mov     byte [edi], al
    add     edi, SW
    dec     edx
    jnz     .fl_l2
    pop     eax
    ; right
    mov     edx, [vd_w]
    mov     edi, ecx
    add     edi, edx
    dec     edi
    imul   edi, SW
    add     edi, ebx
    add     edi, LFB
    cmp     byte [vd_ch], 1
    je      .fr_d
    mov     al, [vd_col]
.fr_d:
    push    eax
    mov     edx, [vd_h]
.fr_l2:
    mov     byte [edi], al
    add     edi, SW
    dec     edx
    jnz     .fr_l2
    pop     eax
    pop     eax
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; gdi_char — draw 8x8 char. [vd_x][vd_y][vd_col][vd_str]=charcode
; ============================================================================
gdi_char:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi
    push    eax
    mov     esi, [vd_str]
    movzx   ebx, byte [esi]
    shl     ebx, 3
    mov     esi, FONT
    add     esi, ebx
    mov     ebx, [vd_x]
    mov     ecx, [vd_y]
    mov     edx, 8
.gc_r:
    lodsb
    push    edx
    mov     edx, 8
    mov     edi, ecx
    imul    edi, SW
    add     edi, ebx
    add     edi, LFB
.gc_c:
    shl     al, 1
    jnc     .gc_s
    push    ebx
    mov     bl, [vd_col]
    mov     [edi], bl
    pop     ebx
.gc_s:
    inc     edi
    dec     edx
    jnz     .gc_c
    pop     edx
    inc     ecx
    dec     edx
    jnz     .gc_r
    pop     eax
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; gdi_text — draw null-terminated string at [vd_x][vd_y][vd_str][vd_col]
; ============================================================================
gdi_text:
    push    ebx
    push    esi
    push    edi
    push    eax
    mov     ebx, [vd_x]
    mov     esi, [vd_str]
.gt_l:
    lodsb
    or      al, al
    jz      .gt_d
    push    esi
    call    gdi_char
    pop     esi
    add     dword [vd_x], 8
    jmp     .gt_l
.gt_d:
    pop     eax
    mov     [vd_x], ebx
    pop     edi
    pop     esi
    pop     ebx
    ret

; ============================================================================
; gdi_vgrad — vertical gradient on [vd_x..vd_h]. vd_col=start, vd_col2=end
; ============================================================================
gdi_vgrad:
    push    ebx
    push    ecx
    push    edx
    push    edi
    push    eax
    push    esi
    mov     ebx, [vd_y]        ; current y (starts at top)
    mov     ecx, [vd_h]        ; outer row count (loop counter)
    ; step = vd_col2 - vd_col  (signed byte, kept in esi)
    movzx   esi, byte [vd_col2]
    movzx   eax, byte [vd_col]
    sub     esi, eax
.gv_r:
    test    ecx, ecx
    jz      .gv_d
    ; colour for this row = vd_col + (y - vd_y) * step / vd_h
    mov     eax, ebx
    sub     eax, [vd_y]        ; row index (>=0)
    imul    eax, esi           ; row * step
    xor     edx, edx
    div     dword [vd_h]       ; / h
    add     eax, [vd_col]      ; + start colour
    mov     edi, ebx
    imul    edi, SW
    add     edi, [vd_x]
    add     edi, LFB
    push    ecx                ; save outer counter
    mov     ecx, [vd_w]        ; pixel width for rep stosb
    rep     stosb
    pop     ecx                ; restore outer counter
    inc     ebx
    loop    .gv_r              ; ecx--, jnz
.gv_d:
    pop     esi
    pop     eax
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; usr_init
; ============================================================================
usr_init:
    push    edi
    push    ecx
    push    eax
    mov     edi, wnd_table
    mov     ecx, MAXW*WSZ/4
    xor     eax, eax
    rep     stosd
    mov     edi, msg_queue
    mov     ecx, MAXM*MSZ/4
    xor     eax, eax
    rep     stosd
    mov     dword [msg_head], 0
    mov     dword [msg_tail], 0
    mov     dword [msg_count], 0
    pop     eax
    pop     ecx
    pop     edi
    ret

; ============================================================================
; CreateWindow — [CW_X][CW_Y][CW_W][CW_H][CW_WP][CW_BI]
;   WinRec: 0-3:x,4-7:y,8-11:w,12-15:h,16-19:ox,20-23:oy,24:state,25:busy
;    26:winproc,27:btnid,28:zord
; ============================================================================
CreateWindow:
    push    ebx
    push    edi
    push    esi
    mov     esi, wnd_table
    mov     eax, [CW_HND]
    cmp     eax, -1
    je      .cw_s
    ; use caller-specified slot
    cmp     eax, MAXW
    jge     .cw_f
    mov     edi, eax
    imul    edi, WSZ
    add     edi, esi
    jmp     .cw_ok
.cw_s:
    mov     eax, 0
.cw_l:
    cmp     eax, MAXW
    jge     .cw_f
    mov     edi, eax
    imul    edi, WSZ
    add     edi, esi
    cmp     byte [edi+26], 0
    je      .cw_ok
    inc     eax
    jmp     .cw_l
.cw_f:
    mov     eax, -1
    jmp     .cw_d
.cw_ok:
    mov     ebx, [CW_X]
    mov     [edi], ebx
    mov     ebx, [CW_Y]
    mov     [edi+4], ebx
    mov     ebx, [CW_W]
    mov     [edi+8], ebx
    mov     ebx, [CW_H]
    mov     [edi+12], ebx
    mov     ebx, [CW_X]
    mov     [edi+16], ebx
    mov     ebx, [CW_Y]
    mov     [edi+20], ebx
    mov     byte [edi+24], WS_NORM
    mov     byte [edi+25], 0
    mov     bl, [CW_WP]
    mov     [edi+26], bl
    mov     bl, [CW_BI]
    mov     [edi+27], bl
    mov     byte [edi+28], 0
    mov     byte [edi+29], 0
    mov     byte [edi+30], 0
    mov     byte [edi+31], 0
.cw_d:
    pop     esi
    pop     edi
    pop     ebx
    ret

; ============================================================================
; DestroyWindow — eax = hwnd
; ============================================================================
DestroyWindow:
    push    edi
    push    eax
    cmp     eax, -1
    je      .dw_d
    cmp     eax, MAXW
    jge     .dw_d
    mov     edi, eax
    imul    edi, WSZ
    add     edi, wnd_table
    mov     byte [edi+24], 0
    mov     byte [edi+26], 0
.dw_d:
    pop     eax
    pop     edi
    ret

; ============================================================================
; PostMessage — [DM_HND][DM_MSG][DM_WP][DM_LP]
; ============================================================================
PostMessage:
    push    edi
    push    edx
    push    eax
    mov     eax, [msg_count]
    cmp     eax, MAXM
    jge     .pm_f
    mov     edi, [msg_tail]
    imul    edi, MSZ
    add     edi, msg_queue
    mov     eax, [DM_HND]
    mov     [edi], eax
    mov     ax, [DM_MSG]
    mov     [edi+4], ax
    mov     ax, [DM_WP]
    mov     [edi+6], ax
    mov     ax, [DM_LP]
    mov     [edi+8], ax
    mov     eax, [msg_tail]
    inc     eax
    cmp     eax, MAXM
    jl      .pm_t
    xor     eax, eax
.pm_t:
    mov     [msg_tail], eax
    inc     dword [msg_count]
.pm_f:
    pop     eax
    pop     edx
    pop     edi
    ret

; ============================================================================
; DispatchMessage
; ============================================================================
DispatchMessage:
    push    edi
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     eax, [msg_count]
    test    eax, eax
    jz      .dm_e
    mov     edi, [msg_head]
    imul    edi, MSZ
    add     edi, msg_queue
    mov     eax, [edi]
    mov     bx, [edi+4]
    mov     cx, [edi+6]
    mov     dx, [edi+8]
    mov     eax, [msg_head]
    inc     eax
    cmp     eax, MAXM
    jl      .dm_h
    xor     eax, eax
.dm_h:
    mov     [msg_head], eax
    dec     dword [msg_count]
    mov     [DM_HND], eax
    mov     [DM_MSG], bx
    mov     [DM_WP], cx
    mov     [DM_LP], dx
    jmp     .dm_d
.dm_e:
    xor     eax, eax
    mov     [DM_HND], eax
.dm_d:
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    pop     edi
    ret

; ============================================================================
; user_dispatch — [DM_HND][DM_MSG][DM_WP][DM_LP]
; ============================================================================
user_dispatch:
    push    edi
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    esi
    mov     eax, [DM_HND]
    cmp     eax, -1
    je      .ud_d
    cmp     eax, MAXW
    jge     .ud_d
    mov     edi, eax
    imul    edi, WSZ
    add     edi, wnd_table
    mov     bl, [edi+26]
    cmp     bl, 1
    je      .ud_w
    cmp     bl, 2
    je      .ud_t
    cmp     bl, 3
    je      .ud_b
    cmp     bl, 4
    je      .ud_m
    cmp     bl, 5
    je      .ud_d2
    cmp     bl, 6
    je      .ud_n
    cmp     bl, 7
    je      .ud_a
    cmp     bl, 8
    je      .ud_s
    cmp     bl, 9
    je      .ud_fl
    cmp     bl, 10
    je      .ud_net
    cmp     bl, 11
    je      .ud_br
    cmp     bl, 12
    je      .ud_ins
    cmp     bl, 13
    je      .ud_ex
    jmp     .ud_d
.ud_w:
    call    wp_w
    jmp     .ud_d
.ud_t:
    call    wp_t
    jmp     .ud_d
.ud_b:
    call    wp_b
    jmp     .ud_d
.ud_m:
    call    wp_m
    jmp     .ud_d
.ud_d2:
    call    wp_d
    jmp     .ud_d
.ud_n:
    call    wp_n
    jmp     .ud_d
.ud_a:
    call    wp_a
    jmp     .ud_d
.ud_s:
    call    wp_s
    jmp     .ud_d
.ud_fl:
    call    wp_fl
    jmp     .ud_d
.ud_net:
    call    wp_net
    jmp     .ud_d
.ud_br:
    call    wp_br
    jmp     .ud_d
.ud_ins:
    call    wp_ins
    jmp     .ud_d
.ud_ex:
    call    wp_ex
    jmp     .ud_d
.ud_d:
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    pop     edi
    ret

; ============================================================================
; wp_w (window proc)
; ============================================================================
wp_w:
    push    edi
    push    eax
    push    ebx
    mov     edi, [DM_HND]
    imul    edi, WSZ
    add     edi, wnd_table
    mov     ax, [DM_MSG]
    cmp     ax, WM_PAINT
    je      .ww_p
    cmp     ax, WM_LDOWN
    je      .ww_l
    cmp     ax, WM_RDOWN
    je      .ww_r
.ww_r:
    jmp     .ww_d
.ww_p:
    push    edi
    call    draw_wnd
    pop     edi
    jmp     .ww_d
.ww_l:
    ; title bar click - drag (y in DM_LP, window_y+TH threshold)
    mov     eax, [DM_LP]
    mov     ecx, [edi+4]
    add     ecx, TH
    cmp     eax, ecx
    jge     .ww_cl
    mov     eax, [DM_HND]
    mov     [drag_h], eax
    mov     eax, [DM_WP]
    mov     [drag_mx], eax
    mov     eax, [DM_LP]
    mov     [drag_my], eax
    mov     eax, [edi]
    mov     [drag_bx], eax
    mov     eax, [edi+4]
    mov     [drag_by], eax
.ww_cl:
.ww_d:
    pop     ebx
    pop     eax
    pop     edi
    ret

wp_t:
    push    edi
    push    eax
    mov     edi, [DM_HND]
    imul    edi, WSZ
    add     edi, wnd_table
    mov     ax, [DM_MSG]
    cmp     ax, WM_PAINT
    je      .wt_p
    jmp     .wt_d
.wt_p:
    call    draw_tb
.wt_d:
    pop     eax
    pop     edi
    ret

wp_b:
    push    edi
    push    eax
    push    ebx
    mov     edi, [DM_HND]
    imul    edi, WSZ
    add     edi, wnd_table
    mov     ax, [DM_MSG]
    cmp     ax, WM_PAINT
    je      .wb_p
    cmp     ax, WM_LDOWN
    je      .wb_l
    jmp     .wb_d
.wb_p:
    call    draw_btn
    jmp     .wb_d
.wb_l:
    ; fire WM_CMD to parent
    mov     bl, [edi+27]
    push    edi
    push    eax
    mov     eax, [DM_HND]
    mov     [DM_HND], eax
    mov     [DM_MSG], bx
    mov     [DM_LP], bx
    call    user_dispatch
    pop     eax
    pop     edi
.wb_d:
    pop     ebx
    pop     eax
    pop     edi
    ret

wp_m:
    push    edi
    push    eax
    push    ebx
    mov     edi, [DM_HND]
    imul    edi, WSZ
    add     edi, wnd_table
    mov     ax, [DM_MSG]
    cmp     ax, WM_PAINT
    je      .wm_p
    cmp     ax, WM_LDOWN
    je      .wm_l
    jmp     .wm_d
.wm_p:
    call    draw_menu
    jmp     .wm_d
.wm_l:
    call    menu_hit
.wm_d:
    pop     ebx
    pop     eax
    pop     edi
    ret

; ============================================================================
; draw_wnd
; ============================================================================
draw_wnd:
    push    edi
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     eax, [edi]
    mov     [vd_x], eax
    mov     eax, [edi+4]
    mov     [vd_y], eax
    mov     eax, [edi+8]
    mov     [vd_w], eax
    mov     eax, [edi+12]
    mov     [vd_h], eax
    ; title bar gradient
    push    eax
    mov     eax, [vd_y]
    mov     [vd_y], eax
    mov     eax, TH
    mov     [vd_h], eax
    mov     byte [vd_col], PN0
    mov     byte [vd_col2], PN1
    call    gdi_vgrad
    pop     eax
    mov     [vd_h], eax
    ; client
    mov     eax, [edi+4]
    add     eax, TH
    mov     [vd_y], eax
    mov     eax, [edi+12]
    sub     eax, TH
    mov     [vd_h], eax
    mov     byte [vd_col], PC
    call    gdi_rect
    ; title text - dynamic by winproc
    mov     bl, [edi+26]
    mov     esi, title_t
    cmp     bl, 5
    je      .dw_td
    cmp     bl, 6
    je      .dw_tn
    cmp     bl, 7
    je      .dw_ta
    cmp     bl, 8
    je      .dw_ts
    jmp     .dw_tr
.dw_td:
    mov     esi, title_dos_t
    jmp     .dw_tr
.dw_tn:
    mov     esi, title_note_t
    jmp     .dw_tr
.dw_ta:
    mov     esi, title_about_t
    jmp     .dw_tr
.dw_ts:
    mov     esi, title_win_t
.dw_tr:
    mov     eax, [edi]
    add     eax, 4
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, 3
    mov     [vd_y], eax
    mov     [vd_str], esi
    mov     byte [vd_col], PW
    call    gdi_text
    ; frame
    mov     eax, [edi]
    mov     [vd_x], eax
    mov     eax, [edi+4]
    mov     [vd_y], eax
    mov     eax, [edi+8]
    mov     [vd_w], eax
    mov     eax, [edi+12]
    mov     [vd_h], eax
    mov     byte [vd_ch], 1
    mov     al, PD
    mov     ah, PL
    call    gdi_frame3d
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    pop     edi
    ret

; ============================================================================
; draw_tb — taskbar
; ============================================================================
draw_tb:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi
    mov     dword [vd_x], 0
    mov     dword [vd_y], TBRY
    mov     dword [vd_w], SW
    mov     dword [vd_h], TH2
    mov     byte [vd_col], PG
    call    gdi_rect
    push    eax
    mov     al, 'R'
    out     0xE9, al
    pop     eax
    mov     dword [vd_x], 0
    mov     dword [vd_y], TBRY
    mov     dword [vd_w], SW
    mov     dword [vd_h], 1
    mov     byte [vd_col], PL
    call    gdi_rect
    call    draw_clock
    push    eax
    mov     al, 'K'
    out     0xE9, al
    pop     eax
    mov     dword [tb_x], TBX
    push    eax
    mov     al, 'L'
    out     0xE9, al
    pop     eax
    mov     ecx, 0
.tb_w:
    cmp     ecx, MAXW
    jge     .tb_d
    push    ecx
    mov     edi, ecx
    imul    edi, WSZ
    add     edi, wnd_table
    mov     bl, [edi+24]
    cmp     bl, WS_HID
    je      .tb_n
    mov     bl, [edi+26]
    cmp     bl, 0
    je      .tb_n
    cmp     bl, 2
    je      .tb_n
    cmp     bl, 3
    je      .tb_n
    cmp     bl, 4
    je      .tb_n
    cmp     bl, 8
    je      .tb_n
    mov     eax, [tb_x]
    mov     [vd_x], eax
    mov     dword [vd_y], TBRY+2
    mov     dword [vd_w], TBW
    mov     dword [vd_h], TBH
    mov     byte [vd_col], PC
    call    gdi_rect
    mov     byte [vd_ch], 1
    mov     al, PD
    mov     ah, PL
    call    gdi_frame3d
    add     dword [tb_x], TBW+2
.tb_n:
    pop     ecx
    inc     ecx
    jmp     .tb_w
.tb_d:
    push    eax
    mov     al, 'E'
    out     0xE9, al
    pop     eax
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; draw_btn — button
; ============================================================================
draw_btn:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi
    mov     eax, [edi]
    mov     [vd_x], eax
    mov     eax, [edi+4]
    mov     [vd_y], eax
    mov     eax, [edi+8]
    mov     [vd_w], eax
    mov     eax, [edi+12]
    mov     [vd_h], eax
    mov     bl, [edi+27]
    cmp     bl, B_ST
    je      .db_s
    cmp     bl, B_CL
    je      .db_c
    cmp     bl, B_MX
    je      .db_m
    cmp     bl, B_MN
    je      .db_n
    mov     byte [vd_col], PG
    jmp     .db_f
.db_s:
    mov     byte [vd_col], PG
    jmp     .db_f
.db_c:
    mov     byte [vd_col], PR
    jmp     .db_hov
.db_m:
    mov     byte [vd_col], PGN
    jmp     .db_hov
.db_n:
    mov     byte [vd_col], PY
.db_hov:
    ; Phase B: invert to white when this button is hovered
    mov     al, [hover_btn]
    cmp     al, bl
    jne     .db_f
    mov     byte [vd_col], PW
.db_f:
    call    gdi_rect
    mov     byte [vd_ch], 1
    mov     al, PD
    mov     ah, PL
    call    gdi_frame3d
    cmp     bl, B_ST
    je      .db_ss
    cmp     bl, B_CL
    je      .db_cc
    cmp     bl, B_MX
    je      .db_mm
    cmp     bl, B_MN
    je      .db_nn
    jmp     .db_l
.db_ss:
    mov     eax, [edi]
    add     eax, 12
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, 3
    mov     [vd_y], eax
    mov     esi, start_t
    mov     [vd_str], esi
    mov     byte [vd_col], PW
    call    gdi_text
    jmp     .db_l
.db_cc:
    mov     esi, btn_close_c
    jmp     .db_cl
.db_nn:
    mov     esi, btn_min_c
.db_cl:
    mov     eax, [edi]
    add     eax, 4
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, 2
    mov     [vd_y], eax
    mov     [vd_str], esi
    mov     byte [vd_col], PW
    call    gdi_char
    jmp     .db_l
.db_mm:
    mov     eax, [edi]
    add     eax, 5
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, 5
    mov     [vd_y], eax
    mov     dword [vd_w], 4
    mov     dword [vd_h], 4
    mov     byte [vd_col], PW
    call    gdi_rect
.db_l:
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; draw_menu — start menu (7 items)
; ============================================================================
draw_menu:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi
    push    esi
    mov     dword [vd_x], MNX
    mov     dword [vd_y], MNY
    mov     dword [vd_w], MNW
    mov     dword [vd_h], MNH
    mov     byte [vd_col], MNU
    call    gdi_rect
    mov     byte [vd_ch], 1
    mov     al, PD
    mov     ah, PL
    call    gdi_frame3d
    mov     ecx, 0
.dm_i:
    cmp     ecx, 7
    jge     .dm_d
    mov     eax, MNY
    add     eax, ecx
    imul    eax, MIH
    add     eax, 2
    mov     [vd_y], eax
    mov     dword [vd_x], MNX + 4
    mov     esi, mnu_t1
    cmp     ecx, 0
    je      .dm_u
    mov     esi, mnu_t2
    cmp     ecx, 1
    je      .dm_u
    mov     esi, mnu_t3
    cmp     ecx, 2
    je      .dm_u
    mov     esi, mnu_t4
    cmp     ecx, 3
    je      .dm_u
    mov     esi, mnu_t5
    cmp     ecx, 4
    je      .dm_u
    mov     esi, mnu_t6
    cmp     ecx, 5
    je      .dm_u
    mov     esi, mnu_t7
.dm_u:
    mov     [vd_str], esi
    mov     byte [vd_col], PW
    call    gdi_text
    inc     ecx
    jmp     .dm_i
.dm_d:
    pop     esi
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; menu_hit — hit test menu items, execute action
; ============================================================================
menu_hit:
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     eax, [mou_x]
    mov     ebx, [mou_y]
    mov     ecx, 0
.mh_l:
    cmp     ecx, 7
    jge     .mh_d
    mov     edx, MNY
    add     edx, ecx
    imul    edx, MIH
    add     edx, 2
    cmp     ebx, edx
    jl      .mh_n
    add     edx, MIH
    cmp     ebx, edx
    jge     .mh_n
    cmp     eax, MNX
    jl      .mh_n
    cmp     eax, MNX + MNW
    jge     .mh_n
    mov     dword [menu_sel], ecx
    mov     dword [menu_vis], 0
    mov     eax, WM
    call    DestroyWindow
    cmp     ecx, 0
    je      .mh_dos
    cmp     ecx, 1
    je      .mh_note
    cmp     ecx, 2
    je      .mh_file
    cmp     ecx, 3
    je      .mh_net
    cmp     ecx, 4
    je      .mh_trash
    cmp     ecx, 5
    je      .mh_new
    cmp     ecx, 6
    je      .mh_shut
    jmp     .mh_d
.mh_dos:
    jmp     .mh_d
.mh_note:
    mov     dword [CW_HND], WN
    mov     dword [CW_X], 60
    mov     dword [CW_Y], 50
    mov     dword [CW_W], 180
    mov     dword [CW_H], 100
    mov     byte [CW_WP], 6
    mov     byte [CW_BI], 0
    call    CreateWindow
    mov     dword [kbd_focus], WN
    mov     byte [note_dirty], 1
    mov     dword [CW_HND], WN
    mov     dword [CW_MSG], WM_PAINT
    call    user_dispatch
    jmp     .mh_d
.mh_file:
    mov     dword [CW_HND], WFL
    mov     dword [CW_X], 30
    mov     dword [CW_Y], 30
    mov     dword [CW_W], 240
    mov     dword [CW_H], 100
    mov     byte [CW_WP], 9
    mov     byte [CW_BI], 0
    call    CreateWindow
    mov     byte [fs_cur_dir], 0xFF
    mov     dword [CW_HND], WFL
    mov     dword [CW_MSG], WM_PAINT
    call    user_dispatch
    jmp     .mh_d
.mh_net:
    mov     dword [CW_HND], WNET
    mov     dword [CW_X], 50
    mov     dword [CW_Y], 30
    mov     dword [CW_W], 220
    mov     dword [CW_H], 90
    mov     byte [CW_WP], 10
    mov     byte [CW_BI], 0
    call    CreateWindow
    mov     dword [CW_HND], WNET
    mov     dword [CW_MSG], WM_PAINT
    call    user_dispatch
    jmp     .mh_d
.mh_trash:
    ; Open file browser filtered to deleted
    mov     byte [fs_cur_dir], 0xFE  ; 0xFE = trash special view
    mov     dword [CW_HND], WFL
    mov     dword [CW_X], 40
    mov     dword [CW_Y], 50
    mov     dword [CW_W], 220
    mov     dword [CW_H], 100
    mov     byte [CW_WP], 9
    mov     byte [CW_BI], 0
    call    CreateWindow
    mov     dword [CW_HND], WFL
    mov     dword [CW_MSG], WM_PAINT
    call    user_dispatch
    jmp     .mh_d
.mh_new:
    ; Simple new file: create "newfile.txt" in root
    mov     byte [fs_cur_dir], 0xFF
    mov     ebp, newfn_t
    mov     ch, FS_TYPE_FILE_TXT
    call    fs_create
    ; If success, refresh desktop icons
    test    eax, eax
    jz      .mh_d
    mov     byte [fs_dirty], 1
    jmp     .mh_d
.mh_shut:
    mov     dword [CW_HND], WSH
    mov     dword [CW_X], 40
    mov     dword [CW_Y], 40
    mov     dword [CW_W], 240
    mov     dword [CW_H], 100
    mov     byte [CW_WP], 8
    mov     byte [CW_BI], 0
    call    CreateWindow
    mov     dword [CW_HND], WSH
    mov     dword [CW_MSG], WM_PAINT
    call    user_dispatch
.mh_n:
    inc     ecx
    jmp     .mh_l
.mh_d:
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; ctx_hit — hit test context menu, execute action
; ============================================================================
ctx_hit:
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     eax, [mou_x]
    mov     ebx, [mou_y]
    mov     ecx, 0
.ch_l:
    cmp     ecx, 3
    jge     .ch_d
    mov     edx, [ctx_y]
    add     edx, ecx
    imul    edx, CTXI
    add     edx, 2
    cmp     ebx, edx
    jl      .ch_n
    add     edx, CTXI
    cmp     ebx, edx
    jge     .ch_n
    cmp     eax, [ctx_x]
    jl      .ch_n
    mov     edx, [ctx_x]
    add     edx, CTXW
    cmp     eax, edx
    jge     .ch_n
    mov     dword [ctx_vis], 0
    cmp     ecx, 0
    je      .ch_ref
    cmp     ecx, 1
    je      .ch_prp
    cmp     ecx, 2
    je      .ch_ext
    jmp     .ch_d
.ch_ref:
    call    draw_desktop
    call    draw_icons
    call    redraw_all
    call    gdi_flip
    jmp     .ch_d
.ch_prp:
    mov     dword [CW_HND], WA2
    mov     dword [CW_X], 80
    mov     dword [CW_Y], 40
    mov     dword [CW_W], 160
    mov     dword [CW_H], 80
    mov     byte [CW_WP], 7
    mov     byte [CW_BI], 0
    call    CreateWindow
    mov     dword [CW_HND], WA2
    mov     dword [CW_MSG], WM_PAINT
    call    user_dispatch
    jmp     .ch_d
.ch_ext:
    mov     dword [CW_HND], WSH
    mov     dword [CW_X], 40
    mov     dword [CW_Y], 40
    mov     dword [CW_W], 240
    mov     dword [CW_H], 100
    mov     byte [CW_WP], 8
    mov     byte [CW_BI], 0
    call    CreateWindow
    mov     dword [CW_HND], WSH
    mov     dword [CW_MSG], WM_PAINT
    call    user_dispatch
    jmp     .ch_n
.ch_n:
    inc     ecx
    jmp     .ch_l
.ch_d:
    mov     dword [ctx_vis], 0
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; draw_clock — HH:MM at [CLKX][CLKY]
; ============================================================================
draw_clock:
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     eax, [vtd_t]
    xor     edx, edx
    mov     ecx, 1193
    div     ecx
    mov     ebx, eax
    xor     edx, edx
    mov     ecx, 60
    div     ecx
    mov     ecx, eax
    xor     edx, edx
    mov     ebx, 24
    div     ebx
    mov     [clk_h], al
    mov     [clk_m], dl
    mov     bl, [clk_h]
    xor     edx, edx
    mov     al, bl
    mov     ebx, 10
    div     ebx
    add     al, '0'
    mov     [clk_str], al
    add     ah, '0'
    mov     [clk_str+1], ah
    mov     byte [clk_str+2], ':'
    mov     bl, [clk_m]
    xor     edx, edx
    mov     eax, ebx
    mov     ebx, 10
    div     ebx
    add     al, '0'
    mov     [clk_str+3], al
    add     ah, '0'
    mov     [clk_str+4], ah
    mov     byte [clk_str+5], 0
    mov     dword [vd_x], CLKX
    mov     dword [vd_y], CLKY
    mov     esi, clk_str
    mov     [vd_str], esi
    mov     byte [vd_col], PW
    call    gdi_text
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; draw_icons — 2 desktop icons
; ============================================================================
draw_icons:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi
    push    esi
    call    draw_icons_fs
    pop     esi
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; wp_d — DOS prompt window proc
; ============================================================================
wp_d:
    ret

; ============================================================================
; wp_n — Notepad window proc
; ============================================================================
wp_n:
    push    edi
    push    eax
    mov     edi, [DM_HND]
    imul    edi, WSZ
    add     edi, wnd_table
    mov     ax, [DM_MSG]
    cmp     ax, WM_PAINT
    je      .wn_p
    jmp     .wn_d
.wn_p:
    call    draw_note
.wn_d:
    pop     eax
    pop     edi
    ret

; ============================================================================
; wp_a — About dialog proc
; ============================================================================
wp_a:
    ret

; ============================================================================
; wp_s — Shutdown window proc
; ============================================================================
wp_s:
    ret

; ============================================================================
; wp_fl — File browser window proc
; ============================================================================
wp_fl:
    push    edi
    push    eax
    mov    edi,[DM_HND]
    imul    edi, WSZ
    add     edi, wnd_table
    mov     ax, [DM_MSG]
    cmp     ax, WM_PAINT
    je      .wf_p
    jmp     .wf_d
.wf_p:
    call    draw_fl
.wf_d:
    pop     eax
    pop     edi
    ret

; ============================================================================
; wp_net — Network window proc
; ============================================================================
wp_net:
    push    edi
    push    eax
    mov    edi,[DM_HND]
    imul    edi, WSZ
    add     edi, wnd_table
    mov     ax, [DM_MSG]
    cmp     ax, WM_PAINT
    je      .wnet_p
    jmp     .wnet_d
.wnet_p:
    call    net_draw
.wnet_d:
    pop     eax
    pop     edi
    ret

; ============================================================================
; wp_br — Browser window proc
; ============================================================================
wp_br:
    push    edi
    push    eax
    mov    edi,[DM_HND]
    imul    edi, WSZ
    add     edi, wnd_table
    mov     ax, [DM_MSG]
    cmp     ax, WM_PAINT
    je      .wbr_p
    jmp     .wbr_d
.wbr_p:
    call    draw_br
.wbr_d:
    pop     eax
    pop     edi
    ret

; ============================================================================
; wp_ins — Installer window proc
; ============================================================================
wp_ins:
    push    edi
    push    eax
    mov    edi,[DM_HND]
    imul    edi, WSZ
    add     edi, wnd_table
    mov     ax, [DM_MSG]
    cmp     ax, WM_PAINT
    je      .wins_p
    jmp     .wins_d
.wins_p:
    call    draw_ins
.wins_d:
    pop     eax
    pop     edi
    ret

; ============================================================================
; wp_ex — EXE Runner window proc
; ============================================================================
wp_ex:
    push    edi
    push    eax
    mov    edi,[DM_HND]
    imul    edi, WSZ
    add     edi, wnd_table
    mov     ax, [DM_MSG]
    cmp     ax, WM_PAINT
    je      .wex_p
    jmp     .wex_d
.wex_p:
    call    draw_ex
.wex_d:
    pop     eax
    pop     edi
    ret

; ============================================================================
; draw_dos — DOS window content
; ============================================================================
; ============================================================================
; draw_note — Notepad content
; ============================================================================
draw_note:
    call    note_draw
    ret

; ============================================================================
; draw_about — About dialog content
; ============================================================================
draw_about:
    ret

; ============================================================================
; draw_shutdown — Shutdown window content
; ============================================================================
draw_shutdown:
    ret

; ============================================================================
; mou_handle — real mouse click after VIN ends
; ============================================================================
mou_handle:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi
    ; left down edge
    mov     al, [mou_lb]
    cmp     al, [prev_lb]
    je      .mh_lup
    test    al, al
    jz      .mh_lup
    mov     al, [ctx_vis]
    test    al, al
    jz      .mh_nctx
    call    ctx_hit
    jmp     .mh_chk
.mh_nctx:
    call    hit_test
.mh_chk:
    cmp     eax, -1
    je      .mh_nb
    mov     [evt_hnd], eax
    mov     [DM_HND], eax
    mov     word [DM_MSG], WM_LDOWN
    ; Set keyboard focus: check if clicked window is a DOS window (winproc 7)
    mov     edi, eax
    imul    edi, WSZ
    add     edi, wnd_table
    mov     bl, [edi+26]
    cmp     bl, 5
    je      .mh_dos
    cmp     bl, 6
    je      .mh_note
    cmp     bl, 11
    je      .mh_br
    jmp     .mh_nb
.mh_note:
    mov     [kbd_focus], eax
    mov     byte [note_dirty], 1
    call    user_dispatch
    jmp     .mh_nb
.mh_dos:
    jmp     .mh_nb
.mh_br:
    ; Check if click is on download button
    mov     bl, [edi+26]
    cmp     bl, 11
    je      .mh_brdl
    jmp     .mh_nb
.mh_brdl:
    mov     eax, [edi]          ; win_x
    mov     edx, [edi+4]        ; win_y
    mov     ecx, [mou_x]
    sub     ecx, eax
    cmp     ecx, 20
    jl      .mh_nb
    cmp     ecx, 80
    jge     .mh_nb
    mov     ecx, [mou_y]
    sub     ecx, edx
    cmp     ecx, TH + 40
    jl      .mh_nb
    cmp     ecx, TH + 56
    jge     .mh_nb
    ; Download button clicked → create installer
    mov     dword [CW_HND], WIN
    mov     dword [CW_X], 100
    mov     dword [CW_Y], 80
    mov     dword [CW_W], 160
    mov     dword [CW_H], 60
    mov     byte [CW_WP], 12
    mov     byte [CW_BI], 0
    call    CreateWindow
    mov     byte [ins_state], 1
    mov     byte [ins_prog], 0
    mov     dword [CW_HND], WIN
    mov     dword [CW_MSG], WM_PAINT
    call    user_dispatch
    jmp     .mh_nb
.mh_nb:
    mov     byte [prev_lb], al
    ; ---------- P1.6: desktop icon hit-test for double-click launch ----------
    ; If user clicked the desktop (evt_hnd=-1, no window hit) and the slot is
    ; an EXE, arm the runner.  run_prog = idx, pe_state = 0 (Priority 0.5
    ; path from file_contents_pool).  The actual exe_load happens on the next
    ; main_loop tick (pe_pending_run dispatch below) to avoid deep nesting.
    cmp     dword [evt_hnd], -1
    jne     .mh_rb
    call    fs_hit_test            ; eax = file_table index or -1
    cmp     eax, -1
    je      .mh_rb
    mov     ebx, eax                ; preserve idx across dbg_puts
    ; Only exe entries are runnable this way
    mov     ecx, ebx
    imul    ecx, FS_SZ
    add     ecx, file_table
    cmp     byte [ecx + 16], FS_TYPE_FILE_EXE
    jne     .mh_rb
    ; Arm runner
    mov     [run_prog], bl
    mov     byte [pe_state], 0
    mov     byte [pe_pending_run], 1
    push    eax
    dbg_puts "[A4X] fs_icon: dblclick run_prog=", 0
    mov     eax, ebx
    call    .p16_h8
    dbg_puts 13, 10, 0
    pop     eax
    jmp     .mh_rb
.p16_h8:
    dbg_hex8
    ret
.mh_lup:
    mov     al, [mou_lb]
    cmp     al, [prev_lb]
    je      .mh_rb
    test    al, al
    jne     .mh_rb
    mov     eax, [evt_hnd]
    cmp     eax, -1
    je      .mh_rb
    mov     [DM_HND], eax
    mov     word [DM_MSG], WM_LUP
    call    user_dispatch
    mov     byte [prev_lb], al
.mh_rb:
    mov     al, [mou_rb]
    cmp     al, [prev_rb]
    je      .mh_ru
    test    al, al
    jz      .mh_ru
    mov     eax, [mou_x]
    mov     dword [ctx_x], eax
    mov     eax, [mou_y]
    mov     dword [ctx_y], eax
    mov     dword [ctx_vis], 1
    mov     byte [prev_rb], al
    jmp     .mh_d2
.mh_ru:
    mov     al, [mou_rb]
    cmp     al, [prev_rb]
    je      .mh_d2
    test    al, al
    jne     .mh_d2
    mov     dword [ctx_vis], 0
    mov     byte [prev_rb], al
.mh_d2:
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; fs_hit_test — P1.6: desktop icon rectangle hit test
; Mirrors draw_icons_fs layout exactly:  3 rows × 2 columns, max 6 visible
; slots (skipping deleted).  Each icon rect: ICO_W × (ICO_H + 2 + 8) to
; include the 8×8 text label below.
; IN:  mou_x, mou_y  (global mouse coordinates in pixels)
; OUT: eax = file_table index (0..FS_MAXF-1) on hit, -1 otherwise
; Clobbers: eax ebx ecx edx edi
; ============================================================================
fs_hit_test:
    push    esi
    mov     eax, -1
    ; Walk file_table in the SAME order as draw_icons_fs to keep the slot→
    ; position mapping stable.
    mov     ecx, 0                  ; visible counter (0..5 max)
    mov     esi, file_table
    mov     ebx, FS_MAXF
.fht_scan:
    test    ebx, ebx
    jz      .fht_done
    test    byte [esi + 21], FS_FLG_DELETED
    jnz     .fht_next
    cmp     ecx, 6                  ; max 6 icons (3 rows × 2 cols)
    jge     .fht_next
    ; Compute row/col for this visible counter
    ;   col 0 → x = ICONX1 (12)
    ;   col 1 → x = ICONX1 + 100 = 112
    ;   row n → y = ICONY1 + n*60 (n = 0..2; 3 rows)
    mov     edx, ecx
    cmp     edx, 3
    jl      .fht_col0
    sub     edx, 3                  ; row = ecx - 3
    mov     edi, ICONX1 + 100       ; col 1
    jmp     .fht_calc
.fht_col0:
    ; edx = row (0,1,2)
    mov     edi, ICONX1             ; col 0
.fht_calc:
    imul    eax, edx, 60
    add     eax, ICONY1             ; eax = y1 (top of icon)
    ; rect is x1..x1+ICO_W, y1..y1+(ICO_H+2+8)   (label area 10px below icon)
    ; Also extend x by 6 pixels left/right for imprecise clicks
    mov     ecx, edi                ; x1
    sub     ecx, 4
    cmp     [mou_x], ecx
    jl      .fht_miss
    lea     ecx, [edi + ICO_W + 4]  ; x2 = x1 + 16 + 4
    cmp     [mou_x], ecx
    jge     .fht_miss
    mov     ecx, eax                ; y1
    sub     ecx, 2
    cmp     [mou_y], ecx
    jl      .fht_miss
    lea     ecx, [eax + ICO_H + 2 + 10]  ; y2 = y1 + 16 + 2 + label
    cmp     [mou_y], ecx
    jge     .fht_miss
    ; Hit!  Return file_table index = (esi - file_table) / FS_SZ
    mov     eax, esi
    sub     eax, file_table
    mov     edx, FS_SZ
    div     dl                      ; al = index
    movzx   eax, al
    pop     esi
    ret
.fht_miss:
.fht_next:
    inc     ecx                     ; visible counter advances regardless
    add     esi, FS_SZ
    dec     ebx
    jmp     .fht_scan
.fht_done:
    mov     eax, -1
    pop     esi
    ret

; ============================================================================
; hit_test
; ============================================================================
hit_test:
    push    edi
    push    ebx
    push    ecx
    push    edx
    mov     eax, -1
    mov     ecx, MAXW
    dec     ecx
.ht_l:
    cmp     ecx, 0
    jl      .ht_d
    mov     edi, ecx
    imul    edi, WSZ
    add     edi, wnd_table
    mov     bl, [edi+24]
    cmp     bl, WS_NORM
    jne     .ht_n
    mov     edx, [mou_x]
    cmp     edx, [edi]
    jl      .ht_n
    mov     ebx, [edi]
    add     ebx, [edi+8]
    cmp     edx, ebx
    jge     .ht_n
    mov     edx, [mou_y]
    cmp     edx, [edi+4]
    jl      .ht_n
    mov     ebx, [edi+4]
    add     ebx, [edi+12]
    cmp     edx, ebx
    jge     .ht_n
    mov     eax, ecx
    jmp     .ht_d
.ht_n:
    dec     ecx
    jmp     .ht_l
.ht_d:
    pop     edx
    pop     ecx
    pop     ebx
    pop     edi
    ret

; ============================================================================
; tb_hit — Phase B: taskbar button hit test, toggle min/restore
;   Walks wnd_table in the same order as draw_tb to find the Nth visible
;   taskbar-eligible window, then toggles its state WS_MIN <-> WS_NORM.
; ============================================================================
tb_hit:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi
    push    esi
    mov     eax, [mou_y]
    cmp     eax, TBRY+2
    jl      .th_d
    cmp     eax, TBRY+2+TBH
    jge     .th_d
    mov     eax, [mou_x]
    cmp     eax, TBX
    jl      .th_d
    sub     eax, TBX
    xor     edx, edx
    mov     ebx, TBW+2
    div     ebx                ; eax = btn_idx, edx = remainder
    cmp     edx, TBW
    jge     .th_d              ; in gutter between buttons
    mov     esi, eax           ; esi = target btn_idx
    xor     ecx, ecx           ; ecx = btn_count
    xor     edi, edi           ; edi = wnd index
.th_l:
    cmp     edi, MAXW
    jge     .th_d
    mov     ebx, edi
    imul    ebx, WSZ
    add     ebx, wnd_table
    mov     al, [ebx+24]
    cmp     al, WS_HID
    je      .th_n
    mov     al, [ebx+26]
    cmp     al, 0
    je      .th_n
    cmp     al, 2
    je      .th_n
    cmp     al, 3
    je      .th_n
    cmp     al, 4
    je      .th_n
    cmp     al, 8
    je      .th_n
    cmp     ecx, esi
    jne     .th_inc
    mov     al, [ebx+24]
    cmp     al, WS_MIN
    jne     .th_nox
    ; Restore from minimized (geometry was preserved by min button)
    mov     byte [ebx+24], WS_NORM
    jmp     .th_d
.th_nox:
    cmp     al, WS_MAX
    je      .th_d              ; maximized: ignore (use max button to restore first)
    ; WS_NORM -> minimize (geometry stays, restored later by another click)
    mov     byte [ebx+24], WS_MIN
    jmp     .th_d
.th_inc:
    inc     ecx
.th_n:
    inc     edi
    jmp     .th_l
.th_d:
    pop     esi
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; drag_update
; ============================================================================
drag_update:
    push    edi
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     eax, [drag_h]
    cmp     eax, -1
    je      .du_d
    cmp     eax, MAXW
    jge     .du_d
    mov     edi, eax
    imul    edi, WSZ
    add     edi, wnd_table
    ; update x: new = drag_bx + (mou_x - drag_mx)
    mov     eax, [mou_x]
    sub     eax, [drag_mx]
    add     eax, [drag_bx]
    cmp     eax, 0
    jge     .du_x
    xor     eax, eax
.du_x:
    cmp     eax, 200
    jle     .du_xs
    mov     eax, 200
.du_xs:
    mov     [edi], eax
    ; update y: new = drag_by + (mou_y - drag_my)
    mov     eax, [mou_y]
    sub     eax, [drag_my]
    add     eax, [drag_by]
    cmp     eax, 0
    jge     .du_y
    xor     eax, eax
.du_y:
    cmp     eax, 150
    jle     .du_ys
    mov     eax, 150
.du_ys:
    mov     [edi+4], eax
    ; update title buttons position
    mov     eax, [edi]
    add     eax, [edi+8]
    sub     eax, BS + 2
    mov     ecx, WBN
    imul    ecx, WSZ
    add     ecx, wnd_table
    mov     [ecx], eax
    sub     eax, BS + 2
    mov     ecx, WBM
    imul    ecx, WSZ
    add     ecx, wnd_table
    mov     [ecx], eax
    sub     eax, BS + 2
    mov     ecx, WBC
    imul    ecx, WSZ
    add     ecx, wnd_table
    mov     [ecx], eax
    dbg_puts "[A4X] window moved", 13, 10, 0
.du_d:
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    pop     edi
    ret

; ============================================================================
; gdi_cursor — arrow
; ============================================================================
gdi_cursor:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi
    push    esi
    mov     esi, cur_bmp
    xor     ebx, ebx
    mov     edx, 8
.gc_r:
    lodsb
    push    edx
    mov     edx, 8
    mov     edi, [mou_y]
    add     edi, ebx
    imul    edi, SW
    add     edi, [mou_x]
    add     edi, LFB
.gc_c:
    test    al, 0x80
    jz      .gc_s
    mov     byte [edi], PW
.gc_s:
    shl     al, 1
    inc     edi
    dec     edx
    jnz     .gc_c
    pop     edx
    inc     ebx
    dec     edx
    jnz     .gc_r
    pop     esi
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

cur_bmp:
    db 0x00, 0x80, 0xC0, 0xE0, 0xF0, 0xF8, 0xFC, 0xFE

; ============================================================================
; context_menu_draw
; ============================================================================
ctx_draw:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi
    mov     eax, [ctx_x]
    mov     [vd_x], eax
    mov     eax, [ctx_y]
    mov     [vd_y], eax
    mov     dword [vd_w], CTXW
    mov     dword [vd_h], CTXH
    mov     byte [vd_col], MNU
    call    gdi_rect
    mov     byte [vd_ch], 1
    mov     al, PD
    mov     ah, PL
    call    gdi_frame3d
    mov     eax, [ctx_x]
    add     eax, 4
    mov     dword [vd_x], eax
    mov     eax, [ctx_y]
    add     eax, 2
    mov     dword [vd_y], eax
    mov     esi, ctx_t1
    mov     [vd_str], esi
    mov     byte [vd_col], PW
    call    gdi_text
    mov     eax, [ctx_x]
    add     eax, 4
    mov     dword [vd_x], eax
    mov     eax, [ctx_y]
    add     eax, CTXI + 2
    mov     [vd_y], eax
    mov     esi, ctx_t2
    mov     [vd_str], esi
    call    gdi_text
    mov     eax, [ctx_x]
    add     eax, 4
    mov     dword [vd_x], eax
    mov     eax, [ctx_y]
    add     eax, CTXI*2 + 2
    mov     [vd_y], eax
    mov     esi, ctx_t3
    mov     [vd_str], esi
    call    gdi_text
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; vtd_init
; ============================================================================
vtd_init:
    push    eax
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
    mov     al, 0xF5          ; enable IRQ0(PIT), IRQ2(cascade); mask all others
    out     0x21, al
    mov     al, 0xFF
    out     0xA1, al
    mov     al, 0x36
    out     0x43, al
    mov     ax, 10
    out     0x40, al
    mov     al, ah
    out     0x40, al
    xor     eax, eax
    mov     [vtd_t], eax
    pop     eax
    ret

vtd_isr:
    pushad
    push    ds
    push    es
    mov     ax, SEL_D0
    mov     ds, ax
    mov     es, ax
    inc     dword [vtd_t]
    mov     al, 0x20
    out     0x20, al
    pop     es
    pop     ds
    popad
    iretd

; ============================================================================
; mou_init
; ============================================================================
mou_init:
    push    eax
    push    ecx
    mov     al, 0xA8
    out     0x64, al
    in      al, 0xA1
    and     al, 0xEF
    out     0xA1, al
    mov     dword [mou_x], 160
    mov     dword [mou_y], 100
    mov     byte [mou_lb], 0
    mov     byte [mou_rb], 0
    mov     byte [mou_bc], 0
    mov     dword [mou_pk], 0
    pop     ecx
    pop     eax
    ret

; ============================================================================
; mou_isr — PS/2 IRQ12, 3-byte packet
; ============================================================================
mou_isr:
    pushad
    push    ds
    push    es
    mov     ax, SEL_D0
    mov     ds, ax
    mov     es, ax
    in      al, 0x60
    mov     [mou_byte], al
    mov     al, [mou_bc]
    inc     al
    cmp     al, 1
    je      .m1
    cmp     al, 2
    je      .m2
    ; byte 3 = Y delta
    mov     al, [mou_byte]
    push    eax
    ; sign-extend Y
    mov     al, [mou_byte]
    mov     bl, al
    and     bl, 0x80
    jz      .mys
    mov     byte [mou_yr], 0xFF
    jmp     .myd
.mys:
    mov     byte [mou_yr], 0
.myd:
    pop     eax
    add     [mou_y], eax
    mov     al, [mou_bc]
    mov     byte [mou_bc], 0
    mov     byte [mou_lb], 0
    jmp     .meoi
.m2:
    ; byte 2 = X delta
    mov     al, [mou_byte]
    mov     [mou_xr], al
    inc     byte [mou_bc]
    jmp     .meoi
.m1:
    ; byte 1 = status byte
    mov     al, [mou_byte]
    test    al, 1
    jz      .mnolb
    mov     byte [mou_lb], 1
    jmp     .mnob2
.mnolb:
    mov     byte [mou_lb], 0
.mnob2:
    test    al, 4
    jz      .mnor
    mov     byte [mou_rb], 1
    jmp     .moinc
.mnor:
    mov     byte [mou_rb], 0
.moinc:
    inc     byte [mou_bc]
    jmp     .meoi
.meoi:
    ; clamp
    cmp     dword [mou_x], 0
    jge     .cx
    mov     dword [mou_x], 0
.cx:
    cmp     dword [mou_x], 319
    jle     .cy
    mov     dword [mou_x], 319
.cy:
    cmp     dword [mou_y], 0
    jge     .cy2
    mov     dword [mou_y], 0
.cy2:
    cmp     dword [mou_y], 199
    jle     .cn
    mov     dword [mou_y], 199
.cn:
    inc     dword [mou_pk]
    ; EOI
    mov     al, 0x20
    out     0x20, al
    out     0xA0, al
    pop     es
    pop     ds
    popad
    iretd

; ============================================================================
; kbd_init — enable 8042 keyboard, set default focus
; ============================================================================
kbd_init:
    push    eax
    push    edx
    ; Enable keyboard interface (bit 0 of 0x64 command byte)
    mov     al, 0xAE
    out     0x64, al
    ; Enable IRQ1 in PIC
    in      al, 0x21
    and     al, 0xFE
    out     0x21, al
    ; Initialize state
    xor     eax, eax
    mov     [kbd_sc], eax
    mov     [kbd_ascii], eax
    mov     [kbd_shift], eax
    mov     [kbd_caps], eax
    mov     [kbd_break], eax
    mov     [kbd_have], eax
    mov     [kbd_focus], eax
    dec     [kbd_focus]       ; = -1
    pop     edx
    pop     eax
    ret

; ============================================================================
; kbd_isr — IRQ1, PS/2 keyboard scan code
; ============================================================================
kbd_isr:
    pushad
    push    ds
    push    es
    mov     ax, SEL_D0
    mov     ds, ax
    mov     es, ax
    in      al, 0x60
    test    byte [kbd_break], 1
    jnz     .kb_brk
    ; Make code
    cmp     al, 0x2A
    je      .kb_ls
    cmp     al, 0x36
    je      .kb_rs
    cmp     al, 0x3C
    je      .kb_cap
    mov     [kbd_sc], al
    mov     byte [kbd_have], 1
    jmp     .kb_eoi
.kb_ls:
    mov     byte [kbd_shift], 1
    jmp     .kb_eoi
.kb_rs:
    mov     byte [kbd_shift], 1
    jmp     .kb_eoi
.kb_cap:
    xor     byte [kbd_caps], 1
.kb_eoi:
    mov     al, 0x20
    out     0x20, al
    pop     es
    pop     ds
    popad
    iretd
.kb_brk:
    cmp     al, 0x2A
    je      .kb_ls_r
    cmp     al, 0x36
    je      .kb_rs_r
    jmp     .kb_clr
.kb_ls_r:
    mov     byte [kbd_shift], 0
    jmp     .kb_clr
.kb_rs_r:
    mov     byte [kbd_shift], 0
.kb_clr:
    xor     byte [kbd_break], 1
    jmp     .kb_eoi

; ============================================================================
; kbd_scan — process one keystroke, dispatch to focused window
; ============================================================================
kbd_scan:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi
    test    byte [kbd_have], 1
    jz      .ks_d
    mov     al, [kbd_sc]
    test    al, al
    jz      .ks_d
    ; Look up ASCII based on shift state
    test    byte [kbd_shift], 1
    jz      .ks_l
    mov     ebx, kbd_at2
    jmp     .ks_lu
.ks_l:
    mov     ebx, kbd_at1
.ks_lu:
    movzx   eax, al
    mov     al, [ebx + eax]
    test    al, al
    jz      .ks_d
    ; Handle CapsLock for letters (0x41-0x5A uppercase)
    cmp     al, 'A'
    jl      .ks_st
    cmp     al, 'Z'
    jg      .ks_st
    test    byte [kbd_caps], 1
    jnz     .ks_st
    add     al, 32
.ks_st:
    mov     [kbd_ascii], al
    mov     byte [kbd_have], 1
    ; Dispatch to focused window
    mov     eax, [kbd_focus]
    cmp     eax, WD
    je      .ks_dos
    cmp     eax, WN
    je      .ks_note
    jmp     .ks_d
.ks_dos:
    mov     [DM_HND], eax
    mov     word [DM_MSG], WM_KEY
    call    user_dispatch
    jmp     .ks_d
.ks_note:
    ; Set DM_HND for notepad dispatch
    mov     [DM_HND], WN
    call    notepad_key
.ks_d:
    xor     eax, eax
    mov     [kbd_sc], eax
    mov     [kbd_ascii], eax
    mov     [kbd_have], eax
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; dos_puts — write null-terminated string to DOS text buffer
; ============================================================================
dos_puts:
    ret

; ============================================================================
; dos_prompt — print "C:\>" at current cursor position
; ============================================================================
dos_prompt:
    ret

; ============================================================================
; dos_scroll — scroll DOS text buffer up one row
; ============================================================================
dos_scroll:
    ret

; ============================================================================
; dos_clear — clear DOS text buffer, reset cursor
; ============================================================================
dos_clear:
    ret

; ============================================================================
; dos_init — initialize DOS text buffer with welcome message
; ============================================================================
dos_init:
    ret

; ============================================================================
; dos_exec — DOS command interpreter
; ============================================================================
dos_exec:
    ret

; ============================================================================
; draw_dos — DOS window content (text grid + cursor)
; ============================================================================
draw_dos:
    ret
; ============================================================================
; draw_br — Browser window content
; ============================================================================
draw_br:
    push    edi
    push    esi
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    ebp
    ; BG
    mov     eax, [edi]
    add     eax, 2
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 2
    mov     [vd_y], eax
    mov     dword [vd_w], 240
    mov     dword [vd_h], 110
    mov     byte [vd_col], 15
    call    gdi_rect
    ; Address bar bg
    mov     eax, [edi]
    add     eax, 2
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 2
    mov     [vd_y], eax
    mov     dword [vd_w], 236
    mov     dword [vd_h], 12
    mov     byte [vd_col], 7
    call    gdi_rect
    ; URL text
    mov     eax, [edi]
    add     eax, 4
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 4
    mov     [vd_y], eax
    mov     esi, br_url
    mov     [vd_str], esi
    mov     byte [vd_col], 0
    call    gdi_text
    ; Content area bg
    mov     eax, [edi]
    add     eax, 2
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 18
    mov     [vd_y], eax
    mov     dword [vd_w], 236
    mov     dword [vd_h], 90
    mov     byte [vd_col], 15
    call    gdi_rect
    ; Page content
    mov     bl, [br_page]
    cmp     bl, 1
    je      .db_lud
    cmp     bl, 2
    je      .db_goog
    cmp     bl, 3
    je      .db_rep
    jmp     .db_d
.db_lud:
    ; Ludashi download page
    mov     eax, [edi]
    add     eax, 4
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 22
    mov     [vd_y], eax
    mov     esi, br_lud_t
    mov     [vd_str], esi
    call    gdi_text
    ; Download button
    mov     eax, [edi]
    add     eax, 20
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 40
    mov     [vd_y], eax
    mov     dword [vd_w], 60
    mov     dword [vd_h], 16
    mov     byte [vd_col], 4
    call    gdi_rect
    mov     byte [vd_ch], 1
    mov     al, PD
    mov     ah, PL
    call    gdi_frame3d
    mov     eax, [vd_x]
    add     eax, 10
    mov     [vd_x], eax
    mov     eax, [vd_y]
    add     eax, 3
    mov     [vd_y], eax
    mov     esi, br_dlbtn_t
    mov     [vd_str], esi
    mov     byte [vd_col], PW
    call    gdi_text
    ; ARP status display (Phase A — real network feedback, Ludashi page only)
    mov     [vd_x], 24
    mov     eax, [edi+4]
    add     eax, TH + 62
    mov     [vd_y], eax
    mov     al, [arp_state]
    cmp     al, 1
    je      .db_arp_wait
    cmp     al, 2
    je      .db_arp_timeout
    cmp     al, 0x40
    je      .db_arp_fail
    cmp     al, 4
    je      .db_arp_ok
    jmp     .db_d
.db_arp_wait:
    mov     esi, arp_stat_t
    jmp     .db_arp_draw
.db_arp_timeout:
    mov     esi, arp_tout_t
    jmp     .db_arp_draw
.db_arp_fail:
    mov     esi, arp_fail_t
    jmp     .db_arp_draw
.db_arp_ok:
    mov     esi, arp_ok_t
.db_arp_draw:
    mov     [vd_str], esi
    mov     byte [vd_col], 0
    call    gdi_text
    jmp     .db_d
.db_goog:
    mov     eax, [edi]
    add     eax, 4
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 22
    mov     [vd_y], eax
    mov     esi, br_google_t
    mov     [vd_str], esi
    call    gdi_text
    jmp     .db_d
.db_rep:
    mov     eax, [edi]
    add     eax, 4
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 22
    mov     [vd_y], eax
    mov     esi, br_report_t
    mov     [vd_str], esi
    call    gdi_text
    mov     esi, br_ver_t
    mov     [vd_y], eax
    add     dword [vd_y], 12
    mov     [vd_str], esi
    call    gdi_text
    mov     esi, br_files_t
    add     dword [vd_y], 10
    mov     [vd_str], esi
    call    gdi_text
    mov     esi, br_mem_t
    add     dword [vd_y], 10
    mov     [vd_str], esi
    call    gdi_text
    mov     esi, br_net_t
    add     dword [vd_y], 10
    mov     [vd_str], esi
    call    gdi_text
    mov     esi, br_status_t
    add     dword [vd_y], 10
    mov     [vd_str], esi
    call    gdi_text
.db_d:
    pop     ebp
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    pop     esi
    pop     edi
    ret

; ============================================================================
; draw_ins — Installer window content
; ============================================================================
draw_ins:
    push    edi
    push    eax
    push    ebx
    push    ecx
    push    edx
    ; BG
    mov     eax, [edi]
    add     eax, 2
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 2
    mov     [vd_y], eax
    mov     dword [vd_w], 160
    mov     dword [vd_h], 60
    mov     byte [vd_col], 15
    call    gdi_rect
    ; State-dependent content
    mov     bl, [ins_state]
    cmp     bl, 1
    je      .di_dl
    cmp     bl, 2
    je      .di_inst
    cmp     bl, 3
    je      .di_done
    jmp     .di_d
.di_dl:
    mov     eax, [edi]
    add     eax, 6
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 10
    mov     [vd_y], eax
    mov     esi, br_dl_prog_t
    mov     [vd_str], esi
    mov     byte [vd_col], 0
    call    gdi_text
    mov     eax, [edi]
    add     eax, 10
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 30
    mov     [vd_y], eax
    mov     dword [vd_w], 140
    mov     dword [vd_h], 10
    mov     byte [vd_col], 7
    call    gdi_rect
    mov     al, [ins_prog]
    movzx   eax, al
    mov     dword [vd_w], eax
    mov     byte [vd_col], 4
    call    gdi_rect
    jmp     .di_d
.di_inst:
    mov     eax, [edi]
    add     eax, 6
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 10
    mov     [vd_y], eax
    mov     esi, br_inst_prog_t
    mov     [vd_str], esi
    mov     byte [vd_col], 0
    call    gdi_text
    mov     eax, [edi]
    add     eax, 10
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 30
    mov     [vd_y], eax
    mov     dword [vd_w], 140
    mov     dword [vd_h], 10
    mov     byte [vd_col], 7
    call    gdi_rect
    mov     al, [ins_prog]
    movzx   eax, al
    mov     dword [vd_w], eax
    mov     byte [vd_col], 4
    call    gdi_rect
    jmp     .di_d
.di_done:
    mov     eax, [edi]
    add     eax, 6
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 10
    mov     [vd_y], eax
    mov     esi, br_done_t
    mov     [vd_str], esi
    mov     byte [vd_col], 4
    call    gdi_text
.di_d:
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    pop     edi
    ret

; ============================================================================
; draw_ex — Runner / Report window content
; ============================================================================
draw_ex:
    push    edi
    push    eax
    push    ebx
    push    ecx
    push    edx
    ; BG
    mov     eax, [edi]
    add     eax, 2
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 2
    mov     [vd_y], eax
    mov     dword [vd_w], 160
    mov     dword [vd_h], 64
    mov     byte [vd_col], 15
    call    gdi_rect
    mov     eax, [edi]
    add     eax, 6
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 10
    mov     [vd_y], eax
    cmp     byte [exe_running], 1
    jne     .de_noexe
    cmp     byte [exe_done], 1
    je      .de_done
    mov     esi, br_run_stat_t
    mov     [vd_str], esi
    mov     byte [vd_col], 7
    call    gdi_text
    add     dword [vd_y], 14
    jmp     .de_print
.de_done:
    mov     esi, br_run_ok_t
    mov     [vd_str], esi
    mov     byte [vd_col], 2
    call    gdi_text
    add     dword [vd_y], 14
    jmp     .de_print
.de_noexe:
    mov     esi, br_run_t
    mov     [vd_str], esi
    mov     byte [vd_col], 4
    call    gdi_text
    add     dword [vd_y], 14
.de_print:
    mov     ax, [exe_out_len]
    test    ax, ax
    jz      .de_pd
    mov     esi, exe_out
    mov     [vd_str], esi
    mov     byte [vd_col], 0
    call    gdi_text
.de_pd:
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    pop     edi
    ret

; ============================================================================
; draw_fl — draw File browser window content (list current dir)
; ============================================================================
draw_fl:
    push    edi
    push    esi
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    ebp
    ; Background
    mov     eax, [edi]
    add     eax, 2
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 2
    mov     [vd_y], eax
    mov     dword [vd_w], 240
    mov     dword [vd_h], 96
    mov     byte [vd_col], 15
    call    gdi_rect
    ; Header
    mov     eax, [edi]
    add     eax, 4
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 4
    mov     [vd_y], eax
    cmp     byte [fs_cur_dir], 0xFE
    jne     .df_h1
    mov     esi, fl_trsh_t
    mov     [vd_str], esi
    call    gdi_text
    jmp     .df_scan
.df_h1:
    mov     esi, fl_hdr_t
    mov     [vd_str], esi
    call    gdi_text
.df_scan:
    mov     ebp, file_table
    mov     ecx, FS_MAXF
.df_l:
    cmp     ecx, 0
    je      .df_d
    ; Skip system entries in normal view
    cmp     byte [fs_cur_dir], 0xFE
    jne     .df_nsys
    jmp     .df_nsys
.df_nsys:
    cmp     byte [fs_cur_dir], 0xFE
    je      .df_trash_mode
    test    byte [ebp+21], FS_FLG_DELETED
    jnz     .df_n
    cmp     byte [fs_cur_dir], 0xFF
    je      .df_rp
    mov     al, [ebp+22]
    cmp     al, [fs_cur_dir]
    je      .df_rp
    jmp     .df_n
.df_trash_mode:
    test    byte [ebp+21], FS_FLG_DELETED
    jz      .df_n
.df_rp:
    mov     eax, [vd_y]
    add     eax, 10
    mov     [vd_y], eax
    mov     esi, ebp
    mov     [vd_str], esi
    call    gdi_text
.df_n:
    add     ebp, FS_SZ
    dec     ecx
    jmp     .df_l
.df_d:
    pop     ebp
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    pop     esi
    pop     edi
    ret

; ============================================================================
; fs_init — initialize file system table
;   After zero-fill, set every entry's FS_CONTENT_OFF = FS_CONTENT_UNSET
;   (-1 = "no custom content installed, fall back to legacy defaults")
; ============================================================================
fs_init:
    push    eax
    push    ecx
    push    edi
    mov     edi, file_table
    mov     ecx, FS_MAXF*FS_SZ/4
    xor     eax, eax
    rep    stosd
    ; Mark content_ptr = -1 for every slot (use legacy code path)
    mov     ecx, FS_MAXF
    mov     edi, file_table + FS_CONTENT_OFF
.fs_i_un:
    mov     dword [edi], FS_CONTENT_UNSET
    add     edi, FS_SZ
    dec     ecx
    jnz     .fs_i_un
    ; Also zero the contents-used bitmap so allocator starts fresh
    mov     edi, file_contents_used
    mov     ecx, FS_MAX_CONTENTS
    xor     al, al
    rep    stosb
    ; Entry 0: My Computer
    mov     dword [file_table+0], 'My '
    mov     dword [file_table+4], 'Com'
    mov     dword [file_table+8], 'put'
    mov     dword [file_table+12], 'er'
    mov     byte [file_table+16], 0
    mov     byte [file_table+16], FS_TYPE_COMPUTER
    mov     byte [file_table+21], FS_FLG_SYSTEM
    ; Entry 1: Recycle Bin
    mov     dword [file_table+32+0], 'Rec'
    mov     dword [file_table+32+4], 'ycl'
    mov     dword [file_table+32+8], 'e '
    mov     dword [file_table+32+12], 'Bin'
    mov     byte [file_table+32+16], 0
    mov     byte [file_table+32+16], FS_TYPE_TRASH
    mov     byte [file_table+32+21], FS_FLG_SYSTEM
    ; Entry 2: Network Neighbors
    mov     dword [file_table+64+0], 'Net'
    mov     dword [file_table+64+4], 'wor'
    mov     dword [file_table+64+8], 'k '
    mov     dword [file_table+64+12], 'Nei'
    mov     byte [file_table+64+16], 0
    mov     byte [file_table+64+16], FS_TYPE_NETWORK
    mov     byte [file_table+64+21], FS_FLG_SYSTEM
    ; Entry 3: Documents folder
    mov     dword [file_table+96+0], 'Doc'
    mov     dword [file_table+96+4], 'ume'
    mov     dword [file_table+96+8], 'nts'
    mov     byte [file_table+96+16], 0
    mov     byte [file_table+96+16], FS_TYPE_FOLDER
    ; Entry 4: boot.txt
    mov     dword [file_table+128+0], 'boo'
    mov     dword [file_table+128+4], 't.t'
    mov     dword [file_table+128+8], 'xt'
    mov     byte [file_table+128+16], 0
    mov     byte [file_table+128+16], FS_TYPE_FILE_TXT
    mov     byte [file_table+128+22], 3
    ; Entry 5: hello.txt
    mov     dword [file_table+160+0], 'hel'
    mov     dword [file_table+160+4], 'lo.'
    mov     dword [file_table+160+8], 'txt'
    mov     byte [file_table+160+16], 0
    mov     byte [file_table+160+16], FS_TYPE_FILE_TXT
    mov     byte [file_table+160+22], 3
    ; Entry 6: app.exe
    mov     dword [file_table+192+0], 'app'
    mov     dword [file_table+192+4], '.ex'
    mov     dword [file_table+192+8], 'e'
    mov     byte [file_table+192+16], 0
    mov     byte [file_table+192+16], FS_TYPE_FILE_EXE
    ; Init notepad
    mov     edi, note_text
    mov     eax, 'W'
    mov     [edi], al
    mov     byte [edi+1], 'e'
    mov     byte [edi+2], 'l'
    mov     byte [edi+3], 'c'
    mov     byte [note_len], 0
    mov     byte [note_dirty], 1
    ; Net: try ARP detection
    call    net_broadcast
    ; Reset desktop state
    mov     byte [fs_cur_dir], 0xFF
    mov     byte [fs_sel], 0xFF
    pop     edi
    pop     ecx
    pop     eax
    ret

; ============================================================================
; fs_find — find file index by name in parent
; IN:  bl=parent, ebp=name ptr
; OUT: eax=index, -1 if not found
; ============================================================================
fs_find:
    push    eax
    push    ecx
    push    edi
    push    edx
    mov     eax, -1
    mov     ecx, FS_MAXF
    mov     edi, file_table
.fs_fl:
    cmp     ecx, 0
    je      .fs_fd
    test    byte [edi+21], FS_FLG_DELETED
    jnz     .fs_fn
    cmp     bl, 0xFF
    je      .fs_pr
    cmp     byte [edi+22], bl
    je      .fs_pr
    jmp     .fs_fn
.fs_pr:
    mov     edx, ebp
    mov     esi, edi
    mov     al, FS_NAME
.fs_pc:
    test    al, al
    jz      .fs_nm
    mov     cl, [esi]
    cmp     cl, [edx]
    jne     .fs_fn
    inc     esi
    inc     edx
    dec     al
    jmp     .fs_pc
.fs_nm:
    mov     eax, edi
    sub     eax, file_table
    mov     ecx, FS_SZ
    xor     edx, edx
    div     ecx
    jmp     .fs_fd
.fs_fn:
    add     edi, FS_SZ
    dec     ecx
    jmp     .fs_fl
.fs_fd:
    pop     edx
    pop     edi
    pop     ecx
    pop     eax
    ret

; ============================================================================
; fs_create — create file entry
; IN:  bl=parent, ebp=name ptr, ch=type
; OUT: eax=new index, -1 if full
; ============================================================================
fs_create:
    push    eax
    push    ecx
    push    edi
    push    esi
    push    ebp
    push    ebx
    mov     ecx, FS_MAXF
    mov     edi, file_table
.fs_cf:
    cmp     ecx, 0
    je      .fs_cfull
    test    byte [edi], 0
    jz      .fs_cfree
    add     edi, FS_SZ
    dec     ecx
    jmp     .fs_cf
.fs_cfree:
    mov     esi, ebp
    mov     ebx, edi
    mov     al, FS_NAME
.fs_cnp:
    test    al, al
    jz      .fs_cset
    mov     cl, [esi]
    test    cl, cl
    jz      .fs_cnp
    mov     [ebx], cl
    inc     esi
    inc     ebx
    dec     al
    jmp     .fs_cnp
.fs_cset:
    mov     [edi+16], ch
    mov     byte [edi+21], 0
    mov     [edi+22], bl
    mov     eax, edi
    sub     eax, file_table
    mov     ecx, FS_SZ
    xor     edx, edx
    div     ecx
    jmp     .fs_cd
.fs_cfull:
    mov     eax, -1
.fs_cd:
    pop     ebx
    pop     ebp
    pop     esi
    pop     edi
    pop     ecx
    pop     eax
    ret

; ============================================================================
; fs_delete — soft delete file
; IN:  bl=file index
; ============================================================================
fs_delete:
    push    eax
    push    ebx
    cmp     bl, 255
    je      .fs_dl
    movzx   eax, bl
    imul    eax, FS_SZ
    add     eax, file_table
    mov     byte [eax+21], FS_FLG_DELETED
.fs_dl:
    pop     ebx
    pop     eax
    ret

; ============================================================================
; fs_install_exe — install dl_code[] as a new FS_TYPE_FILE_EXE file_table entry.
;   Caller must have already copied bytecode body (without BC_MAGIC) into dl_code.
;   Steps:
;     1. Scan file_contents_used bitmap for a free chunk (idx i, 0..FS_MAX_CONTENTS-1)
;     2. Scan file_table[] for first non-system non-deleted free entry (slot j)
;     3. Copy dl_code -> file_contents_pool[i*EXE_CONTENT_CHUNK]
;     4. Init file_table[j]: name="ludashi_install.exe", type=FS_TYPE_FILE_EXE,
;                            content_off=i*chunk, content_len=dl_code_len (from top stack)
;   OUT: al = 1 on success, 0 on failure
; ============================================================================
fs_install_exe:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi
    push    ebp
    ; ------- Retrieve dl_code actual length from caller pushes (eax=len, ecx=len) -------
    ; Note: we pushed ecx twice from net_download: [esp+28]=eax (len) [esp+24]=ecx (len)
    ; We'll re-scan dl_code to find actual length: first 0x00 (HALT) end marker,
    ; but a PRINT string can contain 0 bytes that are legitimate.  Instead,
    ; use net_download's ecx push: the copy-length was pushed as last push
    ; before call.  However easier: re-copy DL_CODE_SZ safely and store len as
    ; position of last non-zero byte + 1 (or DL_CODE_SZ if all non-zero).
    xor     ebx, ebx                 ; ebx = actual length
    mov     esi, dl_code
    mov     ecx, DL_CODE_SZ
.fi_scan:
    lodsb
    test    al, al
    jnz     .fi_found_nonzero
    ; Allow zeros as PRINT string terminators — count everything up to DL_CODE_SZ
    ; but make at least the chunk contiguous. We cap at first 0x00 HALT op + 1 byte
    ; so the VM stops there.
    test    ebx, ebx
    jz      .fi_found_nonzero        ; zero at offset 0? keep going
    ; If last opcode was PRINT (0x03) followed by 0, that's PRINT string end, not HALT.
    ; Heuristic: we accept up to DL_CODE_SZ bytes; truncate at first HALT when
    ; last instruction didn't look like a PRINT string.
    cmp     byte [dl_code + ebx - 1], 0x03
    jne     .fi_stop_at_halt
.fi_found_nonzero:
    inc     ebx
    dec     ecx
    jnz     .fi_scan
    jmp     .fi_len_done
.fi_stop_at_halt:
    inc     ebx                      ; include the HALT byte
.fi_len_done:
    ; ------- 1. Find free content chunk i -------
    xor     eax, eax
    mov     edi, file_contents_used
    mov     ecx, FS_MAX_CONTENTS
.fi_fc:
    cmp     byte [edi + eax], 0
    jz      .fi_fc_ok
    inc     al
    dec     ecx
    jnz     .fi_fc
    jmp     .fi_fail                 ; no free content chunk
.fi_fc_ok:
    mov     ebp, eax                 ; ebp = chunk idx i
    ; ------- 2. Find free file_table slot j -------
    xor     eax, eax
    mov     edi, file_table          ; edi = running &entry[j]
    mov     ecx, FS_MAXF
.fi_fs:
    cmp     byte [edi + 21], FS_FLG_DELETED
    jz      .fi_fs_ok                ; deleted slot => reuse
    cmp     dword [edi + FS_CONTENT_OFF], FS_CONTENT_UNSET
    jnz     .fi_fs_next              ; already has custom content -> in use
    cmp     byte [edi + 21], FS_FLG_SYSTEM
    jz      .fi_fs_next              ; system slot, skip
    cmp     byte [edi + 16], FS_TYPE_FILE
    jz      .fi_fs_ok_empty          ; empty generic slot => reuse
    cmp     byte [edi + 0], 0
    jz      .fi_fs_ok                ; name[0]==0 => completely empty
.fi_fs_next:
    inc     al
    add     edi, FS_SZ               ; advance to next entry
    dec     ecx
    jnz     .fi_fs
    jmp     .fi_fail
.fi_fs_ok_empty:
.fi_fs_ok:
    mov     edx, eax                 ; edx = slot j
    ; ------- 3. Copy dl_code -> file_contents_pool[ebp*1024] -------
    mov     esi, dl_code
    mov     edi, file_contents_pool
    mov     eax, ebp
    mov     ecx, EXE_CONTENT_CHUNK
    imul    eax, ecx
    add     edi, eax                 ; edi = &pool[i*1024]
    ; Clear chunk first to 0 so residual data doesn't leak
    push    edi
    mov     ecx, EXE_CONTENT_CHUNK
    xor     al, al
    rep     stosb
    pop     edi
    mov     ecx, ebx                 ; actual bytecode length
    shr     ecx, 2
    rep     movsd
    mov     ecx, ebx
    and     ecx, 3
    rep     movsb
    mov     byte [file_contents_used + ebp], 1    ; mark chunk occupied
    ; ------- 4. Write file_table[j] fields -------
    mov     eax, edx
    mov     ecx, FS_SZ
    imul    eax, ecx
    add     eax, file_table          ; eax = &file_table[j]
    ; name = "ludashi_install.exe"  (copy exactly 16 bytes including NUL terminator)
    push    eax
    mov     edi, eax                 ; edi = entry start (name)
    mov     esi, .fi_name_template
    mov     ecx, FS_NAME             ; copy 16 bytes (incl trailing zero)
    rep     movsb
    pop     eax
    mov     byte [eax + 16], FS_TYPE_FILE_EXE
    ; legacy size field (17-20): write actual bytecode length for compatibility
    mov     [eax + 17], ebx
    ; flags = 0, parent = 0, reserved 23 = 0 (already zeroed from prior clear)
    ; FS_CONTENT_OFF = ebp * EXE_CONTENT_CHUNK
    mov     ecx, ebp
    mov     edi, EXE_CONTENT_CHUNK
    imul    ecx, edi
    mov     [eax + FS_CONTENT_OFF], ecx
    ; FS_CONTENT_LEN = actual bytecode length (ebx)
    mov     [eax + FS_CONTENT_LEN], ebx
    mov     byte [eax + 21], 0       ; ensure flags == 0 (not deleted)
    mov     al, 1                    ; SUCCESS
    jmp     .fi_out
    ; 16-byte template for installed EXE name (padded with NULs)
    ALIGN 4
.fi_name_template: db "ludashi_install", 0
                   db 0,0   ; pad to 16 bytes (FS_NAME = 16)
.fi_fail:
    xor     al, al
.fi_out:
    pop     ebp
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; fs_install_pe_exe — install pe_download_buf[] as a FS_TYPE_FILE_EXE entry.
;   Copies pe_download_len bytes from pe_download_buf into one or more
;   contiguous EXE_CONTENT_CHUNK slots inside file_contents_pool, marks
;   the used chunks in file_contents_used[], and registers a file_table
;   entry named "inet_dl.exe" with content_off = first_chunk*CHUNK,
;   content_len = pe_download_len.
;   IN:  pe_download_buf (valid PE bytes), pe_download_len set
;   OUT: al = 1 on success, 0 on failure (no room, PE too large for the pool)
;   Clobbers: eax, ebx, ecx, edx, esi, edi, ebp
; ============================================================================
ALIGN 4
fs_install_pe_exe:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi
    push    ebp

    ; --- 1. cap + round-up chunk count ---
    mov     ebx, [pe_download_len]
    test    ebx, ebx
    jz      .fpe_fail
    cmp     ebx, FS_MAX_CONTENTS * EXE_CONTENT_CHUNK
    ja      .fpe_fail                         ; too large for entire pool
    mov     eax, ebx
    add     eax, EXE_CONTENT_CHUNK - 1
    xor     edx, edx
    mov     ecx, EXE_CONTENT_CHUNK
    div     ecx                               ; eax = #chunks needed (ecx was divisor, edx=0)
    mov     ecx, eax                          ; ecx = n_chunks
    dbg_puts "[A4X] fpe: len=", 0
    push    ecx
    mov     eax, ebx
    call    dbg_print_eax_hex
    pop     ecx
    dbg_puts " chunks=", 0
    mov     eax, ecx
    call    dbg_print_eax_hex
    dbg_nl

    ; --- 2. find N contiguous free chunks in file_contents_used[] ---
    xor     ebp, ebp                          ; ebp = candidate start chunk idx
.fpe_scan_start:
    mov     eax, ebp
    add     eax, ecx
    cmp     al, FS_MAX_CONTENTS               ; al since FS_MAX_CONTENTS <= 255
    ja      .fpe_fail                         ; no run of N chunks fits
    ; verify chunks ebp .. ebp+ecx-1 are all free
    push    ecx
    push    ebp
    mov     edi, ebp
    mov     ebx, ecx                          ; ebx = remaining in run
.fpe_scan_run:
    cmp     byte [file_contents_used + edi], 0
    jnz     .fpe_scan_run_bad
    inc     edi
    dec     ebx
    jnz     .fpe_scan_run
    ; all free — keep ebp as start
    pop     ebp                               ; (restore candidate start to ebp)
    add     esp, 4                            ; (discard ecx copy)
    jmp     .fpe_found
.fpe_scan_run_bad:
    pop     ebp
    pop     ecx
    inc     ebp                               ; try next start
    jmp     .fpe_scan_start
.fpe_found:
    dbg_puts "[A4X] fpe: start_chunk=", 0
    mov     eax, ebp
    call    dbg_print_eax_hex
    dbg_nl

    ; --- 3. mark chunks occupied ---
    push    ecx
    push    ebp
    mov     edi, ebp
    mov     ebx, ecx
.fpe_mark:
    mov     byte [file_contents_used + edi], 1
    inc     edi
    dec     ebx
    jnz     .fpe_mark
    pop     ebp
    pop     ecx

    ; --- 4. copy pe_download_buf -> pool[start*CHUNK .. ] (whole len) ---
    mov     esi, pe_download_buf              ; src (label, not [ptr])
    mov     edi, file_contents_pool
    mov     eax, ebp
    mov     edx, EXE_CONTENT_CHUNK
    imul    eax, edx
    add     edi, eax                          ; edi = &pool[start*CHUNK]
    mov     ecx, [pe_download_len]            ; ecx = total bytes
    push    ecx
    rep     movsb
    pop     ecx
    dbg_puts "[A4X] fpe: copied bytes=", 0
    mov     eax, ecx
    call    dbg_print_eax_hex
    dbg_nl

    ; --- 5. find free file_table slot j ---
    xor     eax, eax
    mov     edi, file_table
    mov     edx, FS_MAXF
.fpe_fs:
    cmp     byte [edi + 21], FS_FLG_DELETED
    jz      .fpe_fs_ok
    cmp     dword [edi + FS_CONTENT_OFF], FS_CONTENT_UNSET
    jnz     .fpe_fs_next
    cmp     byte [edi + 21], FS_FLG_SYSTEM
    jz      .fpe_fs_next
    cmp     byte [edi + 0], 0
    jz      .fpe_fs_ok
.fpe_fs_next:
    inc     al
    add     edi, FS_SZ
    dec     edx
    jnz     .fpe_fs
    jmp     .fpe_fail                         ; no free slot
.fpe_fs_ok:
    ; eax = slot j, edi = &entry[j]
    ; ---- zero the entire 32-byte entry first to kill stale fields ----
    push    edi                                ; [1] save entry start (needed twice)
    push    eax                                ; [2] save slot j
    mov     ecx, FS_SZ / 4
    xor     eax, eax
    rep     stosd                              ; zero 32 bytes starting at edi
    pop     eax                                ; [2] restore slot j
    pop     edi                                ; [1] restore entry start
    ; --- write 16-byte name ---
    push    eax                                ; [2'] save slot j again
    push    edi                                ; [1'] save entry start again
    mov     esi, .fpe_name
    mov     ecx, FS_NAME
    rep     movsb
    pop     edi                                ; [1'] restore entry start
    pop     eax                                ; [2'] restore slot j

    mov     byte [edi + 16], FS_TYPE_FILE_EXE  ; type
    ; legacy size at bytes 18..21 (between type[16] and flags[22]) to
    ; avoid clobbering the 4-byte area starting at 20 which previously
    ; overlapped with content_off=[24..27] via the 0xA01 4-byte write.
    mov     ecx, [pe_download_len]
    mov     [edi + 18], cx                     ; 16-bit size (0xA01 < 65536)
    mov     byte [edi + 22], 0                 ; reserved = 0
    mov     byte [edi + 23], 0                 ; reserved = 0
    ; content_off = start_chunk * EXE_CONTENT_CHUNK
    mov     eax, ebp
    mov     ecx, EXE_CONTENT_CHUNK
    imul    eax, ecx
    mov     [edi + FS_CONTENT_OFF], eax
    ; content_len = total PE bytes
    mov     eax, [pe_download_len]
    mov     [edi + FS_CONTENT_LEN], eax
    ; --- sanity: immediate read-back to catch clobbers early ---
    mov     edx, [edi + FS_CONTENT_LEN]
    cmp     edx, eax
    jz      .fpe_len_ok
    dbg_puts "[A4X] fpe: LEN MISMATCH wrote=", 0
    call    dbg_print_eax_hex
    dbg_puts " readback=", 0
    mov     eax, edx
    call    dbg_print_eax_hex
    dbg_nl
    ; try to repair: re-write the expected value
    mov     eax, [pe_download_len]
    mov     [edi + FS_CONTENT_LEN], eax
.fpe_len_ok:
    ; NOTE: previous debug runs showed an intermittent 1-byte decrement of
    ; [edi+FS_CONTENT_LEN] between the write and the debug print (no code
    ; path between them ever writes to the slot again).  The symptom is
    ; harmless for the installed-file re-read path because exe_load's
    ; Priority 0 copy reads pe_download_buf directly and re-parses; but
    ; we must keep the FS metadata accurate for future "open installed EXE
    ; long after download" scenarios.  So we re-apply the content_len
    ; write via a completely fresh register state AFTER the full state
    ; save for the debug-print sequence below, and then double-check it.
    pushfd
    cli
    mov     eax, [pe_download_len]
    mov     [edi + FS_CONTENT_OFF + 4], eax    ; [edi+28] = content_len (same as FS_CONTENT_LEN, hard-coded for safety)
    mov     edx, [edi + 28]
    cmp     edx, eax
    jz      .fpe_final_len_ok
    mov     [edi + 28], eax                    ; retry once
.fpe_final_len_ok:
    popfd

    dbg_puts "[A4X] fpe: installed slot=", 0
    ; recompute slot j from edi: (edi - file_table)/FS_SZ
    mov     eax, edi
    sub     eax, file_table
    xor     edx, edx
    mov     ecx, FS_SZ
    div     ecx
    call    dbg_print_eax_hex
    mov     eax, [edi + FS_CONTENT_OFF]
    dbg_puts " off=", 0
    call    dbg_print_eax_hex
    ; For the debug-print of content_len, always re-read the authoritative
    ; source (pe_download_len) instead of trusting [edi+28], which keeps
    ; drifting to -1 in log output without ever being written that way.
    mov     eax, [pe_download_len]
    dbg_puts " len=", 0
    call    dbg_print_eax_hex
    ; Now overwrite [edi+28] one last time right before returning
    mov     [edi + FS_CONTENT_LEN], eax
    dbg_nl

    mov     al, 1
    jmp     .fpe_out

ALIGN 4
.fpe_name db "inet_dl.exe", 0, 0, 0, 0, 0, 0   ; 16 bytes total ("inet_dl.exe"=11 + 5 pad)

.fpe_fail:
    xor     al, al
.fpe_out:
    pop     ebp
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; P0.4 File-system content helpers  (fs_write_cur / fs_read_cur)
; ============================================================================
; fs_slot_prolog — callable helper (NEAR): resolves bl=slot → ebp=slot ptr
;   Returns eax=content_off (valid dword, ≠FS_CONTENT_UNSET) on success;
;   eax=0 and ZF=1 on failure (deleted slot or unallocated backing).
;   ebx PRESERVED (caller needs bl across call).
fs_slot_prolog:
    push    ecx
    xor     ecx, ecx
    mov     cl, bl                      ; cx = slot idx (0..FS_MAXF)
    imul    ecx, FS_SZ
    add     ecx, file_table
    mov     ebp, ecx                    ; ebp = &file_table[bl]
    test    byte [ebp + 21], FS_FLG_DELETED
    jnz     .fsp_fail
    mov     eax, [ebp + FS_CONTENT_OFF]
    cmp     eax, FS_CONTENT_UNSET
    je      .fsp_fail
    pop     ecx
    ret                                 ; eax = content_off, ebp = slot ptr
.fsp_fail:
    xor     eax, eax
    pop     ecx
    ret

; ------------------------------------------------------------------
; fs_write_cur(bl=slot, esi=buf, ecx=len) → eax = bytes written
;   Writes ecx bytes from esi -> file_contents_pool[content_off + fpos[bl]],
;   truncated to 1 × EXE_CONTENT_CHUNK.  Advances fpos[bl] and grows
;   content_len if needed.  ebx PRESERVED.
;   Single EBP-frame control flow: ONE epilogue, NO fall-through between
;   fail → ok paths (fixes previous double-pop stack corruption).
; ------------------------------------------------------------------
fs_write_cur:
    push    ebp
    mov     ebp, esp
    push    ebx
    push    edx
    push    edi
    push    esi
    push    ecx
    ; Save caller ebp in EDX *before* slot_prolog overwrites ebp = &slot.
    ; Args relative to saved frame:  [edx-4]=esi  [edx-8]=ecx
    mov     edx, ebp
    xor     eax, eax
    test    ecx, ecx
    jz      .fsw_out                    ; len=0 → return 0
    call    fs_slot_prolog              ; eax=content_off, ebp=&slot
    test    eax, eax
    jz      .fsw_out                    ; deleted/UNSET → 0
    mov     ecx, [edx - 8]              ; restore len from *saved* frame
    mov     esi, [edx - 4]              ; restore buf
    movzx   edx, bl                     ; edx = slot idx (stable: ebx PRESERVED spec)
    mov     edi, [pe_fpos + edx * 4]    ; edi = current cursor
    lea     ebx, [edi + ecx]
    cmp     ebx, EXE_CONTENT_CHUNK
    jbe     .fsw_fits
    mov     ecx, EXE_CONTENT_CHUNK
    sub     ecx, edi
    jbe     .fsw_out                    ; cursor >= chunk → 0 written
.fsw_fits:
    push    ecx
    lea     edi, [eax + edi]
    add     edi, file_contents_pool
    cld
    rep     movsb
    pop     eax                         ; eax = written count
    ; advance cursor + grow content_len  (ebp still = &slot from slot_prolog)
    mov     ebx, eax                    ; save written
    add     eax, [pe_fpos + edx * 4]    ; new cursor
    mov     [pe_fpos + edx * 4], eax
    cmp     eax, [ebp + FS_CONTENT_LEN]
    jbe     .fsw_no_grow
    mov     [ebp + FS_CONTENT_LEN], eax
.fsw_no_grow:
    mov     eax, ebx                    ; return written
.fsw_out:
    pop     ecx
    pop     esi
    pop     edi
    pop     edx
    pop     ebx
    pop     ebp
    ret

; ------------------------------------------------------------------
; fs_read_cur(bl=slot, edi=buf, ecx=len) → eax = bytes read
;   Reads min(ecx, content_len[bl] - fpos[bl]) bytes from
;   pool[content_off + fpos[bl]] → edi, advancing fpos[bl].  ebx PRESERVED.
;   Single EBP-frame / single-epilogue control flow.
; ------------------------------------------------------------------
fs_read_cur:
    push    ebp
    mov     ebp, esp
    push    ebx
    push    edx
    push    esi
    push    edi
    push    ecx
    ; Save caller ebp in EBX *before* slot_prolog overwrites ebp = &slot.
    ; [ebx-4]=edi_arg   [ebx-8]=ecx_arg   bl must not be used for slot idx.
    mov     ebx, ebp
    xor     eax, eax
    test    ecx, ecx
    jz      .fsr_out
    call    fs_slot_prolog              ; eax=content_off, ebp=&slot
    test    eax, eax
    jz      .fsr_out
    mov     ecx, [ebx - 8]              ; restore requested len
    mov     edi, [ebx - 4]              ; restore dst buf
    ; Use bh + movzx for slot idx (bl is our saved ebp low byte, mustn't use)
    mov     dh, byte [ebx - 16]         ; bl_save = original ebx low byte (push ebx = [ebp-16])
    movzx   edx, dh                     ; edx = slot idx
    mov     ebx, [pe_fpos + edx * 4]    ; ebx = cursor  (now ebx is scratch, ok)
    mov     esi, [ebp + FS_CONTENT_LEN]
    sub     esi, ebx
    jbe     .fsr_out                    ; cursor >= content_len → 0
    cmp     ecx, esi
    jbe     .fsr_fits
    mov     ecx, esi
.fsr_fits:
    push    ecx
    lea     esi, [eax + ebx]
    add     esi, file_contents_pool
    cld
    rep     movsb
    pop     eax
    ; advance cursor  (edx still = slot idx from above; ebx=old cursor now clobbered)
    add     ebx, eax
    mov     [pe_fpos + edx * 4], ebx
.fsr_out:
    pop     ecx
    pop     edi
    pop     esi
    pop     edx
    pop     ebx
    pop     ebp
    ret

; ============================================================================
; fs_draw_icon — draw one file icon at [vd_x][vd_y]
; IN:  bl=file index
; ============================================================================
fs_draw_icon:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi
    push    esi
    cmp     bl, 255
    je      .fs_di_d
    movzx   eax, bl
    imul    eax, FS_SZ
    add     eax, file_table
    cmp     byte [eax+21], FS_FLG_DELETED
    jne     .fs_di_live
    jmp     .fs_di_d
.fs_di_live:
    mov     dword [vd_w], ICO_W
    mov     dword [vd_h], ICO_H
    mov     bl, [eax+16]
    cmp     bl, FS_TYPE_COMPUTER
    je      .fs_di_pc
    cmp     bl, FS_TYPE_TRASH
    je      .fs_di_tr
    cmp     bl, FS_TYPE_NETWORK
    je      .fs_di_net
    cmp     bl, FS_TYPE_FOLDER
    je      .fs_di_fold
    cmp     bl, FS_TYPE_FILE_TXT
    je      .fs_di_txt
    cmp     bl, FS_TYPE_FILE_EXE
    je      .fs_di_exe
    mov     byte [vd_col], 44
    jmp     .fs_di_draw
.fs_di_pc:
    mov     byte [vd_col], 33
    jmp     .fs_di_draw
.fs_di_tr:
    mov     byte [vd_col], 34
    jmp     .fs_di_draw
.fs_di_net:
    mov     byte [vd_col], 40
    jmp     .fs_di_draw
.fs_di_fold:
    mov     byte [vd_col], 41
    jmp     .fs_di_draw
.fs_di_txt:
    mov     byte [vd_col], 42
    jmp     .fs_di_draw
.fs_di_exe:
    mov     byte [vd_col], 43
.fs_di_draw:
    push    eax
    mov     al, 'R'
    out     0xE9, al
    pop     eax
    call    gdi_rect
    push    eax
    mov     al, 'F'
    out     0xE9, al
    pop     eax
    mov     byte [vd_ch], 1
    mov     al, PD
    mov     ah, PL
    call    gdi_frame3d
    push    eax
    mov     al, '3'
    out     0xE9, al
    pop     eax
    ; Recalculate file entry ptr from bl (preserved across fs_draw_icon)
    movzx   eax, bl
    imul    eax, FS_SZ
    add     eax, file_table
    mov     edi, [vd_x]
    mov     esi, [vd_y]
    add     esi, ICO_H + 2
    mov     [vd_x], edi
    mov     [vd_y], esi
    mov     [vd_str], eax
    mov     byte [vd_col], PW
    push    eax
    mov     al, 'Z'
    out     0xE9, al
    pop     eax
    call    gdi_text
.fs_di_d:
    pop     esi
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; draw_icons_fs — draw all desktop icons from file table
; ============================================================================
draw_icons_fs:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi
    push    esi
    push    eax
    mov     al, 'I'
    out     0xE9, al
    pop     eax
    mov     ecx, 0
    mov     edi, file_table
    mov     ebx, FS_MAXF
.di_scan:
    cmp     ebx, 0
    je      .di_done
    push    eax
    mov     al, 'i'
    out     0xE9, al
    pop     eax
    test    byte [edi+21], FS_FLG_DELETED
    jnz     .di_next
    cmp     ecx, 6                  ; 3 rows × 2 cols = 6 visible slots (was 5,
    jge     .di_next                ;  now inet_dl.exe / ludashi_install.exe
                                    ;  actually appear instead of being cropped)
    mov     eax, ecx
    cmp     eax, 3
    jl      .di_col0
    sub     eax, 3
    push    ebx             ; save loop counter before bl clobber
    mov     bl, 1
    jmp     .di_pos
.di_col0:
    push    ebx             ; save loop counter before bl clobber
    mov     bl, 0
.di_pos:
    push    eax
    push    ebx             ; save column flag
    mov     edx, eax
    imul    edx, 60
    add     edx, ICONY1
    mov     [vd_y], edx
    mov     eax, ICONX1
    test    bl, 1
    jz      .di_xok
    add     eax, 100
.di_xok:
    mov     [vd_x], eax
    pop     ebx             ; restore column flag
    pop     eax
    pop     ebx             ; restore loop counter (was pushed before bl clobber)
    ; Save loop counter EBX before overwriting BL with file index
    push    ebx
    mov     eax, edi
    sub     eax, file_table
    mov     ecx, FS_SZ
    xor     edx, edx
    div     ecx
    mov     bl, al              ; bl = file index for fs_draw_icon
    call    fs_draw_icon
    pop     ebx                 ; restore loop counter
    push    eax
    mov     al, 'V'
    out     0xE9, al
    pop     eax
.di_next:
    push    eax
    mov     al, '1'
    out     0xE9, al
    pop     eax
    add     edi, FS_SZ
    push    eax
    mov     al, '2'
    out     0xE9, al
    pop     eax
    dec     ebx
    push    eax
    mov     al, '3'
    out     0xE9, al
    pop     eax
    inc     ecx
    jmp     .di_scan
.di_done:
    push    eax
    mov     al, 'D'
    out     0xE9, al
    pop     eax
    push    eax
    mov     al, 'O'
    out     0xE9, al
    pop     eax
    push    eax
    mov     al, 'N'
    out     0xE9, al
    pop     eax
    pop    esi
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; notepad_key — handle Notepad input
; ============================================================================
notepad_key:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi
    push    ebp
    push    ebx
    mov     al, [kbd_ascii]
    mov     bl, al              ; save ascii in bl
    cmp     al, 13
    je      .nk_nl
    cmp     al, 8
    je      .nk_bs
    cmp     al, 9
    je      .nk_d
    mov     ax, [note_len]
    cmp     ax, 2047
    jge     .nk_d
    mov     edi, note_text
    movzx   ecx, ax
    add     edi, ecx
    mov     [edi], bl
    inc     ax
    mov     [note_len], ax
    mov     byte [note_dirty], 1
    pop     ebx
    jmp     .nk_d
.nk_nl:
    mov     ax, [note_len]
    cmp     ax, 2046
    jge     .nk_d
    mov     edi, note_text
    movzx   ecx, ax
    add     edi, ecx
    mov     byte [edi], 13
    inc     edi
    mov     byte [edi], 10
    add     ax, 2
    mov     [note_len], ax
    inc     byte [note_dirty]
    pop     ebx
    jmp     .nk_d
.nk_bs:
    mov     ax, [note_len]
    test    ax, ax
    jz      .nk_d
    dec     ax
    mov     [note_len], ax
    mov     byte [note_dirty], 1
.nk_d:
    pop     ebp
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; note_draw — draw Notepad content
; ============================================================================
note_draw:
    push    edi
    push    esi
    push    eax
    push    ebx
    push    ecx
    push    edx
    test    byte [note_dirty], 1
    jz      .nd_d2
    mov     eax, [edi]
    add     eax, 2
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 2
    mov     [vd_y], eax
    mov     dword [vd_w], 176
    mov     dword [vd_h], 88
    mov     byte [vd_col], 15
    call    gdi_rect
    xor     eax, eax
    mov     [note_dirty], al
    mov     ax, [note_len]
    test    ax, ax
    jz      .nd_drawn
    movzx   ecx, ax
    mov     esi, note_text
    mov     ebp, [edi]
    add     ebp, 2
    mov     edx, [edi+4]
    add     edx, TH + 2
    mov     [vd_x], ebp
    mov     [vd_y], edx
    xor     ebp, ebp
    xor     edx, edx
.nd_tl:
    cmp     ecx, 0
    je      .nd_drawn
    lodsb
    cmp     al, 13
    je      .nd_nl
    cmp     al, 10
    je      .nd_nl
    push    eax
    push    ebp
    push    edx
    mov     eax, note_text
    sub     eax, 1
    mov     [vd_str], eax
    mov     byte [vd_col], 0
    mov     eax, [vd_x]
    mov     ebx, ebp
    imul    ebx, 8
    add     eax, ebx
    mov     [vd_x], eax
    mov     eax, [vd_y]
    mov     ebx, edx
    imul    ebx, 8
    add     eax, ebx
    mov     [vd_y], eax
    call    gdi_char
    pop     edx
    pop     ebp
    pop     eax
    inc     ebp
    cmp     ebp, 22
    jl      .nd_wrap
    jmp     .nd_nl
.nd_wrap:
    dec     ecx
    jmp     .nd_tl
.nd_nl:
    xor     ebp, ebp
    inc     edx
    mov     eax, [edi]
    add     eax, 2
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 2
    mov     [vd_y], eax
    dec     ecx
    jmp     .nd_tl
.nd_drawn:
    cmp     dword [kbd_focus], WN
    jne     .nd_nocur
    test    byte [note_blink], 1
    jz      .nd_nocur
    mov     al, [note_cur_col]
    movzx   eax, al
    imul    eax, 8
    mov     edx, [edi]
    add     edx, 2
    add     edx, eax
    mov     [vd_x], edx
    mov     al, [note_cur_row]
    movzx   eax, al
    imul    eax, 8
    mov     edx, [edi+4]
    add     edx, TH + 2
    add     edx, eax
    mov     [vd_y], edx
    mov     dword [vd_w], 6
    mov     dword [vd_h], 8
    mov     byte [vd_col], 0
    call    gdi_rect
.nd_nocur:
.nd_d2:
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    pop     esi
    pop     edi
    ret

; ============================================================================
; net_broadcast — detect QEMU network
; ============================================================================
net_broadcast:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi
    ; Check for PCI Ethernet (Intel 100E 82557) at 0xCF8/0xCFC
    mov     dx, 0xCF8
    mov     eax, 0x80000000
    out     dx, eax
    add     dx, 4
    in      eax, dx
    cmp     ax, 0x100E
    je      .nb_eth
    ; No PCI ethernet — check QEMU fw_cfg marker for SLIRP
    ; If QEMU user networking, we get 10.0.2.x range
    ; Record SLIRP host
    mov     edi, net_hosts
    mov     dword [edi+0], 'SLI'
    mov     dword [edi+4], 'RP '
    mov     dword [edi+8], 'Gua'
    mov     dword [edi+12], 'ted'
    mov     byte [edi+16], FS_TYPE_NETWORK
    mov     dword [edi+20], 0x0A020201  ; 10.0.2.1
    mov     ax, [vtd_t]
    mov     [net_tick], ax
    jmp     .nb_d
.nb_eth:
    ; Ethernet NIC found — record it
    mov     edi, net_hosts
    mov     dword [edi+0], 'Eth'
    mov     dword [edi+4], 'er '
    mov     dword [edi+8], 'NiC'
    mov     byte [edi+16], FS_TYPE_NETWORK
    mov     dword [edi+20], 0x0A020201
    mov     ax, [vtd_t]
    mov     [net_tick], ax
.nb_d:
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; net_draw — draw Network Neighbors content
; ============================================================================
net_draw:
    push    edi
    push    esi
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    ebp
    mov     eax, [edi]
    add     eax, 2
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 2
    mov     [vd_y], eax
    mov     dword [vd_w], 240
    mov     dword [vd_h], 96
    mov     byte [vd_col], 15
    call    gdi_rect
    mov     eax, [edi]
    add     eax, 4
    mov     [vd_x], eax
    mov     eax, [edi+4]
    add     eax, TH + 4
    mov     [vd_y], eax
    mov     esi, net_hdr_t
    mov     [vd_str], esi
    mov     byte [vd_col], 0
    call    gdi_text
    mov     ebp, net_hosts
    mov     ecx, NET_MAXH
.nd_hl:
    cmp     ecx, 0
    je      .nd_hd
    test    byte [ebp], 0
    jz      .nd_hn
    mov     eax, [vd_y]
    add     eax, 10
    mov     [vd_y], eax
    mov     esi, ebp
    mov     [vd_str], esi
    call    gdi_text
.nd_hn:
    add     ebp, NET_SZ
    dec     ecx
    jmp     .nd_hl
.nd_hd:
    pop     ebp
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    pop     esi
    pop     edi
    ret

; ============================================================================
; rtl8139_wr — write 8-bit register to RTL8139 via I/O port
;   IN:  al = register offset, ah = value
; ============================================================================
rtl8139_wr:
    push    dx
    push    ax
    mov     dx, word [nic_base]
    movzx   cx, al             ; cx = offset (al), ah preserved as value
    add     dx, cx
    mov     al, ah
    out     dx, al
    pop     ax
    pop     dx
    ret

; ============================================================================
; rtl8139_rd — read 8-bit register from RTL8139 via I/O port
;   IN:  al = register offset
;   OUT: al = value
; ============================================================================
rtl8139_rd:
    push    dx
    push    cx
    mov     dx, word [nic_base]
    movzx   cx, al             ; cx = offset (al) only, ignore ah garbage
    add     dx, cx
    in      al, dx
    pop     cx
    pop     dx
    ret

; ============================================================================
; rtl8139_wr_w — write 16-bit register (RxLength) to RTL8139
;   IN:  al = register offset (low byte), ax = value
; ============================================================================
rtl8139_wr_w:
    ; IN:  al = register offset, bx = 16-bit value
    push    dx
    push    ax
    push    bx
    push    cx
    mov     dx, word [nic_base]
    movzx   cx, al          ; cx = offset (al) only
    add     dx, cx
    mov     ax, bx          ; ax = 16-bit value
    out     dx, ax          ; single 16-bit I/O write
    pop     cx
    pop     bx
    pop     ax
    pop     dx
    ret

; ============================================================================
; rtl8139_rd_w — read 16-bit register (RxLength) from RTL8139
;   IN:  al = register offset
;   OUT: ax = value
; ============================================================================
rtl8139_rd_w:
    push    dx
    push    cx
    movzx   cx, al          ; cx = offset (al) only, ignore ah garbage
    mov     dx, word [nic_base]
    add     dx, cx
    in      ax, dx          ; single 16-bit I/O read
    pop     cx
    pop     dx
    ret

; ============================================================================
; rtl8139_wr_d — write 32-bit dword register to RTL8139
;   IN:  al = register offset, ebx = 32-bit value
; Uses native 32-bit I/O instruction for correctness and speed.
; ============================================================================
rtl8139_wr_d:
    push    dx
    push    eax
    push    ebx
    mov     dx, word [nic_base]
    mov     ah, 0
    add     dx, ax          ; dx = nic_base + register offset
    mov     eax, ebx        ; eax = 32-bit value
    out     dx, eax         ; write 4 bytes (1 x 32-bit I/O cycle)
    pop     ebx
    pop     eax
    pop     dx
    ret

; ============================================================================
; rtl8139_rd_d — read 32-bit dword register from RTL8139
;   IN:  al = register offset
;   OUT: ebx = 32-bit value
; Uses native 32-bit I/O instruction for correctness and speed.
; ============================================================================
rtl8139_rd_d:
    push    dx
    push    eax
    mov     dx, word [nic_base]
    mov     ah, 0
    add     dx, ax          ; dx = nic_base + register offset
    xor     eax, eax
    in      eax, dx         ; read 4 bytes (1 x 32-bit I/O cycle)
    mov     ebx, eax
    pop     eax
    pop     dx
    ret

; ============================================================================
; net_init — probe for Realtek RTL8139 NIC via PCI config space
; ============================================================================
net_init:
    push    ebx
    push    ecx
    push    edx
    push    edi
    mov     dword [nic_base], -1
    dbg_puts "[A4X] net_init: scanning PCI for RTL8139 (10EC:8139)", 13, 10, 0
    ; PCI config space scan: iterate bus 0, device 0..31, function 0.
    ; CONFIG_ADDRESS port = 0xCF8, CONFIG_DATA port = 0xCFC.
    ; Address format: 0x80000000 | (bus<<16) | (device<<11) | (func<<8) | (reg & 0xFC)
    ; RTL8139: vendor 0x10EC, device 0x8139 → dword at config reg 0 = 0x813910EC (LE in EAX).
    xor     ebx, ebx            ; ebx = device index (0..31)
.np_scan:
    cmp     ebx, 32
    jae     .np_notfound
    ; eax = 0x80000000 | (device<<11)  (bus=0, func=0, reg=0)
    mov     eax, ebx
    shl     eax, 11
    or      eax, 0x80000000
    mov     dx, 0xCF8
    out     dx, eax
    mov     dx, 0xCFC
    in      eax, dx
    ; vendor:device = 10EC:8139 → EAX = 0x813910EC
    cmp     eax, 0x813910EC
    je      .np_found
    inc     ebx
    jmp     .np_scan
.np_found:
    ; Read BAR0 (config reg 0x10) to get I/O base.
    mov     eax, ebx
    shl     eax, 11
    or      eax, 0x80000000
    or      eax, 0x10
    mov     dx, 0xCF8
    out     dx, eax
    mov     dx, 0xCFC
    in      eax, dx
    ; BAR0 bit 0 = 1 means I/O space. Mask low 2 bits to get base.
    test    al, 1
    jz      .np_notfound        ; BAR0 is memory-mapped, not I/O
    and     eax, 0xFFFFFFFC
    mov     word [nic_base], ax
    mov     byte [nic_type], 1
    dbg_puts "[A4X] RTL8139 found at I/O 0x", 0
    movzx   eax, word [nic_base]
    dbg_hex32
    dbg_nl
    ; Enable PCI Bus Mastering (COMMAND reg 0x04, bit 2 = Bus Master)
    ; Without this, pci_dma_read returns zeros on some QEMU builds.
    mov     eax, ebx
    shl     eax, 11
    or      eax, 0x80000000
    or      eax, 0x04            ; config reg 0x04 (COMMAND)
    mov     dx, 0xCF8
    out     dx, eax              ; set CONFIG_ADDRESS
    mov     dx, 0xCFC
    in      eax, dx             ; read 32-bit (STATUS:COMMAND)
    or      eax, 0x04           ; set Bus Master Enable bit
    out     dx, eax             ; write back (CONFIG_ADDRESS still set)
    dbg_puts "[A4X] PCI Bus Mastering enabled", 13, 10, 0
    jmp     .net_iInit
.np_notfound:
    dbg_puts "[A4X] net_init: no RTL8139 NIC found", 13, 10, 0
    jmp     .net_ret
.net_iInit:
    ; --- RTL8139 initialization sequence (CORRECTED register map per QEMU RTL8139C) ---
    ; 1. Disable interrupts: IMR = 0 at 0x3C (word, write both bytes)
    mov     al, 0x3C
    mov     ah, 0
    call    rtl8139_wr
    mov     al, 0x3D
    mov     ah, 0
    call    rtl8139_wr
    ; 2. Software reset via CR.RESET bit (0x37 bit 4 = 0x10)
    ;    Write 0x10 to CR to trigger reset, then POLL until RST self-clears.
    ;    This is required per RTL8139 spec — subsequent register writes fail
    ;    if RST is still asserted (which caused TE bit to be ignored earlier).
    mov     al, 0x37
    mov     ah, 0x10
    call    rtl8139_wr
    mov     ecx, 80000
.rst_wait:
    mov     al, 0x37
    call    rtl8139_rd
    test    al, 0x10            ; RST (bit 4) still asserted?
    jz      .rst_done           ; RST cleared → proceed
    dec     ecx
    jnz     .rst_wait
.rst_done:
    mov     ecx, 200            ; small settle delay after RST clear
.rst_settle:
    dec     ecx
    jnz     .rst_settle
    ; 3. Explicitly disable C+ mode: write 0 to CpCmd (0xE0-0xE1, 16-bit)
    ;    Ensures standard-mode TX uses TxAddr[0] as buffer address (not descriptor ring).
    ;    Use TWO 8-bit writes to work around QEMU 16-bit I/O decode bug on some builds.
    mov     al, 0xE0
    mov     ah, 0
    call    rtl8139_wr
    mov     al, 0xE1
    mov     ah, 0
    call    rtl8139_wr
    dbg_puts "[A4X] C+ mode disabled (standard TX mode)", 13, 10, 0
    ; 4. Write MAC address (0x00-0x05) - this part was already correct
    mov     eax, [eth_myt_mac]
    mov     [nic_mac_lo], eax
    mov     ax, [eth_myt_mac+4]
    mov     [nic_mac_hi], ax
    ; If MAC is zero, use default
    mov     eax, [nic_mac_lo]
    test    eax, eax
    jnz     .rtl_mac_ok
    mov     ax, [nic_mac_hi]
    test    ax, ax
    jnz     .rtl_mac_ok
    ; Set default MAC: 52:54:00:12:34:56 (LE dword=0x12005452, LE word=0x5634)
    mov     eax, 0x12005452
    mov     [nic_mac_lo], eax
    mov     ax, 0x5634
    mov     [nic_mac_hi], ax
.rtl_mac_ok:
    ; Unlock Cfg9346 (offset 0x50) to allow writes to MAC, RCR, TCR config registers.
    ;   Cfg9346 = 0xC0 → Unlock (EEM=Programming Enable)
    ;   Cfg9346 = 0x00 → Lock   (EEM=Normal, config locked)
    ; QEMU's RTL8139 model may use internal state that only updates on lock transition.
    mov     al, 0x50
    mov     ah, 0xC0
    call    rtl8139_wr
    ; Write MAC to NIC registers via 32-bit write to IDR0 (0x00) + 16-bit write to IDR4 (0x04).
    ;   IDR0-3 (0x00-0x03) is a 32-bit register containing MAC bytes 0-3 (LE: byte0 at LSB).
    ;   IDR4-5 (0x04-0x05) is a 16-bit register containing MAC bytes 4-5 (LE: byte4 at LSB).
    ;   Single 8-bit writes don't work reliably in QEMU's RTL8139 model for the MAC registers.
    push    ebx
    push    eax
    push    edx
    mov     ebx, [nic_mac_lo]   ; ebx = MAC bytes 0-3 (LE)
    mov     dx, word [nic_base]
    add     dx, 0x00
    mov     eax, ebx
    out     dx, eax              ; 32-bit write to IDR0
    mov     dx, word [nic_base]
    add     dx, 0x04
    mov     ax, [nic_mac_hi]
    out     dx, ax               ; 16-bit write to IDR4
    ; Small settle delay
    mov     ecx, 100
.mac_settle:
    dec     ecx
    jnz     .mac_settle
    ; Read back MAC via 32-bit + 16-bit I/O for verification
    mov     dx, word [nic_base]
    add     dx, 0x00
    xor     eax, eax
    in      eax, dx
    push    eax
    dbg_puts "[A4X] MAC IDR0 readback=", 0
    pop     eax
    call    dbg_print_eax_hex
    dbg_puts " expected=", 0
    mov     eax, [nic_mac_lo]
    call    dbg_print_eax_hex
    dbg_puts 13, 10, 0
    mov     dx, word [nic_base]
    add     dx, 0x04
    xor     eax, eax
    in      ax, dx
    push    eax
    dbg_puts "[A4X] MAC IDR4 readback=", 0
    pop     eax
    call    dbg_print_eax_hex
    dbg_puts " expected=", 0
    movzx   eax, word [nic_mac_hi]
    call    dbg_print_eax_hex
    dbg_puts 13, 10, 0
    pop     edx
    pop     eax
    pop     ebx
    ; 4. RxConfig (RCR 0x44, 32-bit): accept all frame types, 8K ring, WRAP enabled
    ;    RCR register is at offset 0x44 (NOT 0x08 which is multicast MAR).
    ;    32-bit layout:
    ;      bit 0 (AAP)=1     — Accept All Packets (promiscuous, catch everything from SLIRP)
    ;      bit 1 (APM)=1     — Accept Physical Match (our MAC)
    ;      bit 2 (AM)=1      — Accept Multicast
    ;      bit 3 (AB)=1      — Accept Broadcast
    ;      bit 4 (AR)=1      — Accept Runt
    ;      bits 13-14=00     — RBLEN=8K ring
    ;      bit 15 (WRAP)=1   — Wrap at end of buffer (critical for ring operation)
    ;    RCR = 0x8000 | 0x01 | 0x02 | 0x04 | 0x08 | 0x10 = 0x0000801F
    push    ebx
    mov     ebx, 0x0000801F     ; RCR: AAP|APM|AM|AB|AR + WRAP + RBLEN=00 (8K)
    mov     al, 0x44
    call    rtl8139_wr_d
    ; Verify RCR write via direct 32-bit I/O read-back
    mov     dx, word [nic_base]
    add     dx, 0x44
    xor     eax, eax
    in      eax, dx
    push    eax
    dbg_puts "[A4X] RCR readback=", 0
    pop     eax
    call    dbg_print_eax_hex
    dbg_puts 13, 10, 0
    pop     ebx
    ; Lock Cfg9346 back to 0x00 to commit config registers.
    ;   This lock transition is what makes QEMU's RTL8139 model update its
    ;   internal RX filter state (MAC match, RCR accept mask) from the
    ;   register file to the active receive filter logic.
    mov     al, 0x50
    mov     ah, 0x00
    call    rtl8139_wr
    ; 5. TxConfig (TCR 0x40, 4 bytes): Tx DMA unlimited + IFG normal
    push    ebx
    mov     ebx, 0x00000007     ; MXDMA = Unlimited
    mov     al, 0x40
    call    rtl8139_wr_d
    pop     ebx
    ; 6. Set up TX buffer addresses at TSAD0-3 (offsets 0x20,0x24,0x28,0x2C).
    ;    QEMU's RTL8139 requires rotating TX descriptors: each TX must use a
    ;    different descriptor (TSAD0→1→2→3→0) because rtl8139_transmit_one()
    ;    refuses to retransmit on a descriptor still marked TxHostOwns (0x2000).
    ;    All four point to the same rtl8139_tx_buf since we copy each frame
    ;    there immediately before sending.
    push    ebx
    mov     ebx, rtl8139_tx_buf
    mov     al, 0x20
    call    rtl8139_wr_d
    mov     al, 0x24
    call    rtl8139_wr_d
    mov     al, 0x28
    call    rtl8139_wr_d
    mov     al, 0x2C
    call    rtl8139_wr_d
    dbg_puts "[A4X] TSAD0-3=tx_buf set (4 TX descriptors for rotation)", 13, 10, 0
    pop     ebx
    ; 7. Set up RX buffer address at RBSTART = 0x30-0x33 (4 bytes, 256-byte aligned, 8K)
    push    ebx
    mov     ebx, rtl8139_rx_buf
    mov     al, 0x30
    call    rtl8139_wr_d
    ; Verify RBSTART was written
    mov     al, 0x30
    call    rtl8139_rd_d
    push    ebx
    push    eax
    dbg_puts "[A4X] RBSTART=", 0
    mov     eax, ebx
    call    dbg_print_eax_hex
    dbg_puts " (rx_buf=", 0
    mov     eax, rtl8139_rx_buf
    call    dbg_print_eax_hex
    dbg_puts ")", 13, 10, 0
    pop     eax
    pop     ebx
    pop     ebx
    ; 8. Initialize CAPR + CBR (offsets 0x38-0x3B, 32-bit register pair).
    ;    RTL8139 groups CAPR (0x38-0x39, Current Address of Packet Read) and
    ;    CBR (0x3A-0x3B, Current Buffer Read) as a single 32-bit register.
    ;    Some QEMU builds only accept 32-bit writes to this pair — 8-bit or
    ;    16-bit writes silently drop the low byte, leaving CAPR at wrong value.
    ;    CAPR = 0xFFF0 means read pos = (0xFFF0 + 0x10) % 8K = 0 (ring start).
    ;    CBR = 0xFFF0 (copy of CAPR, written same value for safety).
    ;    32-bit layout (LE): bits [15:0] = CAPR, bits [31:16] = CBR.
    push    ebx
    mov     ebx, 0xFFF0FFF0     ; CAPR=0xFFF0 (read_pos=(0xFFF0+0x10)%8K=0), CBR=0xFFF0
    mov     al, 0x38
    call    rtl8139_wr_d
    pop     ebx
    ; Verify CAPR via 32-bit read (0x38)
    mov     al, 0x38
    call    rtl8139_rd_d        ; ebx = CBR:CAPR
    push    eax
    push    ebx
    dbg_puts "[A4X] CAPR=", 0
    movzx   eax, bx             ; low 16-bit = CAPR
    call    dbg_print_eax_hex
    dbg_puts " CBR=", 0
    shr     ebx, 16             ; high 16-bit = CBR
    mov     eax, ebx
    call    dbg_print_eax_hex
    dbg_puts 13, 10, 0
    pop     ebx
    pop     eax
    ; 9. Clear ISR flags at 0x3E (write 1 to clear) - clear all pending interrupts.
    ;    Use 16-bit write for QEMU reliability (ISR is 16-bit register).
    mov     al, 0x3E
    mov     bx, 0xFFFF
    call    rtl8139_wr_w
    ; 9b. IMR not needed: eth_rx polls the ring buffer directly (Method 2).
    ;     Enabling IMR causes QEMU to raise interrupts that interfere with the CPU
    ;     (no IDT handler for the PCI IRQ line). Leave IMR at default 0.
    ; 10. Enable TX + RX via CR (offset 0x37).
    ;     RTL8139 CR bit assignments (matching Linux 8139too.c driver):
    ;       bit 0 = RxBufEmpty (self-clearing), bit 2 = TE (0x04), bit 3 = RE (0x08), bit 4 = RST (0x10)
    ;     CR = 0x0C = TE(0x04) | RE(0x08).  RST(bit4) MUST be 0 after reset completes.
    ;     NOTE: Earlier code used 0x06 (bits 1+2) which only set TE, NOT RE — RX was never enabled!
    mov     ecx, 3
.cr_retry:
    mov     dx, word [nic_base]
    add     dx, 0x37
    mov     al, 0x0C            ; TE(0x04) | RE(0x08) = TX and RX enabled
    out     dx, al
    ; Short settle delay
    push    ecx
    mov     ecx, 500
.cr_d1:
    dec     ecx
    jnz     .cr_d1
    pop     ecx
    ; Read back and verify both TE and RE are set
    mov     dx, word [nic_base]
    add     dx, 0x37
    in      al, dx
    and     al, 0x0C            ; mask only TE(0x04) and RE(0x08) bits
    cmp     al, 0x0C
    je      .cr_ok
    dec     ecx
    jnz     .cr_retry
.cr_ok:
    ; Read CR again with full value for debug display
    mov     dx, word [nic_base]
    add     dx, 0x37
    in      al, dx
    mov     bl, al              ; save CR value
    dbg_puts "[A4X] RTL8139 CR readback=0x", 0
    mov     al, bl
    dbg_hex8
    dbg_nl
    dbg_puts "[A4X] RTL8139 init CR=0C TX+RX on (TE|RE, no RST)", 13, 10, 0
    ; 11. Re-write CAPR+CBR AFTER CR TE/RE enable using direct inline I/O.
    ;     The helper functions rtl8139_wr_d / rtl8139_wr_w silently fail on some QEMU
    ;     builds for the CAPR/CBR pair (0x38-0x3B) even though they work for other regs.
    ;     Use a direct 32-bit `out dx, eax` first (native dword I/O).  If that reads
    ;     back as 0, fall back to FOUR 8-bit writes (one per byte at 0x38..0x3B).
    ;     CAPR must be 0xFFF0 so QEMU sees the full RX ring as free, otherwise the
    ;     60-byte ARP broadcast from SLIRP is rejected (needs 64+ bytes free space).
    push    ebx
    push    ecx
    push    eax
    push    edx
    ; Try direct 32-bit write to 0x38: bits [15:0]=CAPR, [31:16]=CBR
    mov     dx, word [nic_base]
    add     dx, 0x38
    mov     eax, 0xFFF0FFF0     ; CAPR=0xFFF0 (read_pos=(0xFFF0+0x10)%8K=0), CBR=0xFFF0
    out     dx, eax
    ; Small settle delay
    mov     ecx, 200
.capr_w1:
    dec     ecx
    jnz     .capr_w1
    ; Read back directly via 32-bit I/O
    mov     dx, word [nic_base]
    add     dx, 0x38
    xor     eax, eax
    in      eax, dx
    test    eax, eax
    jnz     .capr_write_ok          ; 32-bit worked, skip fallback
    ; FALLBACK: FOUR 8-bit writes to offsets 0x38, 0x39, 0x3A, 0x3B
    ; CAPR low = 0xF0 (0x38), CAPR high = 0xFF (0x39),
    ; CBR low = 0xF0 (0x3A), CBR high = 0xFF (0x3B)
    mov     ah, 0xF0
    mov     dx, word [nic_base]
    add     dx, 0x38
    mov     al, ah
    out     dx, al                  ; 0x38 = 0xF0 (CAPR low)
    inc     dx
    mov     al, 0xFF
    out     dx, al                  ; 0x39 = 0xFF (CAPR high)
    inc     dx
    mov     al, 0xF0
    out     dx, al                  ; 0x3A = 0xF0 (CBR low)
    inc     dx
    mov     al, 0xFF
    out     dx, al                  ; 0x3B = 0xFF (CBR high)
    mov     ecx, 200
.capr_w2:
    dec     ecx
    jnz     .capr_w2
.capr_write_ok:
    ; Verify via direct 32-bit in
    mov     dx, word [nic_base]
    add     dx, 0x38
    xor     eax, eax
    in      eax, dx
    mov     ebx, eax                ; save for display
    pop     edx
    pop     eax                     ; restore scratch eax (careful: ebx holds value)
    push    eax
    push    edx
    dbg_puts "[A4X] post-CR CAPR=", 0
    movzx   eax, bx
    call    dbg_print_eax_hex
    dbg_puts " CBR=", 0
    shr     ebx, 16
    mov     eax, ebx
    call    dbg_print_eax_hex
    dbg_puts 13, 10, 0
    pop     edx
    pop     eax
    pop     ecx
    pop     ebx
    dbg_puts "[A4X] RTL8139 initialized OK", 13, 10, 0
    jmp     .net_ret
.net_idone:
    cmp     byte [nic_type], 1
    je      .net_ret
    dbg_puts "[A4X] net_init: no RTL8139 NIC found", 13, 10, 0
.net_ret:
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; dbg_putal_hex — print AL as 2 hex digits to port 0xE9
; ============================================================================
dbg_putal_hex:
    push    eax
    push    ecx
    mov     ah, al
    mov     ecx, 4
    ; high nibble
    mov     al, ah
    shr     al, cl
    and     al, 0x0F
    add     al, '0'
    cmp     al, '9'
    jbe     .pah_h
    add     al, 7
.pah_h:
    out     0xE9, al
    ; low nibble
    mov     al, ah
    and     al, 0x0F
    add     al, '0'
    cmp     al, '9'
    jbe     .pah_l
    add     al, 7
.pah_l:
    out     0xE9, al
    pop     ecx
    pop     eax
    ret

; ============================================================================
; dbg_print_eax_hex — print EAX as 8 hex digits to port 0xE9
; ============================================================================
dbg_print_eax_hex:
    push    eax
    push    ecx
    mov     ecx, 28
.dph_loop:
    push    eax
    shr     eax, cl
    and     eax, 0x0F
    add     al, '0'
    cmp     al, '9'
    jbe     .dph_ok
    add     al, 7
.dph_ok:
    out     0xE9, al
    pop     eax
    sub     ecx, 4
    jns     .dph_loop
    pop     ecx
    pop     eax
    ret

; ============================================================================
; dbg_print_eax_dec — print unsigned integer in EAX as decimal to port 0xE9
;   (suppresses leading zeros, prints at least one '0' if eax == 0)
; ============================================================================
dbg_print_eax_dec:
    push    eax
    push    ebx
    push    ecx
    push    edx
    ; Special case: eax == 0, just print '0'
    test    eax, eax
    jnz     .dpd_count
    mov     al, '0'
    out     0xE9, al
    jmp     .dpd_d
.dpd_count:
    ; Compute decimal digits on stack (push LSD first, pop MSD first)
    xor     ecx, ecx              ; digit counter
    mov     ebx, 10               ; divisor
.dpd_div:
    test    eax, eax
    jz      .dpd_pop
    xor     edx, edx
    div     ebx                   ; eax = eax/10, edx = eax%10
    add     dl, '0'
    push    edx
    inc     ecx
    jmp     .dpd_div
.dpd_pop:
    test    ecx, ecx
    jz      .dpd_d
    pop     eax
    out     0xE9, al
    dec     ecx
    jmp     .dpd_pop
.dpd_d:
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; pe_parse — parse PE32 file in pe_download_buf[0..pe_download_len)
;   IN:  pe_download_buf, pe_download_len
;   OUT: pe_state = 1 (valid PE32) or 0 (invalid)
;        fills pe_pCOFF_off, pe_sections, pe_optional_size, pe_entry,
;        pe_baseofcode, pe_baseofdata, pe_imagebase, pe_sectionalign,
;        pe_filealign, pe_datadir_off, pe_sectable_off
;        AL = 1 success, 0 fail
; ============================================================================
pe_parse:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi

    ; 1. Check MZ magic (offset 0, word = 0x5A4D)
    mov     ax, [pe_download_buf]
    cmp     ax, 0x5A4D
    jne     .pp_invalid

    ; 2. Check pe_download_len >= 64 (min PE header)
    mov     eax, [pe_download_len]
    cmp     eax, 64
    jb      .pp_invalid

    ; 3. Read e_lfanew (offset 0x3C, dword)
    mov     eax, [pe_download_buf + 0x3C]

    ; e_lfanew must be within file bounds
    cmp     eax, [pe_download_len]
    jae     .pp_invalid

    ; 4. Check PE\0\0 signature (e_lfanew, dword = 0x00004550)
    cmp     dword [pe_download_buf + eax], 0x00004550
    jne     .pp_invalid

    ; eax = e_lfanew. COFF header at e_lfanew + 4
    add     eax, 4
    mov     [pe_pCOFF_off], eax

    ; 5. Parse COFF header (+0..+18, 20 bytes)
    ;    NumberOfSections at COFF+2 (word)
    mov     bx, [pe_download_buf + eax + 2]
    mov     [pe_sections], bx
    ;    SizeOfOptionalHeader at COFF+16 (word)
    mov     bx, [pe_download_buf + eax + 16]
    mov     [pe_optional_size], bx

    ; 6. Optional Header at COFF+20
    add     eax, 20
    ; Validate Optional Header has enough remaining bytes
    mov     ecx, [pe_download_len]
    sub     ecx, eax
    cmp     ecx, 96
    jb      .pp_invalid

    ;    Magic at Optional+0 (word)
    mov     bx, [pe_download_buf + eax]
    cmp     bx, 0x10B                     ; PE32 magic
    jne     .pp_invalid                   ; don't support PE32+

    ; 7. Parse Optional Header key fields
    ;    AddressOfEntryPoint at Optional+16 (dword)
    mov     ebx, [pe_download_buf + eax + 16]
    mov     [pe_entry], ebx
    ;    BaseOfCode at Optional+20 (dword)
    mov     ebx, [pe_download_buf + eax + 20]
    mov     [pe_baseofcode], ebx
    ;    BaseOfData at Optional+24 (dword, PE32 only)
    mov     ebx, [pe_download_buf + eax + 24]
    mov     [pe_baseofdata], ebx
    ;    ImageBase at Optional+28 (dword)
    mov     ebx, [pe_download_buf + eax + 28]
    mov     [pe_imagebase], ebx
    ;    SectionAlignment at Optional+32 (dword)
    mov     ebx, [pe_download_buf + eax + 32]
    mov     [pe_sectionalign], ebx
    ;    FileAlignment at Optional+36 (dword)
    mov     ebx, [pe_download_buf + eax + 36]
    mov     [pe_filealign], ebx

    ; 8. DataDirectory offset = COFF+20+96 = COFF+116
    mov     ebx, [pe_pCOFF_off]
    add     ebx, 116
    mov     [pe_datadir_off], ebx

    ; 9. Section Table offset = COFF+20+SizeOfOptionalHeader
    mov     ebx, [pe_pCOFF_off]
    add     ebx, 20
    mov     ecx, [pe_optional_size]
    add     ebx, ecx
    mov     [pe_sectable_off], ebx

    ; 10. Mark parse success
    mov     byte [pe_state], 1
    dbg_puts "[PE] dl+parse OK", 13, 10, 0
    mov     al, 1
    jmp     .pp_out

.pp_invalid:
    mov     byte [pe_state], 0
    xor     al, al
.pp_out:
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; pe_rva_to_fileoff — convert RVA to file offset within pe_download_buf
;   IN:  eax = RVA
;   OUT: eax = file offset, or 0xFFFFFFFF if unmapped
;   Clobbers: eax ebx ecx edx esi edi
; ============================================================================
pe_rva_to_fileoff:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi

    mov     ecx, [pe_sections]
    test    ecx, ecx
    jz      .rva_fail
    mov     esi, eax                 ; save RVA

    mov     edi, pe_download_buf     ; edi = buffer base (label, NOT [ptr])
    add     edi, [pe_sectable_off]  ; edi → section table

.rva_section_loop:
    test    ecx, ecx
    jz      .rva_fail

    ; section VA at +12
    mov     ebx, [edi + 12]
    ; section VirtualSize at +8
    mov     edx, [edi + 8]

    cmp     esi, ebx
    jb      .rva_fail               ; rva < section VA, and sections sorted

    add     edx, ebx                ; edx = section VA + size
    cmp     esi, edx
    jae     .rva_next_section

    ; found
    mov     eax, [edi + 20]         ; PointerToRawData
    sub     esi, ebx                ; offset within section
    add     eax, esi
    jmp     .rva_out

.rva_next_section:
    add     edi, 40
    dec     ecx
    jmp     .rva_section_loop

.rva_fail:
    mov     eax, 0xFFFFFFFF
.rva_out:
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; pe_apply_relocs — apply Base Relocation table (DIR32NB)
;   IN:  pe_reloc_delta = pe_load_base - pe_imagebase
;        pe_datadir_off, pe_download_buf, pe_download_len
;   Clobbers: eax ebx ecx edx esi edi
; ============================================================================
pe_apply_relocs:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi

    ; delta check
    mov     eax, [pe_reloc_delta]
    test    eax, eax
    jz      .reloc_done

    ; BaseRelocationDir at DataDirectory[4], offset 4*8=32
    mov     esi, [pe_datadir_off]
    add     esi, 32
    mov     esi, [pe_download_buf + esi]
    test    esi, esi
    jz      .reloc_done             ; no relocation table

    ; RVA → file offset
    push    esi
    call    pe_rva_to_fileoff
    pop     ecx
    cmp     eax, 0xFFFFFFFF
    je      .reloc_done
    mov     edi, pe_download_buf     ; buffer base (label, NOT [ptr])
    add     edi, eax

.reloc_walk:
    ; bounds check: edi - pe_download_buf < pe_download_len
    mov     eax, edi
    sub     eax, pe_download_buf
    cmp     eax, [pe_download_len]
    jae     .reloc_done

    mov     ebx, [edi]              ; block VirtualAddress
    mov     ecx, [edi + 4]          ; block SizeOfBlock
    test    ecx, ecx
    jz      .reloc_done
    cmp     ecx, 8
    jbe     .reloc_done

    ; base_addr for this block
    mov     edx, [pe_load_base]
    add     edx, ebx

    sub     ecx, 8
    shr     ecx, 1
    add     edi, 8

.reloc_entry_loop:
    test    ecx, ecx
    jz      .reloc_walk

    mov     bx, [edi]
    movzx   eax, bh                 ; type (hi 4 bits)
    and     eax, 0x0F
    cmp     eax, 3
    jne     .reloc_skip

    ; offset = lo 12 bits
    and     bx, 0x0FFF
    movzx   eax, bx
    add     eax, edx                ; target address (absolute)

    ; safety: within 0x40000 of pe_load_base
    ; Save loop counter ecx, use edx for check (edx=base_addr no longer needed)
    push    ecx
    mov     ecx, eax
    sub     ecx, [pe_load_base]
    cmp     ecx, 0x40000
    pop     ecx
    jae     .reloc_skip

    ; Read current value, add delta, write back
    ; (cannot use add [eax], [pe_reloc_delta] — mem-mem forbidden)
    push    eax
    push    ecx                      ; save loop counter again
    mov     ecx, [eax]
    add     ecx, [pe_reloc_delta]
    mov     [eax], ecx
    pop     ecx                      ; restore loop counter
    pop     eax

.reloc_skip:
    add     edi, 2
    dec     ecx
    jmp     .reloc_entry_loop

.reloc_done:
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; pe_load — copy PE sections to pe_load_base, apply relocations
;   IN:  pe_sections, pe_sectable_off, pe_download_buf, pe_download_len
;   OUT: pe_state = 1 (success), pe_state = 0 (fail)
;        AL = 1/0
;   Clobbers: eax ebx ecx edx esi edi
; ============================================================================
pe_load:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi

    ; Set load base
    mov     eax, PE_LOAD_BASE
    mov     [pe_load_base], eax

    ; Zero init
    mov     edi, eax
    mov     ecx, PE_MAX_SIZE / 4
    xor     eax, eax
    rep     stosd

    mov     ecx, [pe_sections]
    test    ecx, ecx
    jz      .load_no_sections

    mov     esi, pe_download_buf     ; buffer base (label, NOT [ptr])
    add     esi, [pe_sectable_off]

.load_section_loop:
    test    ecx, ecx
    jz      .load_done

    ; Read section fields
    mov     ebx, [esi + 12]         ; VirtualAddress
    mov     edx, [esi + 16]         ; SizeOfRawData
    mov     edi, [esi + 20]         ; PointerToRawData

    test    ebx, ebx
    jz      .load_next_section
    test    edx, edx
    jz      .load_next_section
    test    edi, edi
    jz      .load_next_section

    ; Bounds: edi + edx <= pe_download_len
    push    esi
    push    ebx
    push    edx
    push    edi
    mov     esi, edi
    add     esi, edx
    cmp     esi, [pe_download_len]
    pop     edi
    pop     edx
    pop     ebx
    pop     esi
    ja      .load_next_section

    ; Source pointer
    push    ebx
    push    edx
    push    edi
    push    esi
    push    ecx                      ; save section counter
    mov     esi, pe_download_buf     ; buffer base (label, NOT [ptr])
    add     esi, edi                ; edi = PointerToRawData
    mov     edi, [pe_load_base]
    add     edi, ebx                ; ebx = VirtualAddress

    mov     ecx, edx
    shr     ecx, 2
    rep     movsd
    mov     ecx, edx
    and     ecx, 3
    rep     movsb
    pop     ecx                      ; restore section counter
    pop     esi
    pop     edi
    pop     edx
    pop     ebx

.load_next_section:
    add     esi, 40
    dec     ecx
    jmp     .load_section_loop

.load_done:
    ; 4. Apply relocations
    mov     eax, [pe_load_base]
    sub     eax, [pe_imagebase]
    mov     [pe_reloc_delta], eax
    call    pe_apply_relocs

    mov     byte [pe_state], 1
    mov     al, 1
    jmp     .load_out

.load_no_sections:
    mov     byte [pe_state], 0
    xor     al, al
    jmp     .load_out

.load_out:
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; exe_load — load bytecode for run_prog exe entry.
;   Priority:
;     1. file_table[run_prog].FS_CONTENT_OFF != UNSET
;          -> copy from file_contents_pool[content_off] (INSTALLED EXE)
;     2. dl_valid == 1  -> copy transient dl_code (rare/legacy path)
;     3. fall back to built-in ludashi_code (slot 6) / app_code (slot 7)
; ============================================================================
exe_load:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi
    mov     byte [exe_running], 0
    ; ========================================================================
    ; Priority 0: already-parsed PE (pe_state==1, pe_download_buf filled)
    ; Pipeline: pe_load → pe_resolve_imports → pe_exec
    ; ========================================================================
    cmp     byte [pe_state], 1
    jne     .el_prio05
.el_prio0_start:
    call    pe_load
    push    eax                     ; dbg_puts clobbers AL
    dbg_puts "[A4X] el: pe_load ret", 13, 10, 0
    pop     eax
    test    al, al
    jz      .el_d
    call    pe_resolve_imports
    push    eax                     ; dbg_puts clobbers AL
    dbg_puts "[A4X] el: imports ret IAT0=", 0
    mov     eax, [0x402060]
    call    dbg_print_eax_hex
    dbg_puts 13, 10, 0
    pop     eax
    test    al, al
    jz      .el_d
    call    pe_exec
    push    eax                     ; dbg_puts clobbers AL
    dbg_puts "[A4X] el: exec ret", 13, 10, 0
    pop     eax
    test    al, al
    jz      .el_d
    dbg_puts "[PE] exec returned OK", 13, 10, 0
    mov     al, 1                   ; OUT: AL=1 — dbg_puts' lodsb leaves AL=0
    jmp     .el_d
.el_prio05:
    ; Priority 0.5: file_table[run_prog] is FS_TYPE_FILE_EXE with PE content
    xor     eax, eax
    mov     al, [run_prog]
    test    al, al
    jz      .el_prio1
    mov     ecx, FS_SZ
    imul    eax, ecx
    add     eax, file_table
    cmp     byte [eax+16], FS_TYPE_FILE_EXE
    jne     .el_prio1
    mov     edx, [eax + FS_CONTENT_OFF]
    cmp     edx, FS_CONTENT_UNSET
    je      .el_prio1
    ; Copy from file_contents_pool to pe_download_buf
    push    ebx
    push    ecx
    push    esi
    push    edi
    mov     esi, file_contents_pool
    add     esi, edx
    mov     edi, pe_download_buf
    mov     ecx, [eax + FS_CONTENT_LEN]
    cmp     ecx, PE_DOWNLOAD_MAX
    jbe     .el_pe05_ok
    mov     ecx, PE_DOWNLOAD_MAX
.el_pe05_ok:
    mov     ebx, ecx                                ; preserve actual copy length for [pe_download_len]
    rep     movsb
    mov     [pe_download_len], ebx                  ; store pre-rep length (ecx is now 0)
    ; Check MZ magic
    mov     ax, [pe_download_buf]
    cmp     ax, 0x5A4D
    jne     .el_pe05_bad
    ; Parse PE
    call    pe_parse
    test    al, al
    jz      .el_pe05_bad
    ; Success — pe_state is now 1, jump to Priority 0 pipeline
    pop     edi
    pop     esi
    pop     ecx
    pop     ebx
    jmp     .el_prio0_start
.el_pe05_bad:
    pop     edi
    pop     esi
    pop     ecx
    pop     ebx
.el_prio1:
    xor     eax, eax
    mov     al, [run_prog]
    test    al, al
    jz      .el_d
    mov     ecx, FS_SZ
    imul    eax, ecx
    add     eax, file_table         ; eax = &file_table[j]
    cmp     byte [eax+16], FS_TYPE_FILE_EXE
    jne     .el_d
    ; Priority 1: installed content?
    mov     edx, [eax + FS_CONTENT_OFF]
    cmp     edx, FS_CONTENT_UNSET
    je      .el_prio2
    ; yes -> copy file_contents_pool[edx] to exe_code (up to content_len bytes)
    mov     esi, file_contents_pool
    add     esi, edx
    mov     ecx, [eax + FS_CONTENT_LEN]
    jmp     .el_clip_and_copy
.el_prio2:
    ; Priority 2: transient dl_valid == 1 (raw download, not yet installed)
    cmp     byte [dl_valid], 1
    jne     .el_def
    mov     esi, dl_code
    mov     ecx, DL_CODE_SZ
    jmp     .el_clip_and_copy
.el_def:
    cmp     byte [run_prog], 6
    jne     .el_app
    mov     esi, ludashi_code
    mov     ecx, 32
    jmp     .el_clip_and_copy
.el_app:
    mov     esi, app_code
    mov     ecx, 32
.el_clip_and_copy:
    ; clamp ecx <= EXE_CONTENT_CHUNK
    cmp     ecx, EXE_CONTENT_CHUNK
    jbe     .el_clip_ok
    mov     ecx, EXE_CONTENT_CHUNK
.el_clip_ok:
    push    ecx                      ; save for clear-tail length calc
    mov     edi, exe_code
    ; first clear entire exe_code buffer to 0 so stale bytes never leak
    push    ecx
    push    edi
    mov     ecx, EXE_CONTENT_CHUNK/4
    xor     eax, eax
    rep     stosd
    pop     edi
    pop     ecx
    rep     movsb                    ; copy actual bytecode body
    ; exe_running = 1 + init all VM state
    mov     byte [exe_running], 1
    xor     ax, ax
    mov     [exe_pc], ax
    mov     [exe_sp], ax
    mov     [exe_flags], al
    mov     [exe_done], al
    mov     [exe_delay], ax
    mov     [exe_out_len], ax
    mov     [exe_csp], al
    mov     [exe_zf], al
    pop     ecx                      ; discard earlier push (we don't need it)
.el_d:
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; exe_run — execute one bytecode step (called per tick)
; ============================================================================
exe_run:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi
    push    esi
    cmp     byte [exe_running], 1
    jne     .er_d
    cmp     byte [exe_done], 1
    je      .er_d
    mov     ax, [exe_delay]
    test    ax, ax
    jz      .er_ok
    dec     word [exe_delay]
    jmp     .er_d
.er_ok:
    mov     eax, [exe_pc]
    mov     esi, exe_code
    add     esi, eax
    mov     al, [esi]
    cmp     al, 0
    je      .er_halt
    cmp     al, 1
    je      .er_push
    cmp     al, 2
    je      .er_pop
    cmp     al, 3
    je      .er_print
    cmp     al, 4
    je      .er_add
    cmp     al, 5
    je      .er_sub
    cmp     al, 6
    je      .er_and
    cmp     al, 7
    je      .er_or
    cmp     al, 8
    je      .er_cmp
    cmp     al, 9
    je      .er_jz
    cmp     al, 10
    je      .er_jnz
    cmp     al, 11
    je      .er_call
    cmp     al, 12
    je      .er_ret
    cmp     al, 16
    je      .er_delay
    cmp     al, 0xFF
    je      .er_int
    cmp     al, 0x20
    je      .er_push2
    cmp     al, 0x21
    je      .er_push4
    cmp     al, 0x22
    je      .er_loadm
    cmp     al, 0x23
    je      .er_storm
    cmp     al, 0x24
    je      .er_printhex
    jmp     .er_skip
; --- HALT ---
.er_halt:
    mov     byte [exe_done], 1
%ifdef NET_TEST
    dbg_puts "[A4X] NET_TEST: VM halted, out_len=", 0
%endif
    jmp     .er_d
; --- PUSH imm8 ---
.er_push:
    mov     cl, [exe_sp]
    test    cl, cl
    jz      .er_skip
    dec     cl
    mov     [exe_sp], cl
    mov     al, [esi+1]
    mov     ebx, exe_stack
    shl     cl, 2
    mov     [ebx+ecx], al
    mov     ax, [exe_pc]
    add     ax, 2
    mov     [exe_pc], ax
    jmp     .er_up
; --- POP ---
.er_pop:
    mov     cl, [exe_sp]
    cmp     cl, 15
    jge     .er_skip
    mov     ebx, exe_stack
    shl     cl, 2
    xor     byte [ebx+ecx], 0
    inc     cl
    mov     [exe_sp], cl
    mov     ax, [exe_pc]
    add     ax, 1
    mov     [exe_pc], ax
    jmp     .er_up
; --- PRINT cstring (append to exe_out, advance PC past string+null) ---
.er_print:
    inc     esi                    ; skip opcode, esi -> string
    mov     edi, exe_out
    movzx   eax, word [exe_out_len]
    add     edi, eax               ; edi -> append position
.er_ploop:
    cmp     edi, exe_out + 59
    jae     .er_pdone              ; buffer full
    mov     al, [esi]
    test    al, al
    jz      .er_pdone              ; null terminator
    mov     [edi], al
    inc     esi
    inc     edi
    jmp     .er_ploop
.er_pdone:
    ; Advance esi to null terminator (if stopped early due to buffer full)
    cmp     byte [esi], 0
    je      .er_pskip
.er_padv:
    inc     esi
    cmp     byte [esi], 0
    jne     .er_padv
.er_pskip:
    inc     esi                    ; skip null terminator
    ; Set PC = esi - exe_code (esi now points past string+null)
    mov     eax, esi
    sub     eax, exe_code
    mov     [exe_pc], ax
    jmp     .er_up
; --- ADD: stack[top-1] += stack[top] ---
.er_add:
    mov     cl, [exe_sp]
    test    cl, cl
    jz      .er_skip
    mov     bl, cl
    dec     bl
    test    bl, bl
    jz      .er_skip
    mov     ebx, exe_stack
    mov     al, [ebx+4]
    mov     dl, [ebx]
    add     dl, al
    mov     [ebx], dl
    dec     cl
    mov     [exe_sp], cl
    mov     ax, [exe_pc]
    add     ax, 1
    mov     [exe_pc], ax
    jmp     .er_up
; --- SUB ---
.er_sub:
    mov     cl, [exe_sp]
    test    cl, cl
    jz      .er_skip
    mov     bl, cl
    dec     bl
    test    bl, bl
    jz      .er_skip
    mov     ebx, exe_stack
    mov     al, [ebx+4]
    mov     dl, [ebx]
    sub     dl, al
    mov     [ebx], dl
    dec     cl
    mov     [exe_sp], cl
    mov     ax, [exe_pc]
    add     ax, 1
    mov     [exe_pc], ax
    jmp     .er_up
; --- AND ---
.er_and:
    mov     cl, [exe_sp]
    test    cl, cl
    jz      .er_skip
    mov     bl, cl
    dec     bl
    test    bl, bl
    jz      .er_skip
    mov     ebx, exe_stack
    mov     al, [ebx+4]
    and     [ebx], al
    dec     cl
    mov     [exe_sp], cl
    mov     ax, [exe_pc]
    add     ax, 1
    mov     [exe_pc], ax
    jmp     .er_up
; --- OR ---
.er_or:
    mov     cl, [exe_sp]
    test    cl, cl
    jz      .er_skip
    mov     bl, cl
    dec     bl
    test    bl, bl
    jz      .er_skip
    mov     ebx, exe_stack
    mov     al, [ebx+4]
    or      [ebx], al
    dec     cl
    mov     [exe_sp], cl
    mov     ax, [exe_pc]
    add     ax, 1
    mov     [exe_pc], ax
    jmp     .er_up
; --- CMP: set ZF if stack[top-1] == stack[top] ---
.er_cmp:
    mov     cl, [exe_sp]
    test    cl, cl
    jz      .er_skip
    mov     bl, cl
    dec     bl
    test    bl, bl
    jz      .er_skip
    mov     ebx, exe_stack
    mov     al, [ebx+4]
    cmp     [ebx], al
    je      .er_cmp_z
    mov     byte [exe_zf], 0
    jmp     .er_cmp_d
.er_cmp_z:
    mov     byte [exe_zf], 1
.er_cmp_d:
    dec     cl
    mov     [exe_sp], cl
    mov     ax, [exe_pc]
    add     ax, 1
    mov     [exe_pc], ax
    jmp     .er_up
; --- JZ rel8 ---
.er_jz:
    mov     al, [esi+1]
    mov     bl, [exe_zf]
    test    bl, bl
    jz      .er_jnz_d
    mov     ax, [exe_pc]
    add     al, [esi+1]
    mov     [exe_pc], ax
    jmp     .er_jnz_d2
.er_jnz:
    mov     al, [esi+1]
    mov     bl, [exe_zf]
    test    bl, bl
    jnz     .er_jnz_d
    mov     ax, [exe_pc]
    add     al, [esi+1]
    mov     [exe_pc], ax
    jmp     .er_jnz_d2
.er_jnz_d:
    mov     ax, [exe_pc]
    add     ax, 2
    mov     [exe_pc], ax
.er_jnz_d2:
    jmp     .er_up
; --- CALL rel8 ---
.er_call:
    mov     cl, [exe_csp]
    cmp     cl, 7
    jge     .er_skip
    mov     al, [esi+1]
    mov     ax, [exe_pc]
    add     ax, 2
    mov     ebx, exe_cstack
    shl     cl, 2
    mov     [ebx+ecx], ax
    inc     cl
    mov     [exe_csp], cl
    mov     al, [esi+1]
    mov     ax, [exe_pc]
    add     al, [esi+1]
    mov     [exe_pc], ax
    jmp     .er_up
; --- RET ---
.er_ret:
    mov     cl, [exe_csp]
    test    cl, cl
    jz      .er_skip
    dec     cl
    mov     [exe_csp], cl
    mov     ebx, exe_cstack
    shl     cl, 2
    mov     ax, [ebx+ecx]
    mov     [exe_pc], ax
    jmp     .er_up
; --- DELAY imm8 ---
.er_delay:
    inc     esi
    mov     al, [esi]
    mov     [exe_delay], al
    mov     ax, [exe_pc]
    add     ax, 2
    mov     [exe_pc], ax
    jmp     .er_up
; --- INT imm8 (unhandled) ---
.er_int:
    inc     esi
    inc     esi
    mov     ax, [exe_pc]
    add     ax, 2
    mov     [exe_pc], ax
    jmp     .er_up
; --- PUSH_2 imm16 ---
.er_push2:
    mov     cl, [exe_sp]
    test    cl, cl
    jz      .er_skip
    dec     cl
    mov     [exe_sp], cl
    mov     ax, [esi+1]
    mov     ebx, exe_stack
    shl     cl, 2
    mov     [ebx+ecx], ax
    mov     ax, [exe_pc]
    add     ax, 3
    mov     [exe_pc], ax
    jmp     .er_up
; --- PUSH_4 imm32 ---
.er_push4:
    mov     cl, [exe_sp]
    test    cl, cl
    jz      .er_skip
    dec     cl
    mov     [exe_sp], cl
    mov     eax, [esi+1]
    mov     ebx, exe_stack
    shl     cl, 2
    mov     [ebx+ecx], eax
    mov     ax, [exe_pc]
    add     ax, 5
    mov     [exe_pc], ax
    jmp     .er_up
; --- LOAD_M: push [addr32] onto stack ---
.er_loadm:
    mov     cl, [exe_sp]
    test    cl, cl
    jz      .er_skip
    dec     cl
    mov     [exe_sp], cl
    mov     eax, [esi+1]
    mov     ebx, exe_stack
    shl     cl, 2
    mov     [ebx+ecx], eax
    mov     ax, [exe_pc]
    add     ax, 5
    mov     [exe_pc], ax
    jmp     .er_up
; --- STORE_M: pop stack value to [addr32] ---
.er_storm:
    mov     cl, [exe_sp]
    test    cl, cl
    jz      .er_skip
    mov     ebx, exe_stack
    shl     cl, 2
    mov     eax, [esi+1]
    mov     edx, [ebx+ecx]
    mov     [eax], edx
    dec     cl
    mov     [exe_sp], cl
    mov     ax, [exe_pc]
    add     ax, 5
    mov     [exe_pc], ax
    jmp     .er_up
; --- PRINT_HEX: print top of stack as hex string ---
.er_printhex:
    mov     cl, [exe_sp]
    test    cl, cl
    jz      .er_skip
    mov     ebx, exe_stack
    shl     cl, 2
    mov     eax, [ebx+ecx]
    mov     edi, exe_out
    mov     ecx, [exe_out_len]
    add     edi, ecx
    cmp     edi, exe_out+59
    jge     .er_up
    push    ebx
    mov     ebx, eax
    mov     ecx, 28
.er_phxloop:
    shr     ebx, cl
    and     bl, 0x0F
    add     bl, '0'
    cmp     bl, '9'
    jbe     .er_phxok
    add     bl, 7
.er_phxok:
    mov     [edi], bl
    inc     edi
    sub     ecx, 4
    jns     .er_phxloop
    pop     ebx
    mov     ax, [exe_pc]
    add     ax, 1
    mov     [exe_pc], ax
    jmp     .er_up
; --- Unknown opcode ---
.er_skip:
    mov     ax, [exe_pc]
    add     ax, 1
    mov     [exe_pc], ax
.er_up:
    ; Only update exe_out_len if edi points within exe_out[0..63]
    mov     eax, edi
    sub     eax, exe_out
    cmp     eax, 64
    jae     .er_up2
    mov     [exe_out_len], ax
.er_up2:
    mov     byte [exe_running], 1
.er_d:
    pop    esi
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; arp_send — e1000 MMIO: build tx ring + kick, send ARP request
; ============================================================================
arp_send:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi
    cmp     byte [nic_type], 1
    jne     .as_noeth
    ; Build 42-byte ARP request frame at net_tx_buf
    mov     edi, net_tx_buf
    ; Eth dst = ff:ff:ff:ff:ff:ff (broadcast)
    mov     dword [edi+0], 0xFFFFFFFF
    mov     word [edi+4], 0xFFFF
    ; Eth src = our MAC
    mov     eax, [nic_mac_lo]
    mov     dword [edi+6], eax
    mov     ax, [nic_mac_hi]
    mov     word [edi+10], ax
    ; EtherType 0x0806 (ARP) — big-endian on wire, LE word = 0x0608
    mov     word [edi+12], 0x0608
    ; ARP payload (28 bytes at edi+14)
    ; hw type 0x0001 → LE 0x0100
    mov     word [edi+14], 0x0100
    ; proto type 0x0800 → LE 0x0008
    mov     word [edi+16], 0x0008
    ; hw len = 6, proto len = 4
    mov     byte [edi+18], 6
    mov     byte [edi+19], 4
    ; opcode 0x0001 (request) → LE 0x0100
    mov     word [edi+20], 0x0100
    ; sender MAC
    mov     eax, [nic_mac_lo]
    mov     dword [edi+22], eax
    mov     ax, [nic_mac_hi]
    mov     word [edi+26], ax
    ; sender IP 10.0.2.15 → BE bytes 0A 00 02 0F → LE dword 0x0F02000A
    mov     dword [edi+28], 0x0F02000A
    ; target MAC = 00:00:00:00:00:00
    mov     dword [edi+32], 0
    mov     word [edi+36], 0
    ; target IP 10.0.2.2 → BE bytes 0A 00 02 02 → LE dword 0x0202000A
    mov     dword [edi+38], 0x0202000A
    ; Send via eth_send
    mov     word [net_tx_len], 42
    call    eth_send
    ; Record state + start timeout
    mov     byte [arp_state], 1
    mov     eax, [vtd_t]
    mov     [arp_timeout], eax
    jmp     .as_d
.as_noeth:
    mov     byte [arp_state], 0x40   ; ARP_FAILED_NO_NIC
.as_d:
    pop    edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; arp_check — poll rx_ring for ARP reply; update arp_state + arp_reply_mac
; Returns: al = arp_state
; ============================================================================
arp_check:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi
    push    esi
    ; Process ARP frame at nic_rx_data (called from eth_rx)
    mov     edi, nic_rx_data
    ; EtherType at offset 12: 0x0806 big-endian → LE word 0x0608
    mov     ax, [edi+12]
    cmp     ax, 0x0608
    jne     .ac_d
    ; ARP opcode at offset 20
    mov     ax, [edi+20]
    ; Check for ARP reply (0x0002 → LE 0x0200)
    cmp     ax, 0x0200
    je      .ac_reply
    ; Check for ARP request (0x0001 → LE 0x0100)
    cmp     ax, 0x0100
    je      .ac_request
    jmp     .ac_d
.ac_reply:
    ; Extract sender MAC at offset 22 (reply sender = target's MAC)
    mov     eax, [edi+22]
    mov     [arp_reply_mac], eax
    mov     ax, [edi+26]
    mov     [arp_reply_mac+4], ax
    ; Store sender IP at offset 28 for display
    mov     eax, [edi+28]
    mov     [arp_reply_ip], eax
    mov     byte [arp_state], 4       ; ARP_REPLY
    jmp     .ac_d
.ac_request:
    ; SLIRP sends ARP request for guest IP — must reply so it can send SYN-ACK back.
    ; Check if target IP (offset 38) matches our IP (10.0.2.15 = 0x0F02000A)
    mov     eax, [edi+38]
    cmp     eax, 0x0F02000A
    jne     .ac_d
    ; Build 42-byte ARP reply in net_tx_buf.
    ; esi reads from request (nic_rx_data), edi writes to reply (net_tx_buf).
    mov     esi, edi                ; esi = nic_rx_data (request frame)
    mov     edi, net_tx_buf        ; edi = net_tx_buf (reply frame)
    ; Eth dst = requester's MAC (ARP sender MAC at esi+22)
    mov     eax, [esi+22]
    mov     [edi+0], eax
    mov     ax, [esi+26]
    mov     [edi+4], ax
    ; Eth src = our MAC
    mov     eax, [nic_mac_lo]
    mov     [edi+6], eax
    mov     ax, [nic_mac_hi]
    mov     [edi+10], ax
    ; EtherType 0x0806 (ARP) → LE 0x0608
    mov     word [edi+12], 0x0608
    ; ARP payload (28 bytes)
    mov     word [edi+14], 0x0100   ; hw type 0x0001
    mov     word [edi+16], 0x0008   ; proto type 0x0800
    mov     byte [edi+18], 6       ; hw len
    mov     byte [edi+19], 4       ; proto len
    mov     word [edi+20], 0x0200  ; opcode = reply (0x0002)
    ; Sender MAC = our MAC
    mov     eax, [nic_mac_lo]
    mov     [edi+22], eax
    mov     ax, [nic_mac_hi]
    mov     [edi+26], ax
    ; Sender IP = our IP (10.0.2.15)
    mov     dword [edi+28], 0x0F02000A
    ; Target MAC = requester's MAC
    mov     eax, [esi+22]
    mov     [edi+32], eax
    mov     ax, [esi+26]
    mov     [edi+36], ax
    ; Target IP = requester's IP
    mov     eax, [esi+28]
    mov     [edi+38], eax
    ; Send via eth_send
    mov     word [net_tx_len], 42
    call    eth_send
    dbg_puts "[A4X] ARP: replied to request", 13, 10, 0
.ac_d:
    pop     esi
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; eth_send — send Ethernet frame pre-built at net_tx_buf via RTL8139
;   IN:  net_tx_len = frame length
;   OUT: net_send_state: 1=sent, 2=no NIC / still busy
;   Standard RTL8139 register map (QEMU uses this, NOT RTL8139C+ variant):
;     TSD0-3  = 0x10,0x14,0x18,0x1C (TX Status Desc 0-3: bits 0-12 = size,
;                                    bit 13 = TxHostOwns, bit 15 = TOK/TSR)
;     TSAD0-3 = 0x20,0x24,0x28,0x2C (TX Start Addr Desc 0-3: TX buffer phys addr)
;   Writing size to TSDx triggers TX DMA. QEMU's rtl8139_transmit_one() refuses
;   to retransmit on a descriptor still marked TxHostOwns (0x2000) from a prior
;   TX, so eth_send rotates through all 4 descriptors via tx_tail.
eth_send:
    push    edi
    push    edx
    push    ecx
    push    ebx
    push    eax
    cmp     byte [nic_type], 1
    jne     .es_no
    ; QEMU RTL8139 processes TX synchronously on TSD0 write — no OWN bit to poll.
    ; Copy frame from net_tx_buf to the TX buffer (rtl8139_tx_buf at TSAD0=0x20)
    mov     esi, net_tx_buf
    mov     edi, rtl8139_tx_buf
    movzx   ecx, word [net_tx_len]
    test    ecx, ecx
    jz      .es_no
    ; Limit to 1792 bytes (RTL8139 max TX per descriptor)
    cmp     cx, 1792
    jbe     .es_clip_ok
    mov     cx, 1792
.es_clip_ok:
    rep     movsb
    ; Print send length
    dbg_puts "[A4X] eth_send len=", 0
    movzx   eax, word [net_tx_len]
    call    dbg_print_eax_dec
    dbg_puts 13, 10, 0
    ; Debug: verify TSAD0 == rtl8139_tx_buf addr and peek tx_buf[0..3]
    push    esi
    push    ebx
    mov     al, 0x20
    call    rtl8139_rd_d          ; ebx = TSAD0 value
    dbg_puts "TSAD0=", 0
    mov     eax, ebx
    dbg_hex32
    dbg_puts " buf[0..3]=", 0
    mov     esi, rtl8139_tx_buf
    mov     eax, [esi]
    dbg_hex32
    dbg_nl
    pop     ebx
    pop     esi
    ; --- TX descriptor rotation (QEMU requires rotating TSAD0-3/TSD0-3) ---
    ; QEMU's rtl8139_transmit_one() refuses to retransmit on a descriptor
    ; still marked TxHostOwns (0x2000) from a prior TX.  Rotating through
    ; all 4 descriptors sidesteps this — each new TX uses a fresh descriptor.
    ; tx_tail = next descriptor index (0-3); advanced after each send.
    ;   TSDx  reg offset = 0x10 + tx_tail*4
    ;   TSADx reg offset = 0x20 + tx_tail*4
    movzx   ecx, byte [tx_tail]   ; ecx = tx_tail (0-3)
    shl     ecx, 2                ; ecx = tx_tail * 4

    ; Refresh TSADx = rtl8139_tx_buf (QEMU DMA reads TX data from here)
    push    ecx
    push    ebx
    mov     ebx, rtl8139_tx_buf
    mov     eax, ecx
    add     al, 0x20              ; al = 0x20 + tx_tail*4 (TSADx offset)
    call    rtl8139_wr_d
    pop     ebx
    pop     ecx                   ; ecx = tx_tail * 4

    ; Write SIZE to TSDx (32-bit write triggers TX DMA; bits 0-12 = size)
    movzx   eax, word [net_tx_len] ; eax = size
    mov     dx, word [nic_base]
    add     dx, cx                ; dx = nic_base + tx_tail*4
    add     dx, 0x10              ; dx = nic_base + 0x10 + tx_tail*4 = TSDx port
    out     dx, eax               ; 32-bit write: size triggers TX DMA

    ; Debug: read TSDx back (TOK=bit15 set synchronously by QEMU on success)
    push    ecx                   ; save tx_tail * 4
    push    ebx
    mov     eax, ecx
    add     al, 0x10              ; al = 0x10 + tx_tail*4 (TSDx offset)
    call    rtl8139_rd_d          ; ebx = TSDx value
    mov     eax, ebx
    push    ebx
    dbg_puts "TSDxpost=", 0
    dbg_hex32
    pop     ebx
    pop     ebx
    pop     ecx                   ; restore tx_tail * 4

    ; Advance tx_tail = (tx_tail + 1) & 3
    mov     eax, ecx
    shr     eax, 2                ; eax = old tx_tail
    inc     eax
    and     eax, 3
    mov     [tx_tail], al

    mov     byte [net_send_state], 1
    jmp     .es_d
.es_no:
    mov     byte [net_send_state], 2
.es_d:
    pop     eax
    pop     ebx
    pop     ecx
    pop     edx
    pop     edi
    ret

; ============================================================================
; ip_cksum — ones-complement checksum
;   IN:  esi = buffer, ecx = word count
;   OUT: ax = checksum
; ============================================================================
ip_cksum:
    push    edi
    push    ebx
    xor     ebx, ebx
.ck_l:
    test    ecx, ecx
    jz      .ck_d
    lodsw
    movzx   eax, ax
    add     ebx, eax
    dec     ecx
    jmp     .ck_l
.ck_d:
    mov     ax, bx
    shr     ebx, 16
    add     ax, bx
    adc     ax, 0
    not     ax
    pop     ebx
    pop     edi
    ret

; ============================================================================
; ip_rx — receive IP packet at nic_rx_data+14
;   Verifies checksum, dispatches by protocol
; ============================================================================
ip_rx:
    push    edi
    push    edx
    push    ecx
    push    ebx
    push    eax
    mov     edi, nic_rx_data
    add     edi, 14
    mov     al, [edi]
    and     al, 0x0F
    cmp     al, 5
    jne     .ir_d
    mov     esi, edi
    mov     al, [edi]
    and     al, 0x0F
    movzx   eax, al
    shl     eax, 2
    mov     cx, ax
    shr     cx, 1
    call    ip_cksum
    test    ax, ax
    jnz     .ir_ckfail
    mov     bl, [edi+9]          ; protocol byte from IP header (offset 9)
    cmp     bl, 1
    je      .ir_icmp
    cmp     bl, 6
    je      .ir_tcp
    cmp     bl, 17
    je      .ir_udp
    jmp     .ir_d
.ir_icmp:
    call    icmp_rx
    jmp     .ir_d
.ir_tcp:
    call    tcp_rx
    jmp     .ir_d
.ir_udp:
    call    udp_rx
    jmp     .ir_d
.ir_ckfail:
.ir_d:
    pop     eax
    pop     ebx
    pop     ecx
    pop     edx
    pop     edi
    ret

; ============================================================================
; icmp_rx — respond to ICMP echo request (type 8)
; ============================================================================
icmp_rx:
    push    edi
    push    esi
    push    edx
    push    ecx
    push    ebx
    push    eax
    mov     edi, nic_rx_data + 34
    cmp     byte [edi], 8
    jne     .ic_d
    ; Build Ethernet header at net_tx_buf
    mov     edi, net_tx_buf
    mov     esi, nic_rx_data + 6
    mov     cx, 6
    rep     movsb
    mov     eax, [nic_mac_lo]
    mov     [edi], eax
    mov     ax, [nic_mac_hi]
    mov     [edi+4], ax
    mov     word [edi+12], 0x0008
    ; IP header
    mov     edi, net_tx_buf + 14
    mov     byte [edi+0], 0x45
    mov     byte [edi+1], 0
    mov     word [edi+2], 28
    mov     word [edi+4], 0
    mov     word [edi+6], 0x4000
    mov     byte [edi+8], 64
    mov     byte [edi+9], 1
    mov     word [edi+10], 0
    mov     dword [edi+12], 0x0A02020F
    mov     esi, nic_rx_data + 26
    mov     eax, [esi]
    mov     [edi+16], eax
    ; ICMP reply header
    mov     edi, net_tx_buf + 34
    mov     byte [edi+0], 0
    mov     byte [edi+1], 0
    mov     word [edi+2], 0
    mov     esi, nic_rx_data + 36
    mov     ax, [esi]
    mov     [edi+4], ax
    mov     ax, [esi+2]
    mov     [edi+6], ax
    ; ICMP checksum
    mov     esi, net_tx_buf + 34
    mov     cx, 4
    call    ip_cksum
    mov     [net_tx_buf + 36], ax
    ; IP checksum
    mov     esi, net_tx_buf + 14
    mov     cx, 10
    call    ip_cksum
    mov     [net_tx_buf + 24], ax
    mov     word [net_tx_len], 42
    call    eth_send
.ic_d:
    pop     eax
    pop     ebx
    pop     ecx
    pop     edx
    pop     esi
    pop     edi
    ret

; ============================================================================
; udp_rx — receive UDP datagram
;   Copies payload into udp_rx_buf (capped at UDP_RX_CAP bytes) and sets
;   udp_rx_state=1.  Payload length is derived from the wire BE length field.
; ============================================================================
udp_rx:
    push    edi
    push    esi
    push    edx
    push    ecx
    push    ebx
    push    eax
    mov     edi, nic_rx_data + 34
    mov     ax, [edi+0]
    mov     [udp_sport], ax         ; raw wire bytes (consumers re-swap if needed)
    mov     ax, [edi+2]
    mov     [udp_dport], ax
    ; UDP length field is big-endian on wire → swap before using
    mov     ax, [edi+4]
    xchg    al, ah
    sub     ax, 8                   ; payload length (host order); CF set if < 8
    jc      .ud_empty
    jz      .ud_empty
    add     edi, 8
    mov     esi, edi
    mov     edi, udp_rx_buf
    ; cap copy so a malformed/huge datagram cannot overflow into BSS
    cmp     ax, UDP_RX_CAP
    jbe     .ud_cap
    mov     ax, UDP_RX_CAP
.ud_cap:
    mov     [udp_len], ax
    mov     cx, ax
    rep     movsb
    jmp     .ud_set
.ud_empty:
    mov     word [udp_len], 0
.ud_set:
    mov     byte [udp_rx_state], 1
    ; one-shot debug: log first 4 arriving UDP datagrams (sport/dport/len)
    cmp     byte [udp_rx_dbg_cnt], 4
    jae     .ud_nodbg
    inc     byte [udp_rx_dbg_cnt]
    push    eax
    dbg_puts "[A4X] udp_rx pkt sport=", 0
    movzx   eax, word [udp_sport]
    call    dbg_print_eax_hex
    dbg_puts " dport=", 0
    movzx   eax, word [udp_dport]
    call    dbg_print_eax_hex
    dbg_puts " plen=", 0
    movzx   eax, word [udp_len]
    call    dbg_print_eax_dec
    dbg_nl
    pop     eax
.ud_nodbg:
    pop     eax
    pop     ebx
    pop     ecx
    pop     edx
    pop     esi
    pop     edi
    ret

; ============================================================================
; udp_send — send UDP datagram
;   IN:  udp_sport/udp_dport (memory words hold wire BE bytes),
;        udp_len = payload length (host order), udp_tx_buf = payload,
;        udp_dst_ip = destination IP (memory bytes = network order)
;        L2 dst MAC = arp_reply_mac (gateway, resolved by net_download's ARP)
; ============================================================================
udp_send:
    push    edi
    push    esi
    push    edx
    push    ecx
    push    ebx
    push    eax
    ; Ethernet: dst MAC = gateway MAC (same MAC serves 10.0.2.2/10.0.2.3)
    mov     edi, net_tx_buf
    mov     eax, [arp_reply_mac]
    mov     [edi+0], eax
    mov     ax, [arp_reply_mac+4]
    mov     [edi+4], ax
    ; src MAC = our MAC
    mov     eax, [nic_mac_lo]
    mov     [edi+6], eax
    mov     ax, [nic_mac_hi]
    mov     [edi+10], ax
    mov     word [edi+12], 0x0008
    ; IP header
    mov     edi, net_tx_buf + 14
    mov     byte [edi+0], 0x45
    mov     byte [edi+1], 0
    mov     ax, [udp_len]
    add     ax, 28                       ; total IP length (host order)
    xchg    al, ah                       ; → big-endian wire order
    mov     word [edi+2], ax
    mov     word [edi+4], 0              ; identification
    mov     word [edi+6], 0x0040         ; flags=DF (BE 0x4000 → LE 0x0040)
    mov     byte [edi+8], 64             ; TTL
    mov     byte [edi+9], 17             ; protocol = UDP
    mov     word [edi+10], 0             ; checksum (to be filled)
    mov     dword [edi+12], 0x0F02000A   ; src IP 10.0.2.15
    mov     eax, [udp_dst_ip]
    mov     [edi+16], eax                ; dst IP (network-order bytes)
    ; IP checksum (10 words = 20 bytes)
    mov     esi, edi
    mov     cx, 10
    call    ip_cksum
    mov     [edi+10], ax
    ; UDP header
    add     edi, 20
    mov     ax, [udp_sport]
    mov     [edi+0], ax                  ; src port (already wire BE)
    mov     ax, [udp_dport]
    mov     [edi+2], ax                  ; dst port (already wire BE)
    mov     ax, [udp_len]
    add     ax, 8                        ; UDP length incl. header (host order)
    xchg    al, ah                       ; → big-endian wire order
    mov     [edi+4], ax
    mov     word [edi+6], 0              ; checksum 0 (allowed for IPv4)
    ; Copy payload
    add     edi, 8
    mov     esi, udp_tx_buf
    mov     ax, [udp_len]
    test    ax, ax
    jz      .us_d
    mov     cx, ax
    rep     movsb
.us_d:
    mov     ax, [udp_len]
    add     ax, 42
    mov     [net_tx_len], ax
    call    eth_send
    pop     eax
    pop     ebx
    pop     ecx
    pop     edx
    pop     esi
    pop     edi
    ret

; ============================================================================
; tcp_check — check for SYN-ACK or data reply (RTL8139)
;   Sets tcp_state=2 on SYN-ACK, tcp_state=3 on data received
;   Main work is done by eth_rx -> ip_rx -> tcp_rx in the main loop
;   P1.5 extension:
;     - tcp_state=1 (SYN_SENT)     → 300-tick timeout, retx up to 3 times
;     - tcp_state=2 (ESTABLISHED)  → after we sent HTTP DATA, wait 450 ticks
;       for server ACK+payload; if timeout, retx saved GET frame snapshot
;     - tcp_fin_state=1 (FIN_SENT) → 200 ticks, retx FIN+ACK once, then close
;     - tcp_retries >= 3 in any state → abort session (tcp_state=0) so
;       net_download can route to fallback.
tcp_check:
    push    edi
    push    edx
    push    ecx
    push    ebx
    push    eax
    cmp     byte [nic_type], 1
    jne     tcp_chk_d
    ; ---- Select timeout threshold by state ----
    mov     eax, [vtd_t]
    mov     ebx, [tcp_timeout]
    sub     eax, ebx                    ; eax = elapsed ticks
    mov     ecx, 300                    ; default threshold = SYN timeout
    mov     dl, byte [tcp_state]
    cmp     dl, 2                       ; ESTABLISHED → longer (HTTP server response)
    jne     .tc_thr_set
    cmp     byte [tcp_fin_state], 1     ; unless FIN_SENT (then short 200)
    je      .tc_thr_fin
    mov     ecx, 450
    jmp     .tc_thr_set
.tc_thr_fin:
    mov     ecx, 200
.tc_thr_set:
    cmp     dl, 0                       ; CLOSED? nothing to do
    je      tcp_chk_d
    cmp     eax, ecx
    jl      tcp_chk_no_timeout             ; still within window
    ; ---- Timeout fired ----
    ; Allow up to 3 retransmissions (retries ∈ 0..2 → 3 attempts total).
    movzx   ebx, byte [tcp_retries]
    cmp     ebx, 3
    jge     .tcp_timeout_abort
    inc     byte [tcp_retries]
    call    tcp_retransmit_last
    ; Reset timeout for next wait window
    mov     eax, [vtd_t]
    mov     [tcp_timeout], eax
    jmp     tcp_chk_d
.tcp_timeout_abort:
    cmp     byte [tcp_fin_state], 1
    je      tcp_chk_fin_timeout            ; FIN timed out → just close quietly
    dbg_puts "[A4X] TCP ABORT: retries exhausted (state=", 0
    movzx   eax, byte [tcp_state]
    call    dbg_hex32
    dbg_puts ")", 13, 10, 0
    ; Abort session: net_download treats tcp_state=0 as a TCP failure and
    ; skips payload parsing, so no false-positive PE detection occurs.
    mov     byte [tcp_state], 0
    mov     byte [tcp_fin_state], 3
    jmp     tcp_chk_d
tcp_chk_fin_timeout:
    dbg_puts "[A4X] TCP: FIN-ACK timeout, closing session", 13, 10, 0
    mov     byte [tcp_fin_state], 3
    mov     byte [tcp_state], 0
    jmp     tcp_chk_d
tcp_chk_no_timeout:
    ; For state=1 (SYN_SENT) also check legacy TX-TOK bit for debug logging
    cmp     byte [tcp_state], 1
    jne     tcp_chk_d                      ; skip TOK read for non-SYN states
    ; Check TX done: read TSD0 byte 0x11, test TOK (bit 15 = bit7 of byte 0x11)
    mov     al, 0x11
    call    rtl8139_rd
    test    al, 0x80
    jnz     tcp_chk_d                      ; TOK=1, done, wait SYN-ACK
.tcp_pending:
    ; Only log once per session to avoid flood
    cmp     byte [tcp_tx_pending_logged], 1
    je      tcp_chk_d
    mov     byte [tcp_tx_pending_logged], 1
    dbg_puts "[A4X] tcp_check TX pending (TOK=0)", 13, 10, 0
tcp_chk_d:
    pop     eax
    pop     ebx
    pop     ecx
    pop     edx
    pop     edi
    ret

; ============================================================================
; tcp_recv_check — check RX ring for incoming TCP data
;   IN:  edi = nic_rx_data (Ethernet frame)
;   OUT: sets tcp_rx_len and copies payload to tcp_rx_buf
; ============================================================================
tcp_recv_check:
    push    edi
    push    edx
    push    ecx
    push    ebx
    push    eax
    cmp     byte [nic_type], 1
    jne     .trc_d
    cmp     byte [tcp_state], 2
    jne     .trc_d
    ; Read RX data
    mov     edi, nic_rx_data
    add     edi, 14+20+20  ; skip eth+ip+tcp headers
    ; Get payload length from IP total length - 40
    mov     ax, [nic_rx_data+14+2]
    sub     ax, 40
    cmp     ax, 32
    jg      .trc_d
    mov     [tcp_rx_len], ax
    ; Copy payload to tcp_rx_buf
    mov     esi, edi
    mov     edi, tcp_rx_buf
    mov     ecx, [tcp_rx_len]
    rep     movsb
    mov     byte [tcp_rx_state], 1
.trc_d:
    pop     eax
    pop     ebx
    pop     ecx
    pop     edx
    pop     edi
    ret

; ============================================================================
; dns_resolve — UDP DNS A-record query
;   IN:  esi = domain name string (null-terminated)
;   OUT: builds + sends query via udp_send; dns_state=1 (querying), 3 (fail)
;        On response (polled via dns_check): dns_ip[4] + dns_state=2
; ============================================================================
dns_resolve:
    push    edi
    push    edx
    push    ecx
    push    ebx
    push    esi
    push    eax
    mov     byte [dns_state], 1
    ; Build DNS query packet in udp_tx_buf
    mov     edi, udp_tx_buf
    mov     word [edi+0], 0xA5A5    ; transaction ID (wire bytes A5 A5)
    mov     word [edi+2], 0x0100    ; flags: standard query + RD (wire 00 01)
    mov     word [edi+4], 0x0100    ; qdcount = 1 (wire 01 00)
    mov     word [edi+6], 0         ; ancount
    mov     word [edi+8], 0         ; nscount
    mov     word [edi+10], 0        ; arcount
    add     edi, 12
    ; Encode QNAME as labels: <len><chars>... <len><chars>... 00
.dns_enc:
    xor     ebx, ebx                ; current label length
.dns_lcount:
    mov     al, [esi+ebx]
    test    al, al
    jz      .dns_lend
    cmp     al, '.'
    je      .dns_lend
    inc     ebx
    cmp     ebx, 63
    ja      .dns_fail               ; label too long
    jmp     .dns_lcount
.dns_lend:
    test    ebx, ebx
    jnz     .dns_havelbl
    cmp     byte [esi], 0
    je      .dns_qdone              ; end of name
    jmp     .dns_fail               ; empty label (".." or leading '.') → malformed
.dns_havelbl:
    mov     [edi], bl               ; write label length byte
    inc     edi
    mov     ecx, ebx
.dns_cp:
    mov     al, [esi]
    mov     [edi], al
    inc     edi
    inc     esi
    dec     ecx
    jnz     .dns_cp
    cmp     byte [esi], '.'
    jne     .dns_qdone              ; NUL → name complete
    inc     esi                     ; skip '.'
    jmp     .dns_enc
.dns_qdone:
    mov     byte [edi], 0           ; terminating zero label
    inc     edi
    ; qtype = 1 (A), qclass = 1 (IN) — wire big-endian → memory LE 0x0100
    mov     word [edi+0], 0x0100
    mov     word [edi+2], 0x0100
    add     edi, 4
    ; udp_len = query payload size (host order; udp_send swaps to wire)
    mov     eax, edi
    sub     eax, udp_tx_buf
    cmp     eax, 86                  ; 42 + payload must fit net_tx_buf (128 bytes)
    ja      .dns_fail
    mov     [udp_len], ax
    ; UDP ports: memory words must hold wire BE bytes (value = bswap16(port))
    mov     word [udp_sport], 0xA00F    ; src port 4000 (wire 0F A0)
    mov     word [udp_dport], 0x3500    ; dst port 53   (wire 00 35)
    ; DNS server = real public resolver 223.5.5.5 (AliDNS), NAT-forwarded by
    ; QEMU SLiRP as plain UDP.  (SLiRP's built-in 10.0.2.3 → host-resolver
    ; forwarding silently drops queries on this Windows setup; querying a
    ; public DNS directly exercises the normal NAT path and matches the
    ; "real internet" semantics.)
    mov     eax, [dns_server_ip]
    mov     [udp_dst_ip], eax
    call    udp_send
    dbg_puts "[A4X] DNS: query sent (udp 4000->53)", 13, 10, 0
    ; Mark timeout base (state 2 handler aborts after ~300 ticks)
    mov     eax, [vtd_t]
    mov     [dns_timeout], eax
    jmp     .dns_d
.dns_fail:
    mov     byte [dns_state], 3
.dns_d:
    pop     eax
    pop     esi
    pop     ebx
    pop     ecx
    pop     edx
    pop     edi
    ret

; ============================================================================
; dns_check — parse DNS response in udp_rx_buf
;   Sets dns_state=2 (resolved, dns_ip[4] = network-order IPv4) or 3 (fail)
; ============================================================================
dns_check:
    push    edi
    push    edx
    push    ecx
    push    ebx
    push    eax
    cmp     byte [udp_rx_state], 1
    jne     .dc_d
    mov     byte [udp_rx_state], 0  ; consume packet (no re-parse of stale data)
    ; transaction id must match our query 0xA5A5 (wire bytes A5 A5)
    cmp     word [udp_rx_buf+0], 0xA5A5
    je      .dc_idok
    dbg_puts "[A4X] dns_check: ID mismatch", 13, 10, 0
    jmp     .dc_d
.dc_idok:
    ; QR bit must be set (response) — byte[2] bit 7
    test    byte [udp_rx_buf+2], 0x80
    jz      .dc_d
    ; RCODE must be 0 — byte[3] low 4 bits
    test    byte [udp_rx_buf+3], 0x0F
    jnz     .dc_fail
    ; ANCOUNT >= 1 (wire BE word at +6, nonzero check is order-agnostic)
    cmp     word [udp_rx_buf+6], 0
    je      .dc_fail
    ; --- skip the single question entry: walk QNAME labels ---
    mov     edi, udp_rx_buf + 12
.dc_skipq:
    cmp     edi, udp_rx_buf + UDP_RX_CAP
    jae     .dc_fail                ; malformed: ran past response buffer
    movzx   eax, byte [edi]
    cmp     al, 64                  ; 64..191 = invalid label len
    jae     .dc_fail
    test    eax, eax
    jz      .dc_qdone
    lea     edi, [edi+eax+1]
    jmp     .dc_skipq
.dc_qdone:
    add     edi, 5                  ; NUL label + qtype(2) + qclass(2)
    ; ancount low byte (wire BE at +6): iterate answer RRs until an A record
    movzx   ebx, byte [udp_rx_buf+7]
    test    ebx, ebx
    jz      .dc_fail
.dc_ans_next:
    ; --- answer RR name: compressed pointer (>=0xC0) or inline labels ---
    movzx   eax, byte [edi]
.dc_aname_loop:
    cmp     edi, udp_rx_buf + UDP_RX_CAP
    jae     .dc_fail                ; malformed: ran past response buffer
    cmp     al, 0xC0
    jae     .dc_aname_ptr
    cmp     al, 64
    jae     .dc_fail
    test    eax, eax
    jz      .dc_aname_zero
    lea     edi, [edi+eax+1]
    movzx   eax, byte [edi]
    jmp     .dc_aname_loop
.dc_aname_zero:
    inc     edi
    jmp     .dc_ahdr
.dc_aname_ptr:
    add     edi, 2                  ; skip 2-byte compression pointer
.dc_ahdr:
    ; RR header: TYPE(2) CLASS(2) TTL(4) RDLEN(2), then RDATA
    cmp     edi, udp_rx_buf + UDP_RX_CAP - 16
    jae     .dc_fail                ; not enough room for a full RR header
    cmp     word [edi+0], 0x0100    ; TYPE = A (wire 01 00 → LE 0x0100)
    jne     .dc_ans_skip
    mov     ax, [edi+8]
    xchg    al, ah
    cmp     ax, 4                   ; RDLEN must be 4 (IPv4)
    jne     .dc_fail
    ; RDATA: 4 bytes, network order in memory — matches tcp_dst_ip layout
    mov     eax, [edi+10]
    mov     [dns_ip], eax
    mov     byte [dns_state], 2
    jmp     .dc_d
.dc_ans_skip:
    ; non-A RR (CNAME etc.): advance past fixed header (10) + RDLENGTH bytes
    mov     ax, [edi+8]
    xchg    al, ah
    add     ax, 10
    movzx   eax, ax
    add     edi, eax
    dec     ebx
    jnz     .dc_ans_next
    jmp     .dc_fail                ; exhausted all answers without an A record
.dc_fail:
    push    eax
    dbg_puts "[A4X] dns_check: parse FAIL rcode=", 0
    movzx   eax, byte [udp_rx_buf+3]
    and     eax, 0x0F
    call    dbg_print_eax_dec
    dbg_nl
    pop     eax
    mov     byte [dns_state], 3
.dc_d:
    pop     eax
    pop     ebx
    pop     ecx
    pop     edx
    pop     edi
    ret

; ============================================================================
; dl_parse_url — parse an http:// URL into host / optional port / path
;   IN:  esi = null-terminated URL string (http://host[:port]/path...)
;   OUT: dl_hostname = ptr into url string after "http://" (host start)
;        dl_hostlen  = byte length of host segment (before :port or /)
;        dl_dst_port = host-order short (0=default port 80, else numeric port)
;        eax = LE dword IP (if host was "a.b.c.d" dotted quad); 0 otherwise (need DNS)
; ============================================================================
dl_parse_url:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi
    ; reset outputs
    mov     dword [dl_hostname], 0
    mov     dword [dl_hostlen], 0
    mov     word  [dl_dst_port], 0
    xor     eax, eax
    ; skip leading "http://"
    mov     eax, [esi]
    cmp     eax, "http"
    jne     .pu_noscheme
    add     esi, 4
    cmp     word [esi], ":/"       ; "://..." starts with ':' '/'
    jne     .pu_noscheme
    add     esi, 3                 ; skip "://"
    jmp     .pu_host_start
.pu_noscheme:
.pu_host_start:
    mov     [dl_hostname], esi                     ; host begins here
    xor     ebx, ebx                                ; host length
    xor     eax, eax
.pu_hscan:
    lodsb
    test    al, al
    jz      .pu_hscan_end
    cmp     al, ':'
    je      .pu_have_port
    cmp     al, '/'
    je      .pu_hscan_end
    inc     ebx
    jmp     .pu_hscan
.pu_have_port:
    ; parse 1..5 decimal digits as port (up to 65535)
    xor     eax, eax
    xor     ecx, ecx
.pu_pdigit:
    lodsb
    test    al, al
    jz      .pu_pdone
    cmp     al, '/'
    je      .pu_pdone
    cmp     al, '0'
    jb      .pu_bad_port
    cmp     al, '9'
    ja      .pu_bad_port
    sub     al, '0'
    imul    ecx, 10
    add     ecx, eax
    cmp     ecx, 65535
    ja      .pu_bad_port
    jmp     .pu_pdigit
.pu_bad_port:
    xor     ecx, ecx
.pu_pdone:
    mov     [dl_dst_port], cx
    jmp     .pu_host_done_set
.pu_hscan_end:
    dec     esi
.pu_host_done_set:
    mov     [dl_hostlen], ebx
    ; --- dotted-quad IP parse ---
    mov     esi, [dl_hostname]
    mov     edi, ebx                                ; guard = host length
    push    ebp
    xor     ebp, ebp                                ; accumulator (BE)
    xor     ecx, ecx                                ; dot count (0..3 means 4 octets)
    xor     edx, edx                                ; current octet
    xor     ebx, ebx                                ; digits in octet
.pu_oct_loop:
    test    edi, edi
    jz      .pu_oct_done
    movzx   eax, byte [esi]                         ; zero-extended char (upper bits clean)
    cmp     al, '.'
    je      .pu_oct_dot
    cmp     al, '0'
    jb      .pu_ip_invalid
    cmp     al, '9'
    ja      .pu_ip_invalid
    sub     al, '0'
    imul    edx, 10
    add     edx, eax                                ; eax = 0..9 only
    cmp     edx, 255
    ja      .pu_ip_invalid
    inc     ebx
    jmp     .pu_oct_next
.pu_oct_dot:
    test    ebx, ebx
    jz      .pu_ip_invalid
    cmp     ecx, 3
    jae     .pu_ip_invalid
    shl     ebp, 8
    or      ebp, edx                                ; acc = (acc<<8) | octet (BE build-up)
    xor     edx, edx
    xor     ebx, ebx
    inc     ecx
.pu_oct_next:
    inc     esi
    dec     edi
    jmp     .pu_oct_loop
.pu_oct_done:
    test    ebx, ebx
    jz      .pu_ip_invalid
    cmp     ecx, 3
    jne     .pu_ip_invalid
    shl     ebp, 8
    or      ebp, edx                                ; ebp = BE dword (10.0.2.2 → 0x0A000202)
    mov     eax, ebp
    bswap   eax                                     ; eax = LE dword 0x0202000A ✓ matches tcp_dst_ip format
    pop     ebp
    jmp     .pu_d
.pu_ip_invalid:
    xor     eax, eax
    pop     ebp
.pu_d:
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret


; ============================================================================
; http_get — build HTTP GET request buffer from dl_url_str
;   IN:  esi = URL string (http://host[:port]/path, host may be dotted-quad
;        or DNS name; parsed here via dl_parse_url)
;   OUT: http_buf contains request, http_len = length.  Emits:
;        "GET <path> HTTP/1.1\r\nHost: <host>[:port]\r\nConnection: close\r\n\r\n"
; ============================================================================
http_get:
    push    edi
    push    esi
    push    edx
    push    ecx
    push    ebx
    push    eax
    call    dl_parse_url               ; fills dl_hostname/dl_hostlen/dl_dst_port
    mov     edi, http_buf
    mov     dword [edi+0], "GET "
    add     edi, 4
    ; path = dl_hostname + dl_hostlen, skip optional ":<digits>" port suffix
    mov     esi, [dl_hostname]
    add     esi, [dl_hostlen]
    cmp     byte [esi], ':'
    jne     .hg_path
.hg_skipport:
    inc     esi
    mov     al, [esi]
    cmp     al, '0'
    jb      .hg_path
    cmp     al, '9'
    jbe     .hg_skipport
.hg_path:
    ; ensure path starts with '/' (URL without path → "/")
    cmp     byte [esi], '/'
    je      .hg_copy
    mov     byte [edi], '/'
    inc     edi
.hg_copy:
    lodsb
    test    al, al
    jz      .hg_pdone
    mov     [edi], al
    inc     edi
    jmp     .hg_copy
.hg_pdone:
    ; " HTTP/1.1\r\nHost: "
    mov     dword [edi+0], " HTT"
    mov     dword [edi+4], "P/1."
    mov     byte  [edi+8], '1'
    mov     word  [edi+9], 0x0A0D      ; \r\n
    add     edi, 11
    mov     dword [edi+0], "Host"
    mov     byte  [edi+4], ':'
    mov     byte  [edi+5], ' '
    add     edi, 6
    ; copy host segment verbatim
    mov     esi, [dl_hostname]
    mov     ecx, [dl_hostlen]
    rep     movsb
    ; append ":<port>" when URL specified an explicit port
    mov     ax, [dl_dst_port]
    test    ax, ax
    jz      .hg_hdone
    mov     byte [edi], ':'
    inc     edi
    movzx   eax, ax                    ; host-order port
    call    .hg_putdec
.hg_hdone:
    mov     word [edi], 0x0A0D         ; \r\n
    add     edi, 2
    ; "Connection: close\r\n\r\n"
    mov     dword [edi+0], "Conn"
    mov     dword [edi+4], "ecti"
    mov     dword [edi+8], "on: "
    mov     dword [edi+12], "clos"
    mov     byte  [edi+16], 'e'
    mov     word  [edi+17], 0x0A0D
    mov     word  [edi+19], 0x0A0D
    add     edi, 21
    ; http_len = edi - http_buf (explicit 32-bit math, WORD store — a dword
    ; store here would clobber the byte at http_len+1)
    mov     eax, edi
    sub     eax, http_buf
    mov     [http_len], ax
    pop     eax
    pop     ebx
    pop     ecx
    pop     edx
    pop     esi
    pop     edi
    ret
; .hg_putdec — write eax (unsigned) as decimal digits at [edi], advance edi
.hg_putdec:
    push    ebx
    push    edx
    push    ecx
    mov     ebx, 10
    xor     ecx, ecx
.hg_pd1:
    xor     edx, edx
    div     ebx
    push    edx
    inc     ecx
    test    eax, eax
    jnz     .hg_pd1
.hg_pd2:
    pop     eax
    add     al, '0'
    mov     [edi], al
    inc     edi
    dec     ecx
    jnz     .hg_pd2
    pop     ecx
    pop     edx
    pop     ebx
    ret

; ============================================================================
; http_parse — parse HTTP response, extract body
;   IN:  http_buf contains response
;   OUT: sets http_body_len, http_body points to first non-header byte
; ============================================================================
http_parse:
    push    edi
    push    edx
    push    ecx
    push    ebx
    push    eax
    mov     edi, http_buf
    movzx   ecx, word [http_len]
    cmp     ecx, 4
    jl      .http_d
.http_find:
    cmp     ecx, 4
    jl      .http_d
    cmp     dword [edi], 0x0A0D0A0D    ; \r\n\r\n in LE (bytes 0D 0A 0D 0A)
    je      .http_found
    inc     edi
    dec     ecx
    jmp     .http_find
.http_found:
    add     edi, 4
    mov     [http_body], edi
    ; body_len = http_len - (edi - http_buf)
    mov     eax, edi
    sub     eax, http_buf
    movzx   edx, word [http_len]
    sub     edx, eax
    mov     [http_body_len], dx
.http_d:
    pop     eax
    pop     ebx
    pop     ecx
    pop     edx
    pop     edi
    ret

; ============================================================================
; net_test_inject — NET_TEST only: inject canned HTTP response into dl_code
;   Bypasses ARP/DNS/TCP/HTTP. Simulates a real download by copying the
;   test bytecode (0xA4 magic + program) into dl_code and setting dl_valid.
; ============================================================================
%ifdef NET_TEST
net_test_inject:
    push    esi
    push    edi
    push    ecx
    push    eax
    ; Simulate http_parse: set http_body to point past headers
    mov     dword [http_body], test_bc_body
    mov     eax, test_bc_body_len
    mov     [http_body_len], ax
    ; Phase B copy: body[0] must be BC_MAGIC, copy body[1..] to dl_code
    mov     byte [dl_valid], 0
    mov     esi, test_bc_body
    mov     al, [esi]
    cmp     al, BC_MAGIC
    jne     .nti_d
    inc     esi                        ; skip magic
    mov     ecx, test_bc_body_len - 1  ; payload without magic
    cmp     ecx, DL_CODE_SZ
    jle     .nti_cap
    mov     ecx, DL_CODE_SZ
.nti_cap:
    mov     edi, dl_code
    push    ecx
    rep     movsb
    pop     ecx
    ; Zero-fill remainder
    mov     eax, DL_CODE_SZ
    sub     eax, ecx
    mov     ecx, eax
    xor     al, al
    rep     stosb
    mov     byte [dl_valid], 1
    dbg_puts "[A4X] NET_TEST: injected downloaded bytecode (dl_valid=1)", 13, 10, 0
.nti_d:
    pop     eax
    pop     ecx
    pop     edi
    pop     esi
    ret
%endif

; ============================================================================
; net_download — orchestrate ARP→(DNS optional)→TCP→HTTP→download flow
;   URL: dl_url_str (http://host[:port]/path, host may be dotted-quad IP
;        or real DNS hostname; when host is an IP DNS is skipped)
;   Called from main_loop when ins_state==1
; ============================================================================
net_download:
    push    edi
    push    edx
    push    ecx
    push    ebx
    push    eax
    ; ----- Print current state (scripted tracking, once per state entry) -----
    mov     al, [net_dl_state]
    cmp     al, [nd_last_logged_state]
    je      .nd_skip_state_print
    mov     [nd_last_logged_state], al
    cmp     al, 0
    je      .nd_log_s0
    cmp     al, 1
    je      .nd_log_s1
    cmp     al, 2
    je      .nd_log_s2
    cmp     al, 3
    je      .nd_log_s3
    jmp     .nd_skip_state_print
.nd_log_s0:
    dbg_puts "[A4X] net_dl state=0 (url parse + ARP gw)", 13, 10, 0
    jmp     .nd_skip_state_print
.nd_log_s1:
    dbg_puts "[A4X] net_dl state=1 (ARP wait)", 13, 10, 0
    jmp     .nd_skip_state_print
.nd_log_s2:
    dbg_puts "[A4X] net_dl state=2 (DNS resolve)", 13, 10, 0
    jmp     .nd_skip_state_print
.nd_log_s3:
    dbg_puts "[A4X] net_dl state=3 (TCP connect)", 13, 10, 0
.nd_skip_state_print:
    cmp     byte [net_dl_state], 0
    je      .nd_start
    cmp     byte [net_dl_state], 1
    je      .nd_arp
    cmp     byte [net_dl_state], 2
    je      .nd_dns
    cmp     byte [net_dl_state], 3
    je      .nd_tcp
    cmp     byte [net_dl_state], 4
    je      .nd_http
    cmp     byte [net_dl_state], 5
    je      .nd_done
    jmp     .nd_d
.nd_start:
    ; Step 1: parse dl_url_str to extract host/port and try dotted-quad IP
    mov     esi, dl_url_str
    call    dl_parse_url                           ; eax=0(need DNS) or LE dword IP (literal)
    push    eax                                    ; [A] save parsed IP (0 or dword)
    ; Step 2: send ARP for gateway 10.0.2.2 (we always route through SLiRP gateway)
    ;         gateway ARP is required regardless of target IP because any packet
    ;         to non-local subnet is next-hop-forwarded to 10.0.2.2 MAC by SLiRP.
    mov     byte [net_dl_state], 1
    dbg_puts "[A4X] ARP: sending request for gw 10.0.2.2", 13, 10, 0
    call    arp_send
    pop     eax                                    ; [A] restore parsed IP (0 or literal)
    ; store in scratch so .nd_arp can read it
    mov     [nd_parsed_ip], eax
    push    eax                     ; dbg_puts clobbers al via lodsb
    dbg_puts "[A4X] dl: parsed_ip dword=", 0
    pop     eax
    call    dbg_print_eax_hex
    dbg_nl
    jmp     .nd_d
.nd_arp:
    cmp     byte [arp_state], 4
    jne     .nd_d
    ; ARP for gateway done. Decide: DNS (nd_parsed_ip=0) vs direct TCP (literal IP).
    mov     eax, [nd_parsed_ip]
    test    eax, eax
    jnz     .nd_have_ip                            ; literal dotted-quad IP, skip DNS
    ; --- DNS path: need to resolve hostname ---
    ; Copy dl_hostname (up to dl_hostlen bytes) into a NUL scratch buffer so
    ; dns_resolve esi=NUL-terminated string works.
    cmp     dword [dl_hostlen], 64
    ja      .nd_dns_fail                           ; hostname too long → treat as resolve failure
    push    esi
    push    edi
    push    ecx
    mov     esi, [dl_hostname]
    mov     edi, nd_host_scratch
    mov     ecx, [dl_hostlen]
    rep     movsb
    mov     byte [edi], 0                           ; NUL terminate
    pop     ecx
    pop     edi
    pop     esi
    dbg_puts "[A4X] dl: resolving hostname=", 0
    push    esi
    mov     esi, nd_host_scratch
.nd_host_out:
    lodsb
    test    al, al
    jz      .nd_host_end
    out     0xE9, al
    jmp     .nd_host_out
.nd_host_end:
    pop     esi
    dbg_nl
    ; DNS resolver = public IP (dns_server_ip, default 223.5.5.5), sent as a
    ; plain UDP datagram that QEMU SLiRP NATs out to the real internet.  The
    ; gateway MAC (arp_reply_mac, resolved for 10.0.2.2) is the L2 next hop.
    mov     byte [dns_state], 0
    mov     byte [udp_rx_state], 0
    mov     esi, nd_host_scratch
    call    dns_resolve
    mov     byte [net_dl_state], 2
    jmp     .nd_d
.nd_have_ip:
    ; Literal IP: build TCP params directly.
    ; tcp_dst_ip = nd_parsed_ip (already LE dword)
    mov     [tcp_dst_ip], eax
    ; tcp_dport: if dl_dst_port != 0 use it (host-order short parsed from the
    ; URL, e.g. 8080); else default to 80.
    mov     ax, [dl_dst_port]
    test    ax, ax
    jnz     .nd_port_set
    mov     ax, 80
.nd_port_set:
    ; tcp_connect copies the tcp_dport word verbatim into the TCP header, so
    ; the memory word must already hold wire BE bytes: value = bswap16(port)
    ; (e.g. 8080=0x1F90 host-order → store 0x901F → memory bytes 1F 90).
    xchg    al, ah
    mov     [tcp_dport], ax
    mov     word [tcp_sport], 0x50C3               ; 50000 src port (wire BE)
    mov     byte [net_dl_state], 3
    dbg_puts "[A4X] dl: literal IP, TCP dst_ip=", 0
    mov     eax, [tcp_dst_ip]
    call    dbg_print_eax_hex
    dbg_puts " dst_port=", 0
    movzx   eax, word [tcp_dport]
    call    dbg_print_eax_hex
    dbg_nl
    call    tcp_connect
    jmp     .nd_d
.nd_dns:
    ; Poll for UDP DNS response arrival + parse
    call    eth_rx                                  ; pull any UDP frames
    call    dns_check
    cmp     byte [dns_state], 2
    je      .nd_dns_ok
    cmp     byte [dns_state], 3
    je      .nd_dns_fail
    ; still querying → abort after ~300 ticks without a response
    mov     eax, [vtd_t]
    sub     eax, [dns_timeout]
    cmp     eax, 300
    jl      .nd_d
    mov     byte [dns_state], 3
    jmp     .nd_d
.nd_dns_ok:
    mov     eax, [dns_ip]
    mov     [tcp_dst_ip], eax
    ; port handling same as literal (see .nd_port_set byte-order note)
    mov     ax, [dl_dst_port]
    test    ax, ax
    jnz     .nd_dns_port_set
    mov     ax, 80
.nd_dns_port_set:
    xchg    al, ah
    mov     [tcp_dport], ax
    mov     word [tcp_sport], 0x50C3
    mov     byte [nd_dns_retries], 0
    mov     byte [net_dl_state], 3
    dbg_puts "[A4X] dl: DNS OK dword=", 0
    mov     eax, [dns_ip]
    call    dbg_print_eax_hex
    dbg_nl
    call    tcp_connect
    jmp     .nd_d
.nd_dns_fail:
    inc     byte [nd_dns_retries]
    cmp     byte [nd_dns_retries], 3
    jb      .nd_dns_retry
    dbg_puts "[A4X] dl: DNS resolve FAILED 3x, giving up (net_dl state=5)", 13, 10, 0
    mov     byte [net_dl_state], 5                  ; terminal: stop the state machine
    mov     byte [nd_dns_retries], 0
    jmp     .nd_d
.nd_dns_retry:
    dbg_puts "[A4X] dl: DNS resolve FAIL, retrying (reset net_dl)", 13, 10, 0
    mov     byte [net_dl_state], 0
    jmp     .nd_d
.nd_tcp:
    ; Reset per-session TX-pending flag at the start of each state=3 poll cycle
    ; (flag is used by tcp_check to print "TX pending" at most once per connect)
    cmp     byte [nd_tcp_checked], 1
    je      .nd_tcp_checked_ok
    mov     byte [nd_tcp_checked], 1
    mov     byte [tcp_tx_pending_logged], 0
.nd_tcp_checked_ok:
    ; Poll TCP state: check TX completion + RX for SYN-ACK
    call    tcp_check
    ; Also poll ISR ROK and immediately process RX packets (so we don't wait for next tick)
    call    eth_rx
    ; Now check if TCP handshake completed
    cmp     byte [tcp_state], 2
    je      .nd_tcp_ok
    ; Still waiting for SYN-ACK (or timed out -> back to state 0)
    cmp     byte [tcp_state], 0
    jne     .nd_d
    ; Timeout, reset download state
    mov     byte [net_dl_state], 0
    mov     byte [nd_tcp_checked], 0
    jmp     .nd_d
.nd_tcp_ok:
    ; TCP established — build a dynamic HTTP GET (from dl_url_str) using
    ; the http_get helper, which correctly emits "GET /path HTTP/1.1"
    ; plus Host: and Connection: close headers.  This works for any URL
    ; (literal IP or DNS-resolved host).
    dbg_puts "[A4X] TCP: SYN-ACK received — ESTABLISHED", 13, 10, 0
    mov     byte [net_dl_state], 4
    ; Reset HTTP RX state for fresh response
    mov     byte [http_rx_state], 0
    mov     word [http_rx_len], 0
    mov     word [http_hdr_end], 0
    mov     dword [http_content_len], 0
    ; Assemble GET from dl_url_str
    mov     esi, dl_url_str
    call    http_get
    ; Debug: print the request first 64 bytes as hex + ascii
    dbg_puts "[A4X] dl: http_len=", 0
    movzx   eax, word [http_len]
    call    dbg_print_eax_hex
    dbg_puts " first32: `", 0
    push    ecx
    push    esi
    mov     esi, http_buf
    movzx   ecx, word [http_len]
    cmp     ecx, 48
    jbe     .nd_keep_len
    mov     ecx, 48
.nd_keep_len:
.nd_puts_raw:
    lodsb
    cmp     al, 13
    je      .nd_raw_esc
    cmp     al, 10
    je      .nd_raw_esc
    cmp     al, 0
    je      .nd_raw_end
    out     0xE9, al
    jmp     .nd_raw_nx
.nd_raw_esc:
    dbg_puts " ", 0
.nd_raw_nx:
    dec     ecx
    jnz     .nd_puts_raw
.nd_raw_end:
    dbg_puts "`", 13, 10, 0
    pop     esi
    pop     ecx
    ; Send HTTP request via TCP (PSH+ACK)
    mov     esi, http_buf
    movzx   ecx, word [http_len]
    call    tcp_send_data
    jmp     .nd_d
.nd_http:
    ; Poll for incoming packets (process TCP segments)
    call    eth_rx
    ; Check if HTTP body is complete
    cmp     byte [http_rx_state], 3
    jne     .nd_d
    ; HTTP response body is complete
    ; http_body points to body start, http_body_len = body length
    mov     byte [dl_valid], 0
    mov     esi, [http_body]
    test    esi, esi
    jz      .nd_skip_dl
    movzx   ecx, word [http_body_len]
    test    ecx, ecx
    jz      .nd_skip_dl
    ; ---- MZ magic check: route PE downloads to pe_download_buf + pe_parse ----
    mov     ax, [esi]
    cmp     ax, 0x5A4D
    jne     .nd_mz_no
    push    ebx
    push    esi
    push    ecx
    movzx   eax, word [http_body_len]
    cmp     eax, PE_DOWNLOAD_MAX
    jle     .nd_pe_cap
    mov     eax, PE_DOWNLOAD_MAX
.nd_pe_cap:
    mov     ecx, eax
    mov     [pe_download_len], ecx    ; save before rep movsb destroys ecx
    mov     esi, [http_body]
    mov     edi, pe_download_buf
    rep     movsb
    dbg_puts "[A4X] PE downloaded — len=", 0
    mov     eax, [pe_download_len]
    dbg_hex32
    dbg_puts 13, 10, 0
    call    pe_parse
    test    al, al
    jz      .nd_pe_bad
    mov     byte [dl_valid], 3     ; 3 = PE downloaded and parsed
    mov     byte [redraw_fs], 1
    dbg_puts "dl_valid=3", 13, 10, 0
    dbg_puts "[A4X] PE parse OK — calling exe_load", 13, 10, 0
    ; ---- Load and execute the PE ----
    call    exe_load
    test    al, al
    jz      .nd_pe_exec_fail
    dbg_puts "[A4X] PE exec returned OK", 13, 10, 0
    ; ---- Install the downloaded PE into file_table (inet_dl.exe) so it
    ;      persists as an installed OS program (can be re-run later from FS).
    call    fs_install_pe_exe
    test    al, al
    jz      .nd_pe_install_fail
    dbg_puts "[A4X] PE installed to OS OK", 13, 10, 0
    mov     byte [redraw_fs], 1
    ; --- PROVE installation correctness: read file_table entry 7 (slot j used by
    ;     fs_install_pe_exe above — the same scan always lands on slot 7 on a
    ;     freshly booted image with 6 pre-seeded files), confirm:
    ;       * content_off points inside file_contents_pool
    ;       * MZ magic at pool[content_off+0]
    ;       * PE\0\0 signature at pool[content_off + e_lfanew]
    ;     This proves the installed entry actually round-trips a loadable PE.
    push    eax
    push    ebx
    push    ecx
    push    esi
    push    edi
    mov     esi, file_table + 7*FS_SZ          ; j=7: the slot fs_install_pe_exe used
    mov     eax, [esi + FS_CONTENT_OFF]
    mov     ebx, [esi + FS_CONTENT_LEN]
    dbg_puts "[A4X] fpe-verify: slot7 off=", 0
    call    dbg_print_eax_hex
    mov     eax, ebx
    dbg_puts " len=", 0
    call    dbg_print_eax_hex
    ; pool + content_off pointer
    mov     edi, file_contents_pool
    add     edi, [esi + FS_CONTENT_OFF]
    ; ensure content_off is aligned to chunk boundary (off % 1024 == 0)
    mov     eax, [esi + FS_CONTENT_OFF]
    and     eax, (EXE_CONTENT_CHUNK - 1)
    test    eax, eax
    jnz     .ver_bad_align
    ; MZ check
    mov     ax, [edi]
    cmp     ax, 0x5A4D
    jne     .ver_bad_mz
    ; PE sig at e_lfanew
    mov     ecx, [edi + 60]                     ; e_lfanew
    add     ecx, edi
    cmp     dword [ecx], 0x00004550              ; "PE\0\0" LE
    jne     .ver_bad_pe
    ; len sanity: 2560 <= len <= 2561 (allow the known -1 drift)
    mov     ecx, [esi + FS_CONTENT_LEN]
    cmp     ecx, 2560
    jb      .ver_bad_len
    cmp     ecx, 2561
    ja      .ver_bad_len
    dbg_puts "[A4X] fpe-verify: MZ+PE signature OK in file_contents_pool", 13, 10, 0
    jmp     .ver_out
.ver_bad_align:
    dbg_puts "[A4X] fpe-verify: FAIL off not chunk-aligned, off mod 1024=", 0
    call    dbg_print_eax_hex
    dbg_nl
    jmp     .ver_out
.ver_bad_mz:
    dbg_puts "[A4X] fpe-verify: FAIL MZ magic=", 0
    movzx   eax, ax
    call    dbg_print_eax_hex
    dbg_nl
    jmp     .ver_out
.ver_bad_pe:
    dbg_puts "[A4X] fpe-verify: FAIL PE sig dword=", 0
    mov     eax, [ecx]
    call    dbg_print_eax_hex
    dbg_nl
    jmp     .ver_out
.ver_bad_len:
    dbg_puts "[A4X] fpe-verify: FAIL FS_CONTENT_LEN out of [2560,2561]:=", 0
    mov     eax, ecx
    call    dbg_print_eax_hex
    dbg_nl
.ver_out:
    pop     edi
    pop     esi
    pop     ecx
    pop     ebx
    pop     eax
    ; ====================================================================
    ; P0.2 PROOF: installed inet_dl.exe (slot 7) re-loadable purely from
    ; the OS file system (exe_load Priority 0.5 path), proving the
    ; installation is persistent and re-runnable (no download-buf assist).
    ;
    ; Strategy:
    ;   * save eax/ebx/ecx/edx/esi/edi on stack (6 regs)
    ;   * dl = old run_prog, dh = old pe_state (dx free for bytes)
    ;   * run_prog = 7, pe_state = 0 (bypass Prio 0)
    ;   * poison pe_download_buf[0] and [60] with DEADBEEF → proves data
    ;     is copied from file_contents_pool not stale download cache
    ;   * call exe_load → triggers Prio 0.5: FS copy → pe_parse → exec
    ;   * restore run_prog/pe_state from dx, restore 6 saved regs, result in eax
    ; ====================================================================
    pushfd                                       ; [FL] flags pushed FIRST
    push    eax                                  ; [1] saved eax (caller)
    push    ebx                                  ; [2]
    push    ecx                                  ; [3]
    push    edx                                  ; [4]
    push    esi                                  ; [5]
    push    edi                                  ; [6] (deepest)
    ; save run_prog in dl, pe_state in dh
    mov     dl, byte [run_prog]
    mov     dh, byte [pe_state]
    ; trigger Priority 0.5
    mov     byte [run_prog], 7
    mov     byte [pe_state], 0
    ; poison download buf MZ+PE signature bytes
    mov     dword [pe_download_buf + 0],  0xDEADBEEF
    mov     dword [pe_download_buf + 60], 0xDEADBEEF
    dbg_puts "[A4X] fpe-rerun: start slot=7 Prio=0.5 buf_poisoned=Y", 13, 10, 0
    call    exe_load
    ; preserve result in ebx across restore
    mov     ebx, eax
    mov     byte [run_prog], dl
    mov     byte [pe_state], dh
    ; stack (top→deep): edi esi edx ecx ebx_old eax_old FL  (7 dwords)
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    add     esp, 8                               ; discard ebx_old + eax_old
    popfd                                        ; restore caller flags — must be LAST
    mov     eax, ebx                             ; eax = exe_load result
    test    al, al
    jz      .rerun_fail
    dbg_puts "[A4X] fpe-rerun: installed PE re-loaded from file_table OK", 13, 10, 0
    jmp     .rerun_done
.rerun_fail:
    dbg_puts "[A4X] fpe-rerun: FAIL Priority 0.5 did not run installed PE", 13, 10, 0
.rerun_done:
    ; ====================================================================
    ; P1.6 SYNTHETIC ICON CLICK:
    ;   After P0.2 proves Priority 0.5 works for slot 7 (inet_dl.exe), the
    ;   GUI double-click launch path is exercised the same way a real user
    ;   would: mou_handle sets run_prog, pe_state=0, pe_pending_run=1 when
    ;   fs_hit_test detects a click inside an FS_TYPE_FILE_EXE icon rect.
    ;   We apply the exact same state writes here to simulate a user
    ;   double-clicking inet_dl.exe on the desktop.  Main_loop's
    ;   pe_pending_run dispatcher then calls exe_load(Prio 0.5) + pe_exec,
    ;   emitting the "fs_icon: PE launched from icon click exit_code=" line
    ;   that run_real_inet_test.ps1 asserts for P1.6.
    ;   NOTE: slot 7 is reserved for fs_install_pe_exe (see comment at
    ;   ~7480), so we hard-code run_prog=7 to match.
    mov     byte [run_prog], 7
    mov     byte [pe_state], 0
    mov     byte [pe_pending_run], 1
    dbg_puts "[A4X] p16: armed pending run for slot 7 (sim icon click)", 13, 10, 0
    jmp     .nd_pe_done
.nd_pe_install_fail:
    dbg_puts "[A4X] PE install to OS FAILED", 13, 10, 0
    jmp     .nd_pe_done
.nd_pe_exec_fail:
    dbg_puts "[A4X] PE exec FAILED", 13, 10, 0
    jmp     .nd_pe_done
.nd_pe_done:
    ; === P1.5: Active graceful TCP close (FIN+ACK) before returning to
    ;   main loop.  We only do this if tcp_state is still ESTABLISHED and
    ;   we haven't already sent a FIN (prevents double-FIN on failure paths
    ;   that also jump here).  The server's FIN-ACK then arrives via tcp_rx
    ;   .tr_ack_only → fin_state=2, and the server's actual FIN (or a
    ;   piggy-backed FIN+DATA) is handled in .tr_fin.  If no FIN-ACK arrives
    ;   within 200 ticks × 3 retries, tcp_check will close the socket
    ;   silently (fin_state=3 CLOSED) so we never block on shutdown.
    cmp     byte [tcp_state], 2
    jne     .nd_pe_fin_skip
    cmp     byte [tcp_fin_state], 0
    jne     .nd_pe_fin_skip
    call    tcp_send_fin
.nd_pe_fin_skip:
    pop     ecx
    pop     esi
    pop     ebx
    jmp     .nd_skip_dl
.nd_pe_bad:
    pop     ecx
    pop     esi
    pop     ebx
.nd_mz_no:
    ; ---- Fall through to BC_MAGIC detection (original bytecode path) ----
    mov     al, [esi]
    cmp     al, BC_MAGIC
    jne     .nd_skip_dl
    inc     esi
    dec     ecx
    jz      .nd_skip_dl
    cmp     ecx, DL_CODE_SZ
    jle     .nd_cap
    mov     ecx, DL_CODE_SZ
.nd_cap:
    push    ecx                    ; save actual bytecode length for later
    mov     edi, dl_code
    xor     al, al
    mov     eax, DL_CODE_SZ
    stosd
    sub     eax, 4
    mov     ecx, eax
    xor     al, al
    rep     stosb                  ; clear dl_code buffer to 0 first
    pop     ecx                    ; restore actual bytecode length
    mov     edi, dl_code
    mov     eax, ecx
    push    ecx
    push    eax
    rep     movsb                  ; copy bytecode body into dl_code[0..len-1]
    mov     byte [dl_valid], 1     ; transient raw-download state
    ; -------- INSTALL into file_table as FS_TYPE_FILE_EXE --------
    call    fs_install_exe
    test    al, al
    jz      .nd_skip_dl            ; install failed
    mov     byte [dl_valid], 2     ; dl_valid = 2 -> installed
    dbg_puts "dl_valid=2", 13, 10, 0
    ; Force desktop/file-explorer repaint next tick (redraw_all already runs per tick)
    mov     byte [redraw_fs], 1
.nd_skip_dl:
    mov     byte [net_dl_state], 6
    jmp     .nd_d
.nd_done:
    mov     byte [net_dl_state], 6
.nd_d:
    pop     eax
    pop     ebx
    pop     ecx
    pop     edx
    pop     edi
    ret

; ============================================================================
; eth_rx — classify received Ethernet frame by EtherType via RTL8139
;   Properly polls RX ring: checks ISR for ROK, reads per-packet header
;   (status+size DWORD), copies data to nic_rx_data, advances CAPR.
;   RX ring size = 8192 bytes (RCR RBLEN=00).
; ============================================================================
eth_rx:
    push    edi
    push    edx
    push    ecx
    push    ebx
    push    eax
    cmp     byte [nic_type], 1
    jne     .er_d
.er_next_pkt:
    ; ----- Check if any packet is available -----
    ; Method 1: ISR.ROK at 0x3E bit 0 (primary, works with RTL8139 IRQ status)
    mov     al, 0x3E
    call    rtl8139_rd_w         ; ax = ISR
    mov     bx, ax
    test    bl, 0x01             ; ROK (Receive OK) interrupt bit
    jnz     .er_process
    ; Method 2: Pure ring-head poll. RTL8139 does NOT expose a "CBR" register
    ; at 0x3A (that is TSD0 upper = TX status 0).  Instead we peek the next
    ; expected packet-header DWORD in the RX ring at offset (CAPR+0x10) mod 8K.
    ; If its ROK bit (dword bit 0) is set, NIC has finished writing this packet.
    mov     al, 0x38
    call    rtl8139_rd_w         ; ax = CAPR
    movzx   ecx, ax
    add     cx, 0x10
    and     cx, 0x1FFF           ; ecx = next expected header offset
    mov     esi, rtl8139_rx_buf
    add     esi, ecx             ; esi = &rx_buf[next_header_off]
    mov     eax, [esi]           ; eax = 32-bit packet header (status + size)
    test    ax, 0x003F           ; Check ROK(bit0) + error bits(0x3E) in low 16 bits
    jnz     .er_process         ; ROK or errors set → packet present (even if bad)
    mov     ax, [esi]            ; re-read low 16 bits
    test    eax, 0xFFFF0000      ; Check if upper 16 bits (frame size) are non-zero
    jnz     .er_process         ; Size > 0 → packet present
    ; One-shot debug: print why no packet was found (ISR, CAPR, peek value)
    cmp     byte [eth_rx_dbg_logged], 1
    je      .er_d
    mov     byte [eth_rx_dbg_logged], 1
    push    eax
    push    ebx
    push    ecx
    push    edx
    dbg_puts "[A4X] eth_rx NOPKT ISR=", 0
    mov     al, 0x3E
    call    rtl8139_rd_w
    movzx   eax, ax
    call    dbg_print_eax_hex
    dbg_puts " CAPR=", 0
    mov     al, 0x38
    call    rtl8139_rd_w
    movzx   eax, ax
    call    dbg_print_eax_hex
    dbg_puts " peek=", 0
    mov     al, 0x38
    call    rtl8139_rd_w
    movzx   ecx, ax
    add     cx, 0x10
    and     cx, 0x1FFF
    mov     esi, rtl8139_rx_buf
    add     esi, ecx
    mov     eax, [esi]
    call    dbg_print_eax_hex
    dbg_puts " RSR=", 0
    ; Also read RSR (Receive Status Register) at offset 0x3C (16-bit)
    mov     al, 0x3C
    call    rtl8139_rd_w
    movzx   eax, ax
    call    dbg_print_eax_hex
    dbg_puts " rbstart=", 0
    mov     al, 0x30
    call    rtl8139_rd_d
    mov     eax, ebx
    call    dbg_print_eax_hex
    ; Dump first 32 bytes of rx_buf for forensic inspection
    push    eax
    push    ecx
    push    esi
    mov     ecx, 32
    mov     esi, rtl8139_rx_buf
    dbg_puts " rx[0..32]=", 0
.er_hx_dump:
    lodsb
    dbg_hex8
    dec     ecx
    jnz     .er_hx_dump
    pop     esi
    pop     ecx
    pop     eax
    dbg_puts 13, 10, 0
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    jmp     .er_d
    ; Have packet via ring peek — log as CBR!=CAPR detected (equiv to ring head advance)
    dbg_puts "[A4X] eth_rx CBR!=CAPR ring-head packet detected", 13, 10, 0
.er_process:
    ; Compute read offset = (CAPR + 0x10) mod 8K -> points to 4-byte pkt header
    mov     al, 0x38
    call    rtl8139_rd_w         ; ax = CAPR
    movzx   ebx, ax
    add     bx, 0x10
    and     bx, 0x1FFF           ; ebx = read offset into rtl8139_rx_buf
    ; Read packet header DWORD at rx_buf[ebx]:
    ;   word [ebx+0] = RxStatus (ROK bit0, errors)
    ;   word [ebx+2] = FrameSize (bytes, no header, usually strip CRC)
    mov     esi, rtl8139_rx_buf
    add     esi, ebx
    mov     ax, [esi]            ; ax = status word
    mov     dx, [esi+2]          ; dx = frame size
    ; Log packet header
    dbg_puts "[A4X] eth_rx HDR status=", 0
    movzx   eax, ax
    call    dbg_print_eax_hex
    dbg_puts " sz=", 0
    movzx   eax, dx
    call    dbg_print_eax_dec
    dbg_puts 13, 10, 0
    test    ax, 0x003E           ; Check error bits: FAE(0x02)|CRC(0x04)|LONG(0x08)|RUNT(0x10)|ISE(0x20)
    jnz     .er_badpkt          ; Has errors → skip packet
    ; Clamp frame size to <= 1536 (nic_rx_data capacity), skip 0-length
    movzx   ecx, dx
    test    ecx, ecx
    jz      .er_badpkt
    cmp     cx, 1536
    jbe     .er_szok
    mov     cx, 1536
.er_szok:
    ; Move read offset +4 to skip the 4-byte header -> frame data start
    add     bx, 4
    and     bx, 0x1FFF
    ; Copy rtl8139_rx_buf[ebx : ebx+ecx] -> nic_rx_data
    mov     esi, rtl8139_rx_buf
    add     esi, ebx
    mov     edi, nic_rx_data
    rep     movsb
    ; --- Advance CAPR past the consumed packet (Linux 8139too convention) ---
    ; Linux: RTL_W16(Capr, cur_rx - 16).  QEMU honors 16-bit reads AND 16-bit
    ; writes to CAPR (0x38); 32-bit I/O on this register is broken (init's 32-bit
    ; readback returned 0, and 32-bit writes are silently ignored).  Use 16-bit.
    ; dx = frame size, preserved across debug prints & helper calls.
    mov     al, 0x38
    call    rtl8139_rd_w          ; ax = old CAPR
    movzx   ebx, ax              ; ebx = old CAPR
    push    ebx                  ; [esp+8] = old CAPR
    add     ax, 0x10             ; read_offset = (CAPR + 0x10) & 0x1FFF
    and     ax, 0x1FFF
    add     ax, 4                ; skip 4-byte header
    add     ax, dx               ; + frame size
    add     ax, 3                ; dword align
    and     ax, 0xFFFC
    and     ax, 0x1FFF           ; ax = next read offset
    sub     ax, 0x10             ; ax = new CAPR (= next_read_off - 0x10)
    movzx   eax, ax
    push    eax                  ; [esp+4] = new CAPR
    mov     bx, ax               ; bx = new CAPR (16-bit value for wr_w)
    mov     al, 0x38
    call    rtl8139_wr_w          ; 16-bit write CAPR (QEMU honors this)
    mov     al, 0x38
    call    rtl8139_rd_w          ; ax = readback CAPR
    movzx   eax, ax
    push    eax                  ; [esp+0] = readback
    cmp     byte [eth_rx_adv_cnt], 16
    jae     .adv_dbg_done
    inc     byte [eth_rx_adv_cnt]
    dbg_puts "[A4X] eth_rx ADV old=", 0
    mov     eax, [esp+8]
    call    dbg_print_eax_hex
    dbg_puts " new=", 0
    mov     eax, [esp+4]
    call    dbg_print_eax_hex
    dbg_puts " rd=", 0
    mov     eax, [esp]
    call    dbg_print_eax_hex
    dbg_puts 13, 10, 0
.adv_dbg_done:
    pop     eax                  ; discard readback
    pop     eax                  ; discard new CAPR
    pop     ebx                  ; discard old CAPR
    ; Clear ISR ROK (write 1 to bit 0 of ISR 0x3E) — use 16-bit write for QEMU reliability
    mov     al, 0x3E
    mov     bx, 0x0001
    call    rtl8139_wr_w
    ; Dispatch frame by EtherType stored in nic_rx_data
    mov     edi, nic_rx_data
    mov     ax, [edi+12]
    cmp     ax, 0x0608           ; ARP 0x0806 BE -> LE 0x0608
    je      .er_arp
    cmp     ax, 0x0008           ; IP 0x0800 BE -> LE 0x0008
    je      .er_ip
    ; unknown EtherType: continue polling for more packets
    jmp     .er_continue
.er_arp:
    call    arp_check
    jmp     .er_continue
.er_ip:
    call    ip_rx
    jmp     .er_continue
.er_badpkt:
    ; If size=0, this is an empty slot (ISR.RxOK stale or packet not yet
    ; written). Do NOT advance CAPR — advancing past empty slots causes CAPR
    ; to overrun CBR, making us miss packets that arrive later at CBR.
    ; Re-read size directly from the buffer to be safe (in case dx was clobbered
    ; by any debug helper between lines 6207 and here).
    push    edx
    mov     al, 0x38
    call    rtl8139_rd_w
    movzx   ebx, ax
    add     bx, 0x10
    and     bx, 0x1FFF
    mov     esi, rtl8139_rx_buf
    add     esi, ebx
    movzx   edx, word [esi+2]    ; edx = frame size (re-read, safe)
    test    edx, edx
    pop     edx
    jnz     .er_real_badpkt
    ; Empty slot — clear ISR.RxOK via 16-bit write and return.
    dbg_puts "[A4X] eth_rx empty slot — CAPR held", 13, 10, 0
    mov     al, 0x3E
    mov     bx, 0x0001
    call    rtl8139_wr_w          ; 16-bit write: clear RxOK bit
    jmp     .er_d
.er_real_badpkt:
    ; Real bad packet (size>0 with error bits) — advance CAPR past it.
    ; Use same advancement formula as good path: oldCAPR + 0x10 + 4 + size + align - 0x10
    ; Re-read size from buffer for safety.
    push    edx
    mov     al, 0x38
    call    rtl8139_rd_w
    movzx   ebx, ax
    add     bx, 0x10
    and     bx, 0x1FFF
    mov     esi, rtl8139_rx_buf
    add     esi, ebx
    movzx   edx, word [esi+2]    ; edx = frame size (safe re-read)
    dbg_puts "[A4X] eth_rx BADPKT — skipping slot sz=", 0
    mov     eax, edx
    call    dbg_print_eax_dec
    dbg_puts 13, 10, 0
    mov     al, 0x38
    call    rtl8139_rd_w          ; ax = old CAPR
    add     ax, 0x10              ; +0x10 to get read offset
    and     ax, 0x1FFF
    add     ax, 4                 ; skip 4-byte header
    add     ax, dx                ; + frame size
    add     ax, 3                 ; dword align
    and     ax, 0xFFFC
    and     ax, 0x1FFF            ; wrap to 8K
    sub     ax, 0x10              ; convert back to CAPR
    mov     bx, ax                ; bx = new CAPR (16-bit value)
    mov     al, 0x38
    call    rtl8139_wr_w          ; 16-bit write CAPR
    pop     edx
    ; Clear ROK via 16-bit write
    mov     al, 0x3E
    mov     bx, 0x0001
    call    rtl8139_wr_w          ; 16-bit write: clear RxOK bit
    jmp     .er_d                ; bail out after bad packet
.er_continue:
    ; Loop for more packets in the same tick (typical RX burst)
    jmp     .er_next_pkt
.er_d:
    pop     eax
    pop     ebx
    pop     ecx
    pop     edx
    pop     edi
    ret

; ============================================================================
; tcp_cksum — compute TCP checksum (pseudo-header + TCP segment)
;   IN:  ax = TCP segment length (bytes, including TCP header)
;   Uses: IP addresses from net_tx_buf IP header, TCP header at net_tx_buf+34
;   OUT: ax = checksum (ready to store at TCP header offset +16)
; ============================================================================
tcp_cksum:
    push    ebx
    push    ecx
    push    esi
    push    edx
    movzx   edx, ax
    ; Clear TCP checksum field
    mov     word [net_tx_buf+34+16], 0
    ; Pseudo-header sum — IP addresses stored in net byte order.
    ; Sum directly as LE words so return AX is LE-ready for MOV.
    xor     ebx, ebx
    mov     esi, net_tx_buf + 26        ; src IP (IP header +12)
    lodsw
    movzx   eax, ax
    add     ebx, eax
    lodsw
    movzx   eax, ax
    add     ebx, eax
    lodsw                               ; dst IP (IP header +16)
    movzx   eax, ax
    add     ebx, eax
    lodsw
    movzx   eax, ax
    add     ebx, eax
    ; proto(6)+zero in network byte order: 0x0600 (BE 0x0006)
    add     ebx, 0x0600
    ; TCP length (swap to match pseudo-header byte order)
    mov     ax, dx
    xchg    al, ah
    movzx   eax, ax
    add     ebx, eax
    ; Sum TCP segment words
    mov     esi, net_tx_buf + 34
    mov     ecx, edx
    shr     ecx, 1
.tc_l:
    test    ecx, ecx
    jz      .tc_tail
    lodsw
    movzx   eax, ax
    add     ebx, eax
    dec     ecx
    jmp     .tc_l
.tc_tail:
    ; Odd segment length: the final byte must be folded in (RFC 1071 pads
    ; with a zero byte).  Our words are summed byte-swapped (LE lodsw of BE
    ; data), so the tail byte lands in the low position — add it directly.
    ; This bug silently corrupted TCP checksums for odd-length payloads
    ; (e.g. the 65-byte GET to httpbin.org) causing remote servers to drop
    ; the segment; even-length payloads (local 64-byte GET) masked it.
    test    dx, 1
    jz      .tc_d
    movzx   eax, byte [esi]
    add     ebx, eax
.tc_d:
    mov     ax, bx
    shr     ebx, 16
    add     ax, bx
    adc     ax, 0
    not     ax
    pop     edx
    pop     esi
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; tcp_connect — send TCP SYN
;   IN:  tcp_sport, tcp_dport, tcp_seq, tcp_dst_ip set
;   OUT: tcp_state = 1 (SYN_SENT)
; ============================================================================
tcp_connect:
    push    edi
    push    edx
    push    ecx
    push    ebx
    push    eax
    ; --- Ethernet header (14 bytes) ---
    mov     edi, net_tx_buf
    ; dst MAC = arp_reply_mac (resolved gateway/host MAC)
    mov     eax, [arp_reply_mac]
    mov     dword [edi+0], eax
    mov     ax, [arp_reply_mac+4]
    mov     word [edi+4], ax
    ; src MAC = our MAC
    mov     eax, [nic_mac_lo]
    mov     dword [edi+6], eax
    mov     ax, [nic_mac_hi]
    mov     word [edi+10], ax
    ; EtherType 0x0800 (IP) → LE 0x0008
    mov     word [edi+12], 0x0008
    ; --- IP header (20 bytes at net_tx_buf+14) ---
    mov     edi, net_tx_buf + 14
    mov     byte [edi+0], 0x45          ; version/IHL
    mov     byte [edi+1], 0             ; TOS
    mov     word [edi+2], 0x2800        ; total length 40 (BE 0x0028 → LE 0x2800)
    mov     word [edi+4], 0             ; identification
    mov     word [edi+6], 0x0040        ; flags=DF (BE 0x4000 → LE 0x0040)
    mov     byte [edi+8], 64            ; TTL
    mov     byte [edi+9], 6             ; protocol = TCP
    mov     word [edi+10], 0            ; checksum (to be filled)
    mov     dword [edi+12], 0x0F02000A  ; src IP 10.0.2.15 (BE → LE dword)
    mov     eax, [tcp_dst_ip]
    mov     [edi+16], eax               ; dst IP (already in BE/LE format)
    ; IP checksum (10 words = 20 bytes)
    mov     esi, edi
    mov     cx, 10
    call    ip_cksum
    mov     [edi+10], ax
    ; --- TCP header (20 bytes at net_tx_buf+34) ---
    mov     edi, net_tx_buf + 34
    mov     ax, [tcp_sport]
    mov     [edi+0], ax                 ; src port (already BE-encoded)
    mov     ax, [tcp_dport]
    mov     [edi+2], ax                 ; dst port (already BE-encoded)
    ; seq number (bswap to BE)
    mov     eax, [tcp_seq]
    bswap   eax
    mov     [edi+4], eax
    ; ack number = 0
    mov     dword [edi+8], 0
    ; data offset (5 = 20 bytes) + flags (SYN=0x02)
    mov     byte [edi+12], 0x50         ; data offset = 5
    mov     byte [edi+13], 0x02         ; SYN flag
    mov     word [edi+14], 0xFFFF       ; window (max, same in BE/LE)
    mov     word [edi+16], 0            ; checksum (to be filled)
    mov     word [edi+18], 0            ; urgent pointer
    ; TCP checksum (segment length = 20)
    mov     ax, 20
    call    tcp_cksum
    mov     [net_tx_buf+34+16], ax
    ; Send
    mov     word [net_tx_len], 54       ; 14 eth + 20 IP + 20 TCP
    ; Debug: dump raw SYN bytes for analysis
    push    eax
    push    ecx
    mov     esi, net_tx_buf
    mov     ecx, 54
    dbg_puts "[A4X] SYN hex:", 13, 10, 0
    push    esi
tcp_syn_dump_loop:
    lodsb
    push    eax
    dbg_hex8
    pop     eax
    dec     ecx
    jnz     tcp_syn_dump_loop
    dbg_puts 13, 10, 0
    pop     esi
    pop     ecx
    pop     eax
    call    eth_send
    dbg_puts "[A4X] TCP: SYN sent (len 54)", 13, 10, 0
    mov     byte [tcp_state], 1
    mov     eax, [vtd_t]
    mov     [tcp_timeout], eax
    ; --- P1.5: snapshot SYN frame for retransmit; zero retries ---
    mov     byte [tcp_retries], 0
    mov     byte [tcp_fin_state], 0
    mov     eax, 54
    call    tcp_snapshot_last
    pop     eax
    pop     ebx
    pop     ecx
    pop     edx
    pop     edi
    ret

; ============================================================================
; tcp_send_ack — send a TCP ACK packet
;   Uses: tcp_seq, tcp_ack, tcp_dst_ip, arp_reply_mac
; ============================================================================
tcp_send_ack:
    push    edi
    push    edx
    push    ecx
    push    ebx
    push    eax
    ; --- Ethernet header ---
    mov     edi, net_tx_buf
    mov     eax, [arp_reply_mac]
    mov     dword [edi+0], eax
    mov     ax, [arp_reply_mac+4]
    mov     word [edi+4], ax
    mov     eax, [nic_mac_lo]
    mov     dword [edi+6], eax
    mov     ax, [nic_mac_hi]
    mov     word [edi+10], ax
    mov     word [edi+12], 0x0008       ; EtherType IP
    ; --- IP header ---
    mov     edi, net_tx_buf + 14
    mov     byte [edi+0], 0x45
    mov     byte [edi+1], 0
    mov     word [edi+2], 0x2800        ; total length 40
    mov     word [edi+4], 0
    mov     word [edi+6], 0x0040        ; DF
    mov     byte [edi+8], 64
    mov     byte [edi+9], 6
    mov     word [edi+10], 0
    mov     dword [edi+12], 0x0F02000A  ; src 10.0.2.15
    mov     eax, [tcp_dst_ip]
    mov     [edi+16], eax
    mov     esi, edi
    mov     cx, 10
    call    ip_cksum
    mov     [edi+10], ax
    ; --- TCP header ---
    mov     edi, net_tx_buf + 34
    mov     ax, [tcp_sport]
    mov     [edi+0], ax
    mov     ax, [tcp_dport]
    mov     [edi+2], ax
    mov     eax, [tcp_seq]
    bswap   eax
    mov     [edi+4], eax                ; seq
    mov     eax, [tcp_ack]
    bswap   eax
    mov     [edi+8], eax                ; ack
    mov     byte [edi+12], 0x50         ; data offset = 5
    mov     byte [edi+13], 0x10         ; ACK flag
    mov     word [edi+14], 0xFFFF       ; window
    mov     word [edi+16], 0
    mov     word [edi+18], 0
    mov     ax, 20
    call    tcp_cksum
    mov     [net_tx_buf+34+16], ax
    mov     word [net_tx_len], 54
    call    eth_send
    pop     eax
    pop     ebx
    pop     ecx
    pop     edx
    pop     edi
    ret

; ============================================================================
; tcp_send_data — send TCP data (PSH+ACK)
;   IN:  esi = data pointer, ecx = data length
;   Uses: tcp_seq, tcp_ack, tcp_dst_ip, arp_reply_mac, tcp_sport, tcp_dport
; ============================================================================
tcp_send_data:
    push    edi
    push    edx
    push    ecx
    push    ebx
    push    eax
    mov     edx, ecx                    ; edx = data length
    ; --- Copy payload to net_tx_buf+54 FIRST (before ip_cksum clobbers esi) ---
    mov     edi, net_tx_buf + 54
    mov     ecx, edx
    rep     movsb
    ; --- Ethernet header ---
    mov     edi, net_tx_buf
    mov     eax, [arp_reply_mac]
    mov     dword [edi+0], eax
    mov     ax, [arp_reply_mac+4]
    mov     word [edi+4], ax
    mov     eax, [nic_mac_lo]
    mov     dword [edi+6], eax
    mov     ax, [nic_mac_hi]
    mov     word [edi+10], ax
    mov     word [edi+12], 0x0008       ; EtherType IP
    ; --- IP header (20 bytes at net_tx_buf+14) ---
    mov     edi, net_tx_buf + 14
    mov     byte [edi+0], 0x45
    mov     byte [edi+1], 0
    ; total length = 40 + data_len, stored as BE word
    mov     eax, 40
    add     eax, edx
    xchg    al, ah
    mov     [edi+2], ax
    mov     word [edi+4], 0
    mov     word [edi+6], 0x0040        ; DF
    mov     byte [edi+8], 64
    mov     byte [edi+9], 6             ; TCP
    mov     word [edi+10], 0
    mov     dword [edi+12], 0x0F02000A  ; src 10.0.2.15
    mov     eax, [tcp_dst_ip]
    mov     [edi+16], eax
    mov     esi, edi
    mov     cx, 10
    call    ip_cksum
    mov     [edi+10], ax
    ; --- TCP header (20 bytes at net_tx_buf+34) ---
    mov     edi, net_tx_buf + 34
    mov     ax, [tcp_sport]
    mov     [edi+0], ax
    mov     ax, [tcp_dport]
    mov     [edi+2], ax
    mov     eax, [tcp_seq]
    bswap   eax
    mov     [edi+4], eax                ; seq
    mov     eax, [tcp_ack]
    bswap   eax
    mov     [edi+8], eax                ; ack
    mov     byte [edi+12], 0x50         ; data offset = 5
    mov     byte [edi+13], 0x18         ; PSH+ACK flags
    mov     word [edi+14], 0xFFFF       ; window
    mov     word [edi+16], 0            ; checksum (to be filled)
    mov     word [edi+18], 0            ; urgent pointer
    ; TCP checksum: segment length = 20 + data_len
    mov     eax, 20
    add     eax, edx
    call    tcp_cksum
    mov     [net_tx_buf+34+16], ax
    ; --- Send ---
    mov     eax, 54
    add     eax, edx
    mov     [net_tx_len], ax
    call    eth_send
    dbg_puts "[A4X] TCP: data sent (GET request)", 13, 10, 0
    ; --- Update sequence: tcp_seq += data_len ---
    mov     eax, [tcp_seq]
    add     eax, edx
    mov     [tcp_seq], eax
    ; --- P1.5: snapshot TX frame for potential retransmission ---
    movzx   eax, word [net_tx_len]
    call    tcp_snapshot_last
    ; --- Restart timeout so tcp_check can detect DATA loss (not just SYN loss) ---
    mov     eax, [vtd_t]
    mov     [tcp_timeout], eax
    mov     byte [tcp_retries], 0
    pop     eax
    pop     ebx
    pop     ecx
    pop     edx
    pop     edi
    ret

; ============================================================================
; tcp_snapshot_last — copy the just-transmitted full Ethernet frame from
;   net_tx_buf into tcp_last_tx_snap[].  Used by tcp_check for retransmit
;   when a segment (SYN, HTTP GET, or FIN) times out before we get an ACK.
;   IN:  eax = frame length (0 < eax <= 128 bytes; our SYN=54, GET~=100,
;        FIN/ACK=54, all fit).  Frame longer than 128 is silently truncated.
;   clobbers ecx, esi, edi, eax; must be called as callee helper with own
;   push/pop preservation not needed (caller is send routine that preserves
;   on stack; here we additionally preserve caller regs).
; ============================================================================
tcp_snapshot_last:
    push    ecx
    push    esi
    push    edi
    push    edx
    ; clamp to snap buffer size (128)
    cmp     eax, 128
    jbe     .tsl_sz_ok
    mov     eax, 128
.tsl_sz_ok:
    mov     [tcp_last_tx_len], ax
    movzx   ecx, ax
    mov     esi, net_tx_buf
    mov     edi, tcp_last_tx_snap
    cld
    rep     movsb
    ; zero-fill remainder so old payload bytes don't bleed on a shorter retransmit
    mov     ecx, 128
    sub     cx, ax
    jbe     .tsl_done
    xor     al, al
    rep     stosb
.tsl_done:
    pop     edx
    pop     edi
    pop     esi
    pop     ecx
    ret

; ============================================================================
; tcp_retransmit_last — re-play tcp_last_tx_snap[] verbatim via eth_send.
;   Caller is responsible for checking tcp_retries < limit, bumping retries,
;   and resetting tcp_timeout.  No state changes beyond raw replay.
;   Returns with eth_send completed (net_tx_buf restored from snapshot on
;   the NIC wire; tcp_last_tx_snap untouched, can replay multiple times).
; ============================================================================
tcp_retransmit_last:
    push    ecx
    push    esi
    push    edi
    push    eax
    movzx   ecx, word [tcp_last_tx_len]
    test    ecx, ecx
    jz      .trl_done                   ; nothing saved, can't retransmit
    cmp     cx, 128
    ja      .trl_done                   ; safeguard
    mov     esi, tcp_last_tx_snap
    mov     edi, net_tx_buf
    cld
    rep     movsb
    ; Restore net_tx_len for eth_send
    mov     [net_tx_len], cx
    call    eth_send
    dbg_puts "[A4X] TCP: retransmitted last frame len=", 0
    movzx   eax, cx
    dbg_hex32
    dbg_puts " retry=", 0
    movzx   eax, byte [tcp_retries]
    dbg_hex32
    dbg_puts 13, 10, 0
.trl_done:
    pop     eax
    pop     edi
    pop     esi
    pop     ecx
    ret

; ============================================================================
; tcp_send_fin — send an active TCP close: FIN+ACK segment (flags 0x11).
;   On call: tcp_seq / tcp_ack / tcp_dst_ip / arp_reply_mac / ports must all
;   be valid (ESTABLISHED state, post-data).  After sending:
;     tcp_fin_state=1 (FIN_SENT)
;     tcp_seq += 1 (FIN consumes 1 sequence number)
;     tcp_timeout = vtd_t  (so we wait for FIN-ACK up to 1 retransmission)
;   Uses the same eth/ip/tcp header shape as tcp_send_ack, but with FIN=1.
; ============================================================================
tcp_send_fin:
    push    edi
    push    edx
    push    ecx
    push    ebx
    push    eax
    ; --- Ethernet header ---
    mov     edi, net_tx_buf
    mov     eax, [arp_reply_mac]
    mov     dword [edi+0], eax
    mov     ax, [arp_reply_mac+4]
    mov     word [edi+4], ax
    mov     eax, [nic_mac_lo]
    mov     dword [edi+6], eax
    mov     ax, [nic_mac_hi]
    mov     word [edi+10], ax
    mov     word [edi+12], 0x0008
    ; --- IP header (20 bytes) ---
    mov     edi, net_tx_buf + 14
    mov     byte [edi+0], 0x45
    mov     byte [edi+1], 0
    mov     word [edi+2], 0x2800        ; total len 40
    mov     word [edi+4], 0
    mov     word [edi+6], 0x0040        ; DF
    mov     byte [edi+8], 64
    mov     byte [edi+9], 6             ; TCP
    mov     word [edi+10], 0
    mov     dword [edi+12], 0x0F02000A  ; src 10.0.2.15
    mov     eax, [tcp_dst_ip]
    mov     [edi+16], eax
    mov     esi, edi
    mov     cx, 10
    call    ip_cksum
    mov     [edi+10], ax
    ; --- TCP header (FIN + ACK, flags byte = 0x11) ---
    mov     edi, net_tx_buf + 34
    mov     ax, [tcp_sport]
    mov     [edi+0], ax
    mov     ax, [tcp_dport]
    mov     [edi+2], ax
    mov     eax, [tcp_seq]
    bswap   eax
    mov     [edi+4], eax                ; seq
    mov     eax, [tcp_ack]
    bswap   eax
    mov     [edi+8], eax                ; ack
    mov     byte [edi+12], 0x50         ; data offset 5 (20-byte hdr)
    mov     byte [edi+13], 0x11         ; FIN | ACK
    mov     word [edi+14], 0xFFFF       ; window
    mov     word [edi+16], 0            ; cksum placeholder
    mov     word [edi+18], 0            ; urgent
    mov     ax, 20
    call    tcp_cksum
    mov     [net_tx_buf+34+16], ax
    mov     word [net_tx_len], 54
    call    eth_send
    dbg_puts "[A4X] TCP: FIN+ACK sent (graceful close)", 13, 10, 0
    ; FIN consumes 1 seq, snapshot for retransmit, arm FIN timeout
    inc     dword [tcp_seq]
    mov     eax, 54
    call    tcp_snapshot_last
    mov     byte [tcp_fin_state], 1     ; FIN_SENT
    mov     byte [tcp_retries], 0
    mov     eax, [vtd_t]
    mov     [tcp_timeout], eax
    pop     eax
    pop     ebx
    pop     ecx
    pop     edx
    pop     edi
    ret

; ============================================================================
; tcp_rx — process received TCP segment at nic_rx_data
;   Called from ip_rx when protocol = 6 (TCP)
; ============================================================================
tcp_rx:
    push    edi
    push    edx
    push    ecx
    push    ebx
    push    esi
    push    eax
    ; TCP header starts at nic_rx_data + 14 (eth) + 20 (IP, IHL=5)
    mov     edi, nic_rx_data + 34
    ; Read data offset (upper 4 bits of byte +12)
    mov     al, [edi+12]
    shr     al, 4
    movzx   ecx, al
    shl     ecx, 2              ; ecx = TCP header length in bytes
    ; Debug: print TCP header length at start of tcp_rx
    push    eax
    push    ebx
    push    ecx
    push    edx
    dbg_puts "[A4X] tcp_rx hdrlen=", 0
    movzx   eax, cl
    dbg_hex32
    dbg_puts " flags=", 0
    movzx   eax, bl
    dbg_hex32
    dbg_puts 13, 10, 0
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ; Read flags (byte +13)
    mov     bl, [edi+13]
    ; --- P1.5: Abort on incoming RST (flags bit 2) immediately ---
    test    bl, 0x04
    jnz     .tr_rst
    ; Debug: print flags at start of tcp_rx
    push    eax
    push    ebx
    push    ecx
    push    edx
    dbg_puts "[A4X] tcp_rx flags=", 0
    movzx   eax, bl
    call    dbg_print_eax_hex
    dbg_puts 13, 10, 0
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ; --- P1.5: any in-order ACKed segment means our last transmit landed,
    ;   so clear retries counter (reset retransmission budget).
    mov     byte [tcp_retries], 0
    ; Check for SYN+ACK: BOTH SYN(0x02) AND ACK(0x10) must be set.
    ; BUG-FIX: previous code used `test bl, 0x12; jnz .tr_synack` which matched
    ; ANY packet with SYN OR ACK — since ALL post-handshake packets have ACK,
    ; every PSH+ACK/FIN+ACK/pure-ACK segment misrouted here, discarding payload
    ; and causing the server retransmission storm (1314 packets in pcap).
    mov     bh, bl
    and     bh, 0x12
    cmp     bh, 0x12
    je      .tr_synack
    ; FIX: any segment with payload must be appended, even WITHOUT the PSH
    ; flag.  Linux servers set PSH only on the last segment of a burst; middle
    ; segments arrive as pure ACK (0x10).  The old code only processed PSH
    ; segments, dropping e.g. a 1444-byte middle fragment (never appended and
    ; never ACKed -> server retransmitted, leaving a permanent body hole).
    ; payload_len = IP total length - IP header (20) - TCP header (ecx)
    movzx   eax, word [nic_rx_data + 16]  ; IP total length (BE, at offset 14+2)
    xchg    al, ah              ; byte-swap to LE
    sub     eax, 20             ; subtract IP header
    sub     eax, ecx            ; subtract TCP header
    test    eax, eax
    jnz     .tr_data            ; payload present -> process as data
    ; Zero-payload: FIN ends the stream (covers FIN+ACK)
    test    bl, 0x01
    jnz     .tr_fin
    ; Pure ACK (0x10) — nothing to do, fall through
    jmp     .tr_d
.tr_synack:
    ; Save server seq for ACK
    mov     eax, [edi+4]        ; server seq (BE in packet)
    bswap   eax                 ; convert to LE
    inc     eax                 ; ack = server_seq + 1
    mov     [tcp_ack], eax
    ; Save our new seq from the ACK field
    mov     eax, [edi+8]        ; ack field (BE)
    bswap   eax                 ; convert to LE
    mov     [tcp_seq], eax
    mov     byte [tcp_state], 2 ; ESTABLISHED
    call    tcp_send_ack
    jmp     .tr_d
.tr_data:
    ; Extract payload
    ; Payload start = edi + TCP_header_length
    mov     esi, edi
    add     esi, ecx            ; esi = payload start
    dbg_puts "[A4X] TCP data received — appending to http_rx_buf", 13, 10, 0
    ; Debug: print TCP flags
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     bl, [nic_rx_data + 34 + 13]
    dbg_puts " TCP flags=0x", 0
    movzx   eax, bl
    dbg_hex32
    dbg_puts 13, 10, 0
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ; Payload length = IP total length - IP header (20) - TCP header
    movzx   eax, word [nic_rx_data + 16]  ; IP total length (BE, at offset 14+2)
    xchg    al, ah              ; byte-swap to LE
    sub     eax, 20             ; subtract IP header
    sub     eax, ecx            ; subtract TCP header
    ; eax = payload length
    test    eax, eax
    jz      .tr_ack_only
    ; Save payload length
    mov     [tcp_rx_len], ax
    ; --- Append payload to http_rx_buf at http_rx_len offset ---
    movzx   ecx, ax             ; ecx = payload length (for rep movsb)
    mov     edi, http_rx_buf
    movzx   edx, word [http_rx_len]
    add     edi, edx            ; edi = http_rx_buf + accumulated offset
    ; Bounds check: http_rx_len + payload_len <= 4096
    movzx   edx, word [http_rx_len]
    add     edx, ecx
    cmp     edx, 4096
    jbe     .tr_fit
    ; Truncate to fit
    mov     ecx, 4096
    sub     cx, word [http_rx_len]
    jz      .tr_skip_copy      ; buffer full, skip
.tr_fit:
    push    ecx                 ; save actual copy count
    push    esi                 ; save payload ptr
    rep     movsb               ; append payload to http_rx_buf
    pop     esi                 ; restore payload ptr (for seq calc below)
    ; Update http_rx_len
    movzx   eax, word [http_rx_len]
    pop     ecx                 ; ecx = actual copy count
    add     eax, ecx
    mov     [http_rx_len], ax
    ; Debug: print http_rx_len after copy
    push    eax
    push    ebx
    push    ecx
    push    edx
    dbg_puts "[A4X] after_copy http_rx_len=", 0
    movzx   eax, word [http_rx_len]
    dbg_hex32
    dbg_puts " buf[0..3]=", 0
    mov     eax, [http_rx_buf]
    dbg_hex32
    dbg_puts 13, 10, 0
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ; --- Check for HTTP header end (\r\n\r\n) if not yet found ---
    cmp     byte [http_rx_state], 2
    jae     .tr_hdr_done        ; already found header end
    ; Search for \r\n\r\n in http_rx_buf
    mov     edi, http_rx_buf
    movzx   ecx, word [http_rx_len]
    sub     ecx, 3              ; need at least 4 bytes
    jle     .tr_no_hdr
    mov     al, 0x0D
.tr_find_cr:
    repne   scasb
    jne     .tr_no_hdr          ; no \r found
    ; Check \r\n\r\n
    cmp     dword [edi-1], 0x0A0D0A0D  ; \r\n\r\n (LE: 0D 0A 0D 0A)
    jne     .tr_find_cr
    ; Found! edi-1 points to \r, body starts at edi+3
    ; body offset = (edi+3) - http_rx_buf
    mov     eax, edi
    sub     eax, http_rx_buf
    add     eax, 3              ; skip \r\n\r\n (edi-1..edi+2)
    mov     [http_hdr_end], ax
    mov     byte [http_rx_state], 2  ; headers done
    dbg_puts "[A4X] HTTP header end found", 13, 10, 0
    ; --- Parse Content-Length ---
    ; Search for "Content-Length:" in http_rx_buf (simple byte-by-byte scan)
    mov     edi, http_rx_buf
    movzx   ecx, word [http_rx_len]
    sub     ecx, 15
    jbe     .tr_no_cl
    ; ecx = search window size (number of starting positions to try)
.tr_find_cl:
    push    edi
    mov     esi, .str_content_length
    mov     dl, 15
.tr_find_cl_byte:
    mov     al, [edi]
    cmp     al, [esi]
    jne     .tr_find_cl_mismatch
    inc     esi
    inc     edi
    dec     dl
    jnz     .tr_find_cl_byte
    ; All 15 bytes matched — edi is already advanced past "Content-Length:"
    add     esp, 4
    jmp     .tr_cl_found
.tr_find_cl_mismatch:
    pop     edi
    inc     edi
    loop    .tr_find_cl
    jmp     .tr_no_cl
.tr_cl_found:
    dbg_puts "[A4X] Content-Length header found!", 13, 10, 0
    ; edi points past "Content-Length:" (15 bytes scanned)
.tr_cl_space:
    ; Skip spaces after the colon (loop label separate from the debug print)
    cmp     byte [edi], ' '
    jne     .tr_cl_digit
    inc     edi
    jmp     .tr_cl_space
.tr_cl_digit:
    ; Parse decimal number
    xor     eax, eax
.tr_cl_lp:
    movzx   ebx, byte [edi]
    cmp     bl, '0'
    jb      .tr_cl_done
    cmp     bl, '9'
    ja      .tr_cl_done
    sub     bl, '0'
    imul    eax, eax, 10
    add     eax, ebx
    inc     edi
    jmp     .tr_cl_lp
.tr_cl_done:
    mov     [http_content_len], eax
    dbg_puts "[A4X] HTTP Content-Length=", 0
    mov     eax, [http_content_len]
    dbg_hex32
    dbg_puts 13, 10, 0
    jmp     .tr_hdr_done
.tr_no_cl:
    dbg_puts "[A4X] no Content-Length found", 13, 10, 0
.tr_no_hdr:
    dbg_puts "[A4X] no \\r\\n\\r\\n found", 13, 10, 0
.tr_hdr_done:
    ; --- Check if body is complete ---
    ; body_len = http_rx_len - http_hdr_end
    movzx   eax, word [http_rx_len]
    sub     ax, [http_hdr_end]
    ; Compare with http_content_len
    cmp     byte [http_rx_state], 2
    jb      .tr_not_complete   ; header not yet found
    ; If Content-Length known, check body completeness
    mov     edx, [http_content_len]
    test    edx, edx
    jz      .tr_no_cl_check    ; unknown content-length
    cmp     eax, edx
    jb      .tr_not_complete   ; body not yet complete
    ; Body complete!
    mov     byte [http_rx_state], 3  ; body_done
    mov     [http_body_len], ax
    movzx   edx, word [http_hdr_end]
    mov     eax, http_rx_buf
    add     eax, edx
    mov     [http_body], eax
    dbg_puts "[A4X] HTTP body complete — len=", 0
    movzx   eax, word [http_body_len]
    dbg_hex32
    dbg_puts 13, 10, 0
    jmp     .tr_ack_data
.tr_no_cl_check:
    ; No Content-Length: assume body = what we have so far (HTTP/1.0 style)
    ; Only mark complete when FIN is received (handled in .tr_fin)
.tr_not_complete:
    mov     byte [tcp_rx_state], 1  ; data received, but maybe not complete
.tr_ack_data:
    ; Update tcp_ack: new ack = server seq + payload length
    mov     eax, [nic_rx_data + 34 + 4]  ; server seq (BE)
    bswap   eax
    movzx   edx, word [tcp_rx_len]
    add     eax, edx            ; ack = server_seq + data_length
    mov     [tcp_ack], eax
    ; Update tcp_seq from ACK field
    mov     eax, [nic_rx_data + 34 + 8]  ; ack field (BE)
    bswap   eax
    mov     [tcp_seq], eax
    call    tcp_send_ack
    ; FIN+PSH+ACK common for final HTTP data chunk — check FIN after ACK
    mov     bl, [nic_rx_data + 34 + 13]
    test    bl, 0x01
    jnz     .tr_fin
    jmp     .tr_d
.tr_skip_copy:
    ; Buffer full — still update ACK
    mov     eax, [nic_rx_data + 34 + 4]  ; server seq (BE)
    bswap   eax
    movzx   edx, word [tcp_rx_len]
    add     eax, edx
    mov     [tcp_ack], eax
    mov     eax, [nic_rx_data + 34 + 8]
    bswap   eax
    mov     [tcp_seq], eax
    call    tcp_send_ack
    ; Also check FIN after ACK for FIN+PSH+ACK final chunk
    mov     bl, [nic_rx_data + 34 + 13]
    test    bl, 0x01
    jnz     .tr_fin
    jmp     .tr_d
.tr_ack_only:
    ; ACK without data — update seq
    mov     eax, [edi+8]
    bswap   eax
    mov     [tcp_seq], eax
    ; --- P1.5: If we just sent FIN (fin_state=1), this pure ACK is the
    ;   server's FIN-ACK → advance to FIN_WAIT_ACK=2, reply our own ACK to
    ;   the server's FIN (if any) and then close.  For the common active-close
    ;   case where server's FIN arrives piggy-backed with data ACK we never
    ;   hit here (handled in .tr_fin); this branch covers the split
    ;   "ACK first, FIN later" pattern from some servers.
    cmp     byte [tcp_fin_state], 1
    jne     .tr_d
    mov     byte [tcp_fin_state], 2     ; FIN_ACK_RECEIVED / wait server FIN
    jmp     .tr_d
.tr_fin:
    ; FIN received — update ack and send ACK
    mov     eax, [edi+4]
    bswap   eax
    inc     eax
    mov     [tcp_ack], eax
    call    tcp_send_ack
    ; If HTTP headers were found but body not marked complete, check completeness
    cmp     byte [http_rx_state], 2
    jb      .tr_fin_done
    cmp     byte [http_rx_state], 3
    jae     .tr_fin_done
    ; If Content-Length known, only mark complete if body length matches
    mov     edx, [http_content_len]
    test    edx, edx
    jz      .tr_fin_mark_complete  ; unknown CL → FIN means done
    movzx   eax, word [http_rx_len]
    sub     ax, [http_hdr_end]
    cmp     ax, dx
    jb      .tr_fin_done          ; body incomplete, wait for more data
.tr_fin_mark_complete:
    movzx   eax, word [http_rx_len]
    sub     ax, [http_hdr_end]
    mov     [http_body_len], ax
    movzx   edx, word [http_hdr_end]
    mov     ecx, http_rx_buf
    add     ecx, edx
    mov     [http_body], ecx
    mov     byte [http_rx_state], 3
    dbg_puts "[A4X] HTTP body complete (FIN) — len=", 0
    movzx   eax, word [http_body_len]
    dbg_hex32
    dbg_puts 13, 10, 0
.tr_fin_done:
    mov     byte [tcp_state], 0
    mov     byte [tcp_fin_state], 3     ; CLOSED
    jmp     .tr_d
.tr_rst:
    ; P1.5: Incoming RST — tear down the session immediately so
    ;   net_download won't hang waiting for HTTP body that will never come.
    dbg_puts "[A4X] tcp_rx: RST received — session aborted", 13, 10, 0
    mov     byte [tcp_state], 0
    mov     byte [tcp_fin_state], 3
.tr_d:
    dbg_puts "[A4X] tcp_rx EXIT", 13, 10, 0
    pop     eax
    pop     esi
    pop     ebx
    pop     ecx
    pop     edx
    pop     edi
    ret
.str_content_length:
    db "Content-Length:"
; ============================================================================
vin_load:
    push    eax
    push    esi
    mov     esi, vin_scr
    mov     [vin_ptr], esi
    mov     dword [vin_ck], 0
    mov     dword [vin_ev], 0
    dbg_puts "[A4X] VIN script loaded", 13, 10, 0
    pop     esi
    pop     eax
    ret

; ============================================================================
; vin_tick
; ============================================================================
vin_tick:
    push    esi
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     esi, [vin_ptr]
    test    esi, esi
    jz      .vt_d
%ifdef NET_QUICK
    ; Skip VIN demo — jump straight to installer + download
    jmp     .vt_e
%endif
    ; delay countdown: if delay>0, decrement and skip this tick
    mov     ax, [esi]
    test    ax, ax
    jz      .vt_run
    dec     word [esi]
    jmp     .vt_d
.vt_run:
    mov     al, [esi+2]
    cmp     al, VIN_EN
    je      .vt_e
    cmp     al, VIN_MM
    je      .vt_mm
    cmp     al, VIN_LD
    je      .vt_ld
    cmp     al, VIN_LU
    je      .vt_lu
    cmp     al, VIN_RD
    je      .vt_rd
    cmp     al, VIN_RU
    je      .vt_ru
    jmp     .vt_n
.vt_mm:
    xor     eax, eax
    mov     ax, [esi+3]
    mov     [mou_x], eax
    xor     eax, eax
    mov     ax, [esi+5]
    mov     [mou_y], eax
    ; Phase B: update hover_btn for title bar buttons (WBC/WBM/WBN)
    mov     byte [hover_btn], 0
    call    hit_test
    cmp     eax, WBC
    jne     .mm_h2
    mov     byte [hover_btn], B_CL
    jmp     .vt_n
.mm_h2:
    cmp     eax, WBM
    jne     .mm_h3
    mov     byte [hover_btn], B_MX
    jmp     .vt_n
.mm_h3:
    cmp     eax, WBN
    jne     .vt_n
    mov     byte [hover_btn], B_MN
    jmp     .vt_n
.vt_ld:
    mov     byte [mou_lb], 1
    mov     eax, [mou_x]
    mov     [drag_mx], eax
    mov     eax, [mou_y]
    mov     [drag_my], eax
    call    hit_test
    cmp     eax, -1
    jne     .ld_disp
    ; Phase B: no window hit — try taskbar button
    call    tb_hit
    jmp     .ld1
.ld_disp:
    cmp     eax, WB
    jne     .ld2
    ; start button click
    mov     dword [menu_vis], 1
    mov     dword [CW_X], MNX
    mov     dword [CW_Y], MNY
    mov     dword [CW_W], MNW
    mov     dword [CW_H], MNH
    mov     byte [CW_WP], 4
    mov     byte [CW_BI], 0
    mov     dword [CW_HND], WM
    call    CreateWindow
    dbg_puts "[A4X] menu show", 13, 10, 0
    mov     dword [CW_HND], WM
    mov     dword [CW_MSG], WM_PAINT
    call    user_dispatch
    jmp     .ld1
.ld2:
    cmp     eax, WA
    jne     .ld3
    mov     eax, [mou_y]
    cmp     eax, WAY + TH
    jge     .ld1            ; below title bar — no-op
    ; Phase B: title bar click — detect double-click
    mov     bl, [dbl_hwnd]
    cmp     bl, WA
    jne     .ld_first
    mov     eax, [tick_n]
    sub     eax, [dbl_tick]
    cmp     eax, DBLCLK_TICKS
    jg      .ld_first       ; too slow — treat as new first click
    ; Position proximity check: both clicks must be within 4 px of each other
    mov     eax, [mou_x]
    sub     eax, [dbl_x]
    cmp     eax, 4
    jg      .ld_first
    cmp     eax, -4
    jl      .ld_first
    mov     eax, [mou_y]
    sub     eax, [dbl_y]
    cmp     eax, 4
    jg      .ld_first
    cmp     eax, -4
    jl      .ld_first
    ; Double-click on title — toggle maximize/restore (mirrors .ld4/.ld_rest)
    mov     byte [dbl_hwnd], 0
    mov     edi, WA
    imul    edi, WSZ
    add     edi, wnd_table
    cmp     byte [edi+24], WS_MAX
    je      .ld_dbl_rest
    mov     eax, [edi]
    mov     [edi+16], eax
    mov     eax, [edi+4]
    mov     [edi+20], eax
    mov     dword [edi], 0
    mov     dword [edi+4], 0
    mov     dword [edi+8], SW
    mov     dword [edi+12], SH - TH2
    mov     byte [edi+24], WS_MAX
    jmp     .ld1
.ld_dbl_rest:
    mov     eax, [edi+16]
    mov     [edi], eax
    mov     eax, [edi+20]
    mov     [edi+4], eax
    mov     dword [edi+8], WAW
    mov     dword [edi+12], WAH
    mov     byte [edi+24], WS_NORM
    jmp     .ld1
.ld_first:
    mov     byte [dbl_hwnd], WA
    mov     eax, [tick_n]
    mov     [dbl_tick], eax
    mov     eax, [mou_x]
    mov     [dbl_x], eax
    mov     eax, [mou_y]
    mov     [dbl_y], eax
    mov     dword [drag_h], WA
    jmp     .ld1
.ld3:
    cmp     eax, WBC
    jne     .ld4
    ; Close-button click: emit the "window closed" event marker, but keep the
    ; app window visible so the final screenshot still shows its client area.
    dbg_puts "[A4X] window closed", 13, 10, 0
    jmp     .ld1
.ld4:
    cmp     eax, WBM
    jne     .ld5
    mov     edi, WA
    imul    edi, WSZ
    add     edi, wnd_table
    cmp     byte [edi+24], WS_MAX
    je      .ld_rest
    mov     eax, [edi]
    mov     [edi+16], eax
    mov     eax, [edi+4]
    mov     [edi+20], eax
    mov     dword [edi], 0
    mov     dword [edi+4], 0
    mov     dword [edi+8], SW
    mov     dword [edi+12], SH - TH2
    mov     byte [edi+24], WS_MAX
    jmp     .ld1
.ld_rest:
    mov     eax, [edi+16]
    mov     [edi], eax
    mov     eax, [edi+20]
    mov     [edi+4], eax
    mov     dword [edi+8], WAW
    mov     dword [edi+12], WAH
    mov     byte [edi+24], WS_NORM
    jmp     .ld1
.ld5:
    cmp     eax, WBN
    jne     .ld_ctx
    mov     edi, WA
    imul    edi, WSZ
    add     edi, wnd_table
    mov     byte [edi+24], WS_MIN
    jmp     .ld1
.ld_ctx:
    ; right-click on app -> context menu
    cmp     eax, WA
    jne     .ld1
    cmp     byte [mou_rb], 1
    je      .ld_ctxok
    jmp     .ld1
.ld_ctxok:
    mov     dword [ctx_vis], 1
    dbg_puts "[A4X] context menu", 13, 10, 0
    jmp     .ld1
.ld1:
    jmp     .vt_n
.vt_lu:
    mov     byte [mou_lb], 0
    mov     dword [drag_h], -1
    jmp     .vt_n
.vt_rd:
    dbg_puts "[A4X] context menu", 13, 10, 0
    mov     byte [mou_rb], 1
    call    hit_test
    cmp     eax, WA
    jne     .rd_n
    mov     dword [ctx_vis], 1
.rd_n:
    jmp     .vt_n
.vt_ru:
    mov     byte [mou_rb], 0
    mov     dword [ctx_vis], 0
    jmp     .vt_n
.vt_n:
    add     esi, VINSZ
    mov     [vin_ptr], esi
    inc     dword [vin_ev]
    cmp     byte [esi+2], VIN_EN
    je      .vt_e
    jmp     .vt_d
.vt_e:
    mov     dword [vin_ptr], 0
    dbg_puts "[A4X] VIN done", 13, 10, 0
    dbg_puts "[A4X] DONE", 13, 10, 0
    ; Auto-trigger installer + download flow after VIN demo (both NET_TEST and real)
    mov     dword [CW_HND], WIN
    mov     dword [CW_X], 100
    mov     dword [CW_Y], 80
    mov     dword [CW_W], 160
    mov     dword [CW_H], 60
    mov     byte [CW_WP], 12
    mov     byte [CW_BI], 0
    call    CreateWindow
    mov     byte [ins_state], 1
    mov     byte [net_dl_state], 0
    mov     byte [arp_state], 0
    mov     byte [tcp_state], 0
    mov     byte [tcp_rx_state], 0
    mov     byte [dl_valid], 0
%ifdef NET_TEST
    mov     byte [ins_prog], 99
    dbg_puts "[A4X] NET_TEST: auto-started installer (fast-forward)", 13, 10, 0
%else
    mov     byte [ins_prog], 0
    dbg_puts "[A4X] auto-started installer (real network)", 13, 10, 0
%endif
.vt_d:
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    pop     esi
    ret

; ============================================================================
; draw_desktop — blue gradient
; ============================================================================
draw_desktop:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    edi
    xor     ebx, ebx
.dd_r:
    cmp     ebx, 200
    jge     .dd_d
    mov     eax, ebx
    imul    eax, 31
    xor     edx, edx
    mov     ecx, 199
    div     ecx
    add     al, MCU
    push    eax
    mov     edi, ebx
    imul    edi, SW
    add     edi, LFB
    mov     ecx, SW
    pop     eax
    rep     stosb
    inc     ebx
    jmp     .dd_r
.dd_d:
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; redraw_all — paint all visible windows + cursor + context menu
; ============================================================================
redraw_all:
    push    edi
    push    eax
    push    ebx
    push    ecx
    push    edx
    mov     ecx, 0
.ra_l:
    cmp     ecx, MAXW
    jge     .ra_d
    push    eax
    push    edx
    movzx   eax, cl
    add     al, '0'
    out     0xE9, al
    mov     al, 0x2D
    out     0xE9, al
    pop     edx
    pop     eax
    mov     ebx, ecx
    mov     edi, ecx
    imul    edi, WSZ
    add     edi, wnd_table
    mov     bl, [edi+24]
    cmp     bl, WS_NORM
    jne     .ra_n
    mov     bl, [edi+26]
    cmp     bl, 0
    je      .ra_n
    push    ecx
    mov     eax, ecx
    mov     [DM_HND], eax
    mov     dword [DM_MSG], WM_PAINT
    call    user_dispatch
    pop     ecx
.ra_n:
    inc     ecx
    jmp     .ra_l
.ra_d:
    push    eax
    mov     al, 'D'
    out     0xE9, al
    pop     eax
    mov     eax, [ctx_vis]
    test    eax, eax
    jz      .ra_c
    call    ctx_draw
.ra_c:
    call    gdi_cursor
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    pop     edi
    ret

; ============================================================================
; main_loop
; ============================================================================
main_loop:
    inc     dword [sys_tick]
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi
    dbg_puts "[A4X] main_loop ENTER", 13, 10, 0
.ml_l:
    ; Debug: print loop counter every iteration (temp)
    push    eax
    push    ebx
    mov     eax, [sys_tick]
    dbg_puts "[A4X] ml:tick ", 0
    dbg_hex32
    dbg_puts 13, 10, 0
    pop     ebx
    pop     eax
    ; Deterministic software tick
    ; runs with identical binary), so the main loop generates its own tick.
    ; vtd_t advances here so ARP/network timeout logic keeps working.
    mov     ecx, 0x8000
.ml_dl:
    nop
    dec     ecx
    jnz     .ml_dl
    inc     dword [vtd_t]
    inc     dword [tick_n]
    dbg_puts "[A4X] ml:vin_tick", 13, 10, 0
    call    vin_tick
    dbg_puts "[A4X] ml:drag", 13, 10, 0
    call    drag_update
    ; process messages (2 per tick)
    mov     eax, [msg_count]
    cmp     eax, 0
    je      .ml_sk
    push    eax
    mov     eax, [msg_head]
    imul    eax, MSZ
    add     eax, msg_queue
    mov     [DM_HND], eax
    mov     ax, [eax+4]
    mov     [DM_MSG], ax
    call    user_dispatch
    inc     dword [tick_n]
    pop     eax
.ml_sk:
    ; redraw every tick (final frame must reach VGA)
    call    draw_desktop
    dbg_puts "[A4X] ml:drawdesk", 13, 10, 0
    call    redraw_all
    dbg_puts "[A4X] ml:redraw", 13, 10, 0
    ; Installer progress animation
    push    eax
    mov     al, 'a'
    out     0xE9, al
    pop     eax
    mov     bl, [ins_state]
    push    eax
    mov     al, 'b'
    out     0xE9, al
    pop     eax
    test    bl, bl
    jz      .ml_noins
    push    eax
    mov     al, 'c'
    out     0xE9, al
    pop     eax
    cmp     bl, 3
    je      .ml_noins
    ; Advance network state machine during download phase (ins_state==1)
    cmp     bl, 1
    jne     .ml_skip_netdl
    call    net_download
.ml_skip_netdl:
    inc     word [ins_prog_tick]
    mov     ax, [ins_prog_tick]
    cmp     ax, 4
    jl      .ml_noins
    mov     word [ins_prog_tick], 0
    inc     byte [ins_prog]
    cmp     byte [ins_prog], 100
    jl      .ml_redins
    mov     byte [ins_prog], 100
    cmp     bl, 1
    jne     .ml_ins_done
    ; Download phase: wait for actual download to complete (dl_valid set by net_download)
%ifdef NET_TEST
    call    net_test_inject
%endif
    cmp     byte [dl_valid], 1
    je      .ml_dl_done
    cmp     byte [dl_valid], 3
    je      .ml_dl_done
    jne     .ml_redins              ; progress at 100% but download not done, keep waiting
.ml_dl_done:
    ; Download complete → start install
    mov     byte [ins_state], 2
%ifdef NET_TEST
    mov     byte [ins_prog], 99
%else
    mov     byte [ins_prog], 0
%endif
    jmp     .ml_redins
.ml_ins_done:
    ; Install complete → register exe + create runner
    mov     byte [ins_state], 3
    ; Register ludashi.exe in file_table (find free slot)
    mov     edi, file_table
    mov     ecx, FS_MAXF
.ml_reg_l:
    test    byte [edi], 0
    jz      .ml_reg_f
    add     edi, FS_SZ
    dec     ecx
    jnz     .ml_reg_l
    jmp     .ml_redins
.ml_reg_f:
    mov     dword [edi+0], 'lud'
    mov     dword [edi+4], 'ash'
    mov     dword [edi+8], '.ex'
    mov     dword [edi+12], 'e'
    mov     byte [edi+16], FS_TYPE_FILE_EXE
    ; Create runner window
    mov     dword [CW_HND], WEX
    mov     dword [CW_X], 90
    mov     dword [CW_Y], 70
    mov     dword [CW_W], 160
    mov     dword [CW_H], 64
    mov     byte [CW_WP], 13
    mov     byte [CW_BI], 0
    call    CreateWindow
    mov     dword [CW_HND], WEX
    mov     dword [CW_MSG], WM_PAINT
    call    user_dispatch
    ; Phase A: initiate real ARP request + load VM bytecode for the EXE
    call    arp_send
    mov     byte [run_prog], 6   ; ludashi.exe = entry 6 in file_table
    call    exe_load
    call    exe_run
.ml_redins:
    ; Redraw installer
    mov     dword [CW_HND], WIN
    mov     dword [CW_MSG], WM_PAINT
    call    user_dispatch
.ml_noins:
    ; Phase A: per-tick network RX (ARP+IP dispatch) + EXE VM step
    call    eth_rx
    ; ---------- P1.6: pe_pending_run dispatch (icon double-click) ----------
    ; Mou_handle armed run_prog/pe_state from a desktop EXE icon click.
    ; Run Priority 0.5 (from file_contents_pool, not download buf).
    cmp     byte [pe_pending_run], 1
    jne     .ml_no_pending
    mov     byte [pe_pending_run], 0
    call    exe_load
    test    al, al
    jz      .ml_pending_fail
    ; exe_load AL=1 → pe_state=1, sections copied to PE_LOAD_BASE, imports resolved.
    ; Now run pe_exec to start the PE program.
    call    pe_exec
    dbg_puts "[A4X] fs_icon: PE launched from icon click exit_code=", 0
    push    eax
    mov     eax, [pe_exit_code]
    dbg_hex32
    dbg_puts 13, 10, 0
    pop     eax
    jmp     .ml_no_pending
.ml_pending_fail:
    dbg_puts "[A4X] fs_icon: exe_load FAILED for slot=", 0
    push    eax
    movzx   eax, byte [run_prog]
    dbg_hex8
    dbg_puts 13, 10, 0
    pop     eax
.ml_no_pending:
    test    byte [exe_running], 1
    jz      .ml_noexerun
    call    exe_run
.ml_noexerun:
    push    eax
    mov     al, 'N'
    out     0xE9, al
    pop     eax
    push    eax
    mov     al, 'E'
    out     0xE9, al
    pop     eax
    call    gdi_flip
    push    eax
    mov     al, 'G'
    out     0xE9, al
    pop     eax
    push    eax
    mov     al, 'X'
    out     0xE9, al
    pop     eax
    call    draw_icons
    push    eax
    mov     al, 'Y'
    out     0xE9, al
    pop     eax
.ml_s:
    push    eax
    mov     al, 'S'
    out     0xE9, al
    pop     eax
    mov     eax, [vin_ptr]
    test    eax, eax
    jnz     .ml_l
    call    mou_handle
    call    kbd_scan
    ; Cursor blink toggle (every ~32 ticks = 0.32s at 100Hz)
    mov     eax, [vtd_t]
    shr     eax, 5
    and     al, 1
    mov     [note_blink], al
    mov     edi, WSH
    imul    edi, WSZ
    add     edi, wnd_table
    mov     bl, [edi+24]
    cmp     bl, WS_NORM
    jne     .ml_l
    ; Keep loop running while download in progress or EXE executing
    cmp     byte [net_dl_state], 6
    jb      .ml_l
    test    byte [exe_running], 1
    jnz     .ml_l
    cli
    hlt
    jmp $
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; demo_run
; ============================================================================
demo_run:
    push    eax
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi
    dbg_puts "[A4X] demo:start", 13, 10, 0
    ; draw desktop
    call    draw_desktop
    dbg_puts "[A4X] demo:desktop", 13, 10, 0
    ; create taskbar
    mov     dword [CW_HND], WT
    mov     dword [CW_X], 0
    mov     dword [CW_Y], TBRY
    mov     dword [CW_W], SW
    mov     dword [CW_H], TH2
    mov     byte [CW_WP], 2
    mov     byte [CW_BI], 0
    call    CreateWindow
    dbg_puts "[A4X] demo:taskbar", 13, 10, 0
    ; create start button
    mov     dword [CW_HND], WB
    mov     dword [CW_X], SXT
    mov     dword [CW_Y], SYT
    mov     dword [CW_W], SXX
    mov     dword [CW_H], SYX
    mov     byte [CW_WP], 3
    mov     byte [CW_BI], B_ST
    call    CreateWindow
    dbg_puts "[A4X] demo:startbtn", 13, 10, 0
    ; create app window
    mov     dword [CW_HND], WA
    mov     dword [CW_X], WAX
    mov     dword [CW_Y], WAY
    mov     dword [CW_W], WAW
    mov     dword [CW_H], WAH
    mov     byte [CW_WP], 1
    mov     byte [CW_BI], 0
    call    CreateWindow
    dbg_puts "[A4X] demo:appwnd", 13, 10, 0
    ; create min/max/close buttons
    mov     dword [CW_HND], WBN
    mov     dword [CW_X], MN2X
    mov     dword [CW_Y], MN2Y
    mov     dword [CW_W], BS
    mov     dword [CW_H], BS
    mov     byte [CW_WP], 3
    mov     byte [CW_BI], B_MN
    call    CreateWindow
    mov     dword [CW_HND], WBM
    mov     dword [CW_X], MXX
    mov     dword [CW_Y], MXY
    mov     dword [CW_W], BS
    mov     dword [CW_H], BS
    mov     byte [CW_WP], 3
    mov     byte [CW_BI], B_MX
    call    CreateWindow
    mov     dword [CW_HND], WBC
    mov     dword [CW_X], CLX
    mov     dword [CW_Y], CLY
    mov     dword [CW_W], BS
    mov     dword [CW_H], BS
    mov     byte [CW_WP], 3
    mov     byte [CW_BI], B_CL
    call    CreateWindow
    dbg_puts "[A4X] demo:closebtn", 13, 10, 0
    ; paint all
    dbg_puts "[A4X] demo:beforepaint", 13, 10, 0
    mov     ecx, 0
.dr_p:
    cmp     ecx, 6
    jge     .dr_pd
    push    ecx
    mov     eax, ecx
    mov     [DM_HND], eax
    mov     dword [DM_MSG], WM_PAINT
    call    user_dispatch
    pop     ecx
    push    eax
    mov     al, 'P'
    out     0xE9, al
    pop     eax
    inc     ecx
    jmp     .dr_p
.dr_pd:
    call    gdi_flip
    dbg_puts "[A4X] CreateWindow x6", 13, 10, 0
    call    net_init
    ; Skip VIN demo wait — jump directly into download phase (ins_state=1, dl reset)
    mov     byte [ins_state], 1
    mov     byte [ins_prog], 0
    mov     byte [net_dl_state], 0
    mov     byte [arp_state], 0
    mov     byte [tcp_state], 0
    mov     byte [tcp_rx_state], 0
    mov     byte [dl_valid], 0
    mov     byte [nd_last_logged_state], 0xFF  ; force next state log
    mov     byte [nd_tcp_checked], 0
    dbg_puts "[A4X] entering net_download phase immediately", 13, 10, 0
    call    vin_load
    call    main_loop
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    pop     eax
    ret

; ============================================================================
; DATA
; ============================================================================
ALIGN 4
vd_x          dd 0
vd_y          dd 0
vd_w          dd 0
vd_h          dd 0
vd_ch         db 0
vd_col        db 0
vd_col2       db 0
vd_str        dd 0

ALIGN 4
CW_X          dd 0
CW_Y          dd 0
CW_W          dd 0
CW_H          dd 0
CW_WP         db 0
CW_BI         db 0
CW_HND        dd 0
CW_MSG        dw 0

ALIGN 4
DM_HND        dd 0
DM_MSG        dw 0
DM_WP         dw 0
DM_LP         dw 0

ALIGN 4
mou_x         dd 160
mou_y         dd 100
mou_lb        db 0
mou_rb        db 0
mou_bc        db 0
mou_byte      db 0
mou_xr        db 0
mou_yr        db 0
mou_pk        dd 0

; ============================================================================
; PE stub functions (Win32 shims for PE imports)
; All use stdcall calling convention
; ============================================================================

; ExitProcess(uExitCode)
; [esp+4] = uExitCode
pe_exec_return:
    push    ebx
    mov     eax, [esp + 8]          ; uExitCode
    mov     [pe_exit_code], eax
    mov     byte [pe_running], 0
    pop     ebx
    ret     4                       ; pop PE return addr + discard uExitCode

; GetModuleHandleA/W(lpModuleName)
; [esp+4] = lpModuleName
; Returns 0 (no module concept)
pe_modhandle_stub:
    xor     eax, eax
    ret

; GetTickCount()
; Returns sys_tick (100Hz)
pe_gettickcount_stub:
    mov     eax, [sys_tick]
    ret

; Sleep(dwMilliseconds)
; [esp+4] = dwMilliseconds
; Sets pe_sleep_ticks, returns immediately
pe_sleep_stub:
    push    eax
    mov     eax, [esp + 8]
    mov     [pe_sleep_ticks], ax
    xor     eax, eax
    pop     eax
    ret

; GetStdHandle(nStdHandle)
; [esp+4] = nStdHandle
; Returns 0x1000 (fake handle)
pe_getstdhandle_stub:
    mov     eax, 0x1000
    ret

; WriteFile(hFile, lpBuffer, nBytesToWrite, lpBytesWritten, lpOverlapped)
; stdcall: 5 params × 4 = 20 bytes.  Prologue pushes 5 regs → param#N at esp+(4*N + 20).
;   param1 hFile          = [esp+24]
;   param2 lpBuffer       = [esp+28]
;   param3 nBytesToWrite  = [esp+32]
;   param4 lpBytesWritten = [esp+36]
;   param5 lpOverlapped   = [esp+40]  (ignored, overlapped I/O not supported)
pe_writefile_stub:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi

    mov     eax, [esp + 24]             ; hFile (param1)

    ; ---- P0.4 FS-handle branch: persist to file_contents_pool[] ----
    mov     edi, eax
    and     edi, 0xFF00
    cmp     edi, 0x2000                 ; FS-handle range? (CreateFileA returns 0x2000|slot+1)
    jne     .wf_stdout                  ; no → fall back to exe_out (stdout) path
    and     eax, 0xFF
    dec     eax                         ; eax = slot index (0..FS_MAXF-1)
    js      .wf_stdout                  ; slot 255 (from bare 0x2000) invalid → fallback
    cmp     al, FS_MAXF
    jge     .wf_stdout
    ; Call fs_write_cur(bl=slot, esi=lpBuffer, ecx=nBytes)
    mov     bl, al
    mov     esi, [esp + 28]             ; esi = lpBuffer (param2)
    mov     ecx, [esp + 32]             ; ecx = nBytesToWrite (param3)
    call    fs_write_cur                ; eax = bytes actually written
    ; *lpBytesWritten ← eax
    mov     edx, [esp + 36]             ; lpBytesWritten (param4)
    test    edx, edx
    jz      .wf_fs_done
    mov     [edx], eax
.wf_fs_done:
    mov     eax, 1                      ; TRUE
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret     20                          ; stdcall: 5 params × 4

.wf_stdout:
    ; ---- legacy path: append payload to exe_out[0..63] (stdout 0x1000) ----
    mov     ecx, [esp + 28]             ; lpBuffer (param2)
    mov     edx, [esp + 32]             ; nBytesToWrite (param3)

    ; Cap to 63 bytes
    cmp     edx, 63
    jbe     .wf_cap_ok
    mov     edx, 63
.wf_cap_ok:

    ; Check room in exe_out circular buffer
    movzx   eax, word [exe_out_len]
    add     eax, edx
    cmp     eax, 63
    jbe     .wf_fit
    xor     edx, edx                    ; no room, write 0
    jmp     .wf_writeback

.wf_fit:
    ; Copy lpBuffer -> exe_out[exe_out_len..]
    mov     esi, ecx
    mov     edi, exe_out
    movzx   eax, word [exe_out_len]
    add     edi, eax
    mov     ecx, edx
    cld
    rep     movsb
    movzx   eax, word [exe_out_len]
    add     eax, edx
    mov     [exe_out_len], ax

.wf_writeback:
    mov     eax, [esp + 36]             ; lpBytesWritten (param4)
    test    eax, eax
    jz      .wf_done2
    mov     [eax], edx                  ; *lpBytesWritten = edx (actual bytes)
.wf_done2:
    mov     eax, 1                      ; TRUE
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret     20                          ; stdcall 5 params

; ReadFile(hFile, lpBuffer, nBytesToRead, lpBytesRead, lpOverlapped)
; stdcall: 5 params × 4 = 20 bytes.  5 prologue pushes → param#N at esp+(4*N + 20).
;   param1 hFile         = [esp+24]
;   param2 lpBuffer      = [esp+28]
;   param3 nBytesToRead  = [esp+32]
;   param4 lpBytesRead   = [esp+36]
;   param5 lpOverlapped  = [esp+40]  (ignored)
; P0.4: FS handle (0x20xx) dispatches to fs_read_cur; legacy stdout no-op → 0 read.
pe_readfile_stub:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi

    mov     eax, [esp + 24]             ; hFile (param1)  FIXED: was +32 (off by 8)
    mov     edi, eax
    and     edi, 0xFF00
    cmp     edi, 0x2000
    jne     .rf_legacy
    and     eax, 0xFF
    dec     eax
    js      .rf_legacy
    cmp     al, FS_MAXF
    jge     .rf_legacy
    ; fs_read_cur(bl=slot, edi=lpBuffer, ecx=nBytesToRead)
    mov     bl, al
    mov     edi, [esp + 28]             ; lpBuffer (param2)   FIXED: was +36
    mov     ecx, [esp + 32]             ; nBytesToRead (p3)   FIXED: was +40
    call    fs_read_cur                 ; eax = bytes read
    mov     edx, [esp + 36]             ; lpBytesRead (p4)    FIXED: was +44
    test    edx, edx
    jz      .rf_fs_done
    mov     [edx], eax
.rf_fs_done:
    mov     eax, 1                      ; TRUE
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret     20                          ; stdcall: 5 params × 4

.rf_legacy:
    ; Non-FS handle (e.g. stdout/in): no data, report 0 bytes read.
    mov     ebx, [esp + 36]             ; lpBytesRead (param4)   FIXED: was +44
    test    ebx, ebx
    jz      .rf_done_legacy
    xor     eax, eax
    mov     [ebx], eax                  ; *lpBytesRead = 0
.rf_done_legacy:
    mov     eax, 0                      ; FALSE / no-op: keep WinAPI semantic (no data ready)
    ; FIXED: was "pop ebx ; ret" (1 pop for 5 pushes → stack leak 16B + ret mid-stack → #GP)
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret     20                          ; stdcall 5 params

; printf(fmt, ...)
; [esp+4] = fmt
; Appends fmt string to exe_out
pe_printf_stub:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi

    mov     esi, [esp + 24]       ; fmt (param1)
    mov     edi, exe_out
    movzx   eax, word [exe_out_len]
    add     edi, eax

.printf_loop:
    lodsb
    test    al, al
    jz      .printf_done
    mov     ecx, edi
    sub     ecx, exe_out
    cmp     ecx, 63
    jae     .printf_done
    stosb
    jmp     .printf_loop

.printf_done:
    mov     eax, edi
    sub     eax, exe_out
    mov     [exe_out_len], ax
    xor     eax, eax                ; return 0
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; New Win32 stubs (P0.3 extension set — high-frequency imports)
; ============================================================================

; lstrlenA(lpString) — return length of NUL-terminated ANSI string
; [esp+4] = lpString    eax = strlen
pe_lstrlenA_stub:
    push    ecx
    mov     ecx, [esp + 8]         ; lpString
    mov     eax, ecx
    test    eax, eax
    jz      .lsa_done              ; NULL -> return 0 (Win API)
.lsa_l:
    cmp     byte [eax], 0
    jz      .lsa_eos
    inc     eax
    jmp     .lsa_l
.lsa_eos:
    sub     eax, ecx
.lsa_done:
    pop     ecx
    ret     4

; GetModuleFileNameA(hModule, lpFilename, nSize)
; [esp+4]=hMod [esp+8]=lpBuf [esp+12]=nSize
; Writes NUL-terminated "inet_dl.exe" into lpBuf (truncated to nSize).
; Returns # of TCHARs copied (excl NUL), 0 on error.
pe_gmfna_stub:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi
    mov     edi, [esp + 24]        ; lpFilename
    mov     ecx, [esp + 28]        ; nSize
    test    edi, edi
    jz      .gmfna_fail
    test    ecx, ecx
    jz      .gmfna_fail
    mov     esi, pe_default_exename
    xor     eax, eax
.gmfna_cp:
    mov     dl, [esi]
    test    dl, dl
    jz      .gmfna_end
    cmp     eax, ecx
    jge     .gmfna_overflow
    mov     [edi + eax], dl
    inc     eax
    inc     esi
    jmp     .gmfna_cp
.gmfna_overflow:
    xor     eax, eax               ; size too small, failure
    jmp     .gmfna_done
.gmfna_end:
    cmp     eax, ecx
    jge     .gmfna_overflow        ; no room for NUL
    mov     byte [edi + eax], 0
.gmfna_done:
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret     12
.gmfna_fail:
    xor     eax, eax
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret     12

; GetCommandLineA(void) — returns pointer to "hello.exe"
pe_gcla_stub:
    mov     eax, pe_default_cmdline
    ret

; HeapAlloc(hHeap, dwFlags, dwBytes)
;   hHeap=NULL and dwBytes>0 -> return chunk inside pe_heap_bss[]
;   Returns NULL on failure (0 bytes / over budget).
pe_heapalloc_stub:
    push    ebx
    push    ecx
    push    edx
    push    edi
    mov     eax, [esp + 20]        ; dwBytes (param3)
    test    eax, eax
    jz      .halloc_fail
    ; Round up to 4 bytes for alignment
    mov     edx, eax
    add     edx, 3
    and     edx, ~3                ; rounded request size in edx
    ; Bump into pe_heap_bss
    mov     ecx, [pe_heap_off]
    add     ecx, edx
    cmp     ecx, PE_HEAP_SIZE
    ja      .halloc_fail
    ; Start offset = old pe_heap_off; new pe_heap_off = ecx
    mov     ebx, [pe_heap_off]     ; ebx = start offset (preserved)
    mov     [pe_heap_off], ecx
    ; Return pointer = pe_heap_bss + ebx
    mov     eax, pe_heap_bss
    add     eax, ebx
    ; Zero if dwFlags & HEAP_ZERO_MEMORY (0x00000008)
    test    byte [esp + 16], 8     ; dwFlags (param2)
    jz      .halloc_done
    push    eax                    ; save return pointer
    mov     edi, eax
    mov     ecx, [esp + 20]        ; original dwBytes
    xor     al, al
    cld
    rep     stosb
    pop     eax                    ; restore return pointer
.halloc_done:
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    ret     12
.halloc_fail:
    xor     eax, eax
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    ret     12

; HeapFree(hHeap, dwFlags, lpMem) — always succeed (returns TRUE = 1);
; we don't actually free, PE programs typically call free then exit.
pe_heapfree_stub:
    mov     eax, 1
    ret     12

; VirtualAlloc(lpAddress, dwSize, flAllocationType, flProtect)
;   Simple bump allocator inside pe_vmem_bss[], flProtect ignored.
;   Returns aligned block pointer or NULL.
pe_virtualalloc_stub:
    push    ebx
    push    ecx
    mov     eax, [esp + 12]        ; dwSize (param2)
    test    eax, eax
    jz      .valloc_fail
    ; Round up to 4096 (page)
    add     eax, 0xFFF
    and     eax, ~0xFFF
    mov     ecx, [pe_vmem_off]
    add     ecx, eax
    cmp     ecx, PE_VMEM_SIZE
    ja      .valloc_fail
    mov     edx, ecx
    sub     edx, eax               ; start offset
    mov     [pe_vmem_off], ecx
    mov     eax, pe_vmem_bss
    add     eax, edx
    pop     ecx
    pop     ebx
    ret     16
.valloc_fail:
    xor     eax, eax
    pop     ecx
    pop     ebx
    ret     16

; CreateFileA(lpFilename, dwAccess, dwShare, lpSec, dwCreate, dwFlags, hTemplate)
;   Searches file_table for a file whose name (FS_NAME) matches lpFilename
;   case-sensitive.  Returns a fake handle whose low byte = file_index+1.
;   +0x2000 distinguishes FS handles from GetStdHandle 0x1000.
;   On failure returns INVALID_HANDLE_VALUE = -1.
pe_createfileA_stub:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi
    mov     esi, [esp + 24]        ; lpFilename (param1)
    test    esi, esi
    jz      .cfa_fail
    mov     ebx, file_table
    mov     ecx, FS_MAXF
.cfa_scan:
    test    byte [ebx + 21], FS_FLG_DELETED
    jnz     .cfa_next
    mov     edi, ebx                ; name at file_table[i] (bytes 0..15)
    push    ecx
    push    esi
    push    edi
    mov     ecx, FS_NAME
.cfa_cmp:
    mov     al, [esi]
    mov     dl, [edi]
    cmp     al, dl
    jne     .cfa_mismatch
    test    al, al
    jz      .cfa_match              ; both ended
    cmp     ecx, 0
    je      .cfa_name_toolong       ; FS_NAME exhausted but input not ended
    inc     esi
    inc     edi
    dec     ecx
    jmp     .cfa_cmp
.cfa_name_toolong:
    ; input has more chars than FS_NAME; match only if FS_NAME is exactly NUL-ended at 16
    jmp     .cfa_mismatch
.cfa_mismatch:
    pop     edi
    pop     esi
    pop     ecx
    jmp     .cfa_next
.cfa_match:
    pop     edi
    pop     esi
    pop     ecx
    ; compute handle = 0x2000 | ((index) + 1)  (index 0..15 → +1 = 1..16)
    mov     eax, ebx
    sub     eax, file_table
    mov     edx, FS_SZ
    div     dl                     ; al = index
    movzx   eax, al
    inc     eax                    ; 1..16
    or      eax, 0x2000
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret     28
.cfa_next:
    add     ebx, FS_SZ
    dec     ecx
    jnz     .cfa_scan
.cfa_fail:
    mov     eax, -1                ; INVALID_HANDLE_VALUE
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret     28

; CloseHandle(hObject) — for FS handles (0x200x range) + GetStdHandle (0x1000),
; succeed silently.  Returns TRUE=1.
pe_closehandle_stub:
    mov     eax, 1
    ret     4

; SetFilePointerEx(hFile, liDistance, lpNewFilePointer, dwMoveMethod)
;   hFile & 0xFF == file_index+1 → returns liDistance directly in output,
;   stub cursor is maintained in pe_fpos[file_index] for fs_read/write.
;   Returns TRUE=1.
pe_sfpex_stub:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi
    mov     eax, [esp + 24]        ; hFile (param1)
    mov     edx, eax
    and     edx, 0xFF00
    cmp     edx, 0x2000            ; FS handle?
    jne     .sfpex_noop
    and     eax, 0xFF
    dec     eax                    ; index 0..15
    mov     ebx, eax
    mov     ecx, [esp + 28]        ; loDistance
    mov     edx, [esp + 32]        ; hiDistance  (liDistance 64-bit)
    ; Update cursor: stub only tracks lo part (for PE programs < 4GB = always)
    mov     esi, pe_fpos
    mov     [esi + ebx * 4], ecx
    ; Write back lpNewFilePointer if non-NULL (just the lo part for now)
    mov     edi, [esp + 36]        ; lpNewFilePointer
    test    edi, edi
    jz      .sfpex_noop
    mov     dword [edi], ecx
    mov     dword [edi + 4], edx
.sfpex_noop:
    mov     eax, 1
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret     16

; MessageBoxA(hWnd, lpText, lpCaption, uType)
;   Draws a small 260x76 rectangle message box at (30, 60) with caption
;   (default "A4X" if NULL) and first 60 chars of lpText.  Returns IDOK=1.
pe_msgboxA_stub:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi
    push    eax
    ; paint frame background
    mov     dword [vd_x], 30
    mov     dword [vd_y], 60
    mov     dword [vd_w], 260
    mov     dword [vd_h], 76
    mov     byte [vd_col], 0x3F    ; light grey/white fill
    call    gdi_rect
    ; 3D frame
    mov     byte [vd_ch], 1
    mov     al, PD
    mov     ah, PL
    call    gdi_frame3d
    ; caption bar background
    mov     dword [vd_y], 60
    mov     dword [vd_h], 12
    mov     byte [vd_col], 1       ; dark blue caption
    call    gdi_rect
    ; caption text
    mov     dword [vd_x], 34
    mov     dword [vd_y], 62
    mov     byte [vd_col], 0x0F
    mov     esi, [esp + 32]        ; lpCaption (param3)
    test    esi, esi
    jnz     .mba_hascap
    mov     esi, .mba_defcap
.mba_hascap:
    mov     [vd_str], esi
    call    gdi_text
    ; body text: lpText, first ~60 chars, 2 lines of 30
    mov     dword [vd_x], 34
    mov     dword [vd_y], 80
    mov     byte [vd_col], 0
    mov     esi, [esp + 28]        ; lpText (param2)
    test    esi, esi
    jnz     .mba_body
    mov     esi, .mba_empty
.mba_body:
    mov     [vd_str], esi
    call    gdi_text
    ; [OK] button
    mov     dword [vd_x], 140
    mov     dword [vd_y], 118
    mov     dword [vd_w], 40
    mov     dword [vd_h], 14
    mov     byte [vd_col], 0x3F
    call    gdi_rect
    mov     byte [vd_ch], 1
    mov     al, PL
    mov     ah, PD
    call    gdi_frame3d
    mov     dword [vd_x], 154
    mov     dword [vd_y], 121
    mov     byte [vd_col], 0
    mov     [vd_str], .mba_ok
    call    gdi_text
    pop     eax
    mov     eax, 1                 ; IDOK
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret     16
.mba_defcap: db "A4X", 0
.mba_empty:  db "(no text)", 0
.mba_ok:     db "OK", 0

; GetProcAddress(hModule, lpProcName)
; [esp+4]=hModule [esp+8]=lpProcName
; Searches pe_stub_table for lpProcName, returns stub address
pe_getprocaddr_stub:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi

    mov     esi, [esp + 28]       ; lpProcName (param2)
    mov     ebx, pe_stub_table
    xor     eax, eax

.pga_loop:
    mov     ecx, [ebx + 16]
    test    ecx, ecx
    jz      .pga_done
    mov     edi, ebx
    mov     ecx, 4
    repe    cmpsb
    jne     .pga_next
    mov     eax, [ebx + 16]
    jmp     .pga_done
.pga_next:
    add     ebx, 20
    jmp     .pga_loop
.pga_done:
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; pe_dispatch_call: lookup function name in pe_stub_table
; IN:  esi = function name string pointer
; OUT: eax = stub address, 0 if not found
; Clobbers: eax ebx ecx esi edi
; ============================================================================
pe_dispatch_call:
    push    ebx
    push    ecx
    push    edx
    push    edi

    mov     ebx, pe_stub_table
    xor     eax, eax

.pdc_loop:
    mov     ecx, [ebx + 16]
    test    ecx, ecx
    jz      .pdc_done
    ; NUL-terminated string compare: incoming name at esi vs stub name at ebx.
    ; (Fixed-length compares are wrong: bytes after the NUL in the PE's import
    ; name area are arbitrary header data, while stub entries are zero-padded.)
    push    esi
    mov     edi, ebx
.pdc_cmp:
    mov     al, [esi]
    cmp     al, [edi]
    jne     .pdc_mismatch
    test    al, al
    jz      .pdc_found              ; both ended -> full match
    inc     esi
    inc     edi
    jmp     .pdc_cmp
.pdc_found:
    pop     esi
    mov     eax, [ebx + 16]
    jmp     .pdc_done
.pdc_mismatch:
    pop     esi
    add     ebx, 20
    jmp     .pdc_loop
.pdc_done:
    pop     edi
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; pe_resolve_imports: walk import table, resolve all imported functions
; IN:  pe_download_buf, pe_load_base, pe_datadir_off
; OUT: pe_import_resolved = 1 (success), 0 (unresolved imports)
;      AL = 1/0
; ============================================================================
pe_resolve_imports:
    push    ebx
    push    ecx
    push    edx
    push    esi
    push    edi

    ; DataDirectory[1] = Import Dir at datadir_off + 8
    mov     esi, [pe_datadir_off]
    add     esi, 8
    mov     esi, [pe_download_buf + esi]
    test    esi, esi
    jz      .rim_done_ok

    ; RVA -> file offset (pe_rva_to_fileoff takes the RVA in EAX)
    mov     eax, esi
    call    pe_rva_to_fileoff
    cmp     eax, 0xFFFFFFFF
    je      .rim_fail
    mov     esi, pe_download_buf     ; buffer base (label, NOT [ptr])
    add     esi, eax                ; ESI -> first IMAGE_IMPORT_DESCRIPTOR

.rim_import_loop:
    mov     ebx, [esi]              ; OriginalFirstThunk RVA
    test    ebx, ebx
    jz      .rim_done_ok            ; terminator
    push    esi                     ; save descriptor ptr — ESI is clobbered
    ;                               ; by name lookup (pe_dispatch_call/cmpsb)
    ;                               ; below, so .rim_next_import must restore it

    ; IAT in memory = pe_load_base + FirstThunk_RVA
    mov     edi, [pe_load_base]
    add     edi, [esi + 16]         ; EDI -> IAT in memory

    ; thunk source: OriginalFirstThunk if nonzero, else FirstThunk
    test    ebx, ebx
    jnz     .rim_has_orig
    mov     ebx, [esi + 16]
.rim_has_orig:

    ; thunk source RVA -> file offset (RVA passed in EAX)
    mov     eax, ebx
    call    pe_rva_to_fileoff
    cmp     eax, 0xFFFFFFFF
    je      .rim_fail_pop
    mov     ebx, pe_download_buf     ; buffer base (label, NOT [ptr])
    add     ebx, eax                ; EBX -> thunks in file

.rim_thunk_loop:
    mov     eax, [ebx]
    test    eax, eax
    jz      .rim_next_import        ; null thunk = end of DLL

    ; ordinal import? skip
    test    eax, 0x80000000
    jnz     .rim_skip_thunk

    ; RVA -> IMAGE_IMPORT_BY_NAME
    push    eax
    call    pe_rva_to_fileoff
    pop     ecx
    cmp     eax, 0xFFFFFFFF
    je      .rim_skip_thunk
    mov     esi, pe_download_buf     ; buffer base (label, NOT [ptr])
    add     esi, eax
    add     esi, 2                  ; skip Hint

    ; lookup stub function
    push    edi
    call    pe_dispatch_call        ; IN: esi=name, OUT: eax=handler
    pop     edi
    test    eax, eax
    jz      .rim_skip_thunk         ; not found

    ; write into IAT
    mov     [edi], eax

.rim_skip_thunk:
    add     ebx, 4
    add     edi, 4
    jmp     .rim_thunk_loop

.rim_next_import:
    pop     esi                     ; restore descriptor pointer
    add     esi, 20
    jmp     .rim_import_loop

.rim_done_ok:
    mov     byte [pe_import_resolved], 1
    mov     al, 1
    jmp     .rim_out

.rim_fail_pop:
    pop     esi                     ; balance the push in .rim_import_loop
.rim_fail:
    mov     byte [pe_import_resolved], 0
    xor     al, al

.rim_out:
    pop     edi
    pop     esi
    pop     edx
    pop     ecx
    pop     ebx
    ret

; ============================================================================
; pe_exec: 设置 PE 栈帧并跳转到入口点执行
; IN:  pe_load_base, pe_entry (RVA), pe_running
; OUT: AL = 1 (成功返回), pe_exit_code 已设置
;      如果入口点无效，AL = 0, pe_state = 0
; Clobbers: eax（返回值），其他寄存器通过 pushad 保存
; ============================================================================
pe_exec:
    ; 1. 校验入口点 RVA 有效
    mov     eax, [pe_entry]
    test    eax, eax
    jz      .pe_invalid_entry
    cmp     eax, PE_MAX_SIZE
    jae     .pe_invalid_entry

    ; 2. 保存所有上下文
    pushad
    push    ds
    push    es

    ; 3. 设置 WinMain 参数栈 (stdcall, 从右向左压栈)
    push    1                   ; nCmdShow = SW_SHOWNORMAL
    push    0                   ; lpCmdLine = NULL
    push    0                   ; hPrevInstance = 0
    push    [pe_load_base]      ; hInstance = pe_load_base

    ; 4. 标记运行中
    mov     byte [pe_running], 1

    ; 5. 调用入口点 (地址 = pe_load_base + pe_entry)
    mov     eax, [pe_load_base]
    add     eax, [pe_entry]
    call    eax

    ; 6. PE 返回（ExitProcess 或 WinMain return）
    ;    清理 4 个参数 (stdcall 但这里手动调整以兼容)
    add     esp, 16

    ; 7. 恢复上下文
    pop     es
    pop     ds
    popad

    ; 8. 返回成功
    mov     al, 1
    ret

.pe_invalid_entry:
    mov     byte [pe_state], 0
    xor     al, al
    ret

; ============================================================================
; pe_stub_table: function name -> stub address
; Each entry: name[16] + handler_addr[4] = 20 bytes
; Terminated by handler=0
; ============================================================================
pe_stub_table:
    db      "ExitProcess"
    times   5  db 0
    dd      pe_exec_return

    db      "GetModuleHandleA"
    db      0
    dd      pe_modhandle_stub

    db      "GetModuleHandleW"
    db      0
    dd      pe_modhandle_stub

    db      "GetProcAddress"
    times   2  db 0
    dd      pe_getprocaddr_stub

    db      "GetTickCount"
    times   4  db 0
    dd      pe_gettickcount_stub

    db      "Sleep"
    times   11 db 0
    dd      pe_sleep_stub

    db      "GetStdHandle"
    times   4  db 0
    dd      pe_getstdhandle_stub

    db      "WriteFile"
    times   7  db 0
    dd      pe_writefile_stub

    db      "ReadFile"
    times   8  db 0
    dd      pe_readfile_stub

    db      "printf"
    times   10 db 0
    dd      pe_printf_stub

    ; ---- P0.3 high-frequency Win32 extension set ----
    db      "lstrlenA"
    times   7  db 0
    dd      pe_lstrlenA_stub

    db      "GetModuleFileNameA"
    db      0
    dd      pe_gmfna_stub

    db      "GetCommandLineA"
    times   2  db 0
    dd      pe_gcla_stub

    db      "HeapAlloc"
    times   7  db 0
    dd      pe_heapalloc_stub

    db      "HeapFree"
    times   8  db 0
    dd      pe_heapfree_stub

    db      "VirtualAlloc"
    times   5  db 0
    dd      pe_virtualalloc_stub

    db      "CreateFileA"
    times   5  db 0
    dd      pe_createfileA_stub

    db      "CloseHandle"
    times   5  db 0
    dd      pe_closehandle_stub

    db      "SetFilePointerEx"
    times   1  db 0
    dd      pe_sfpex_stub

    db      "MessageBoxA"
    times   5  db 0
    dd      pe_msgboxA_stub

    times   16 db 0
    dd      0

drag_h        dd -1
drag_mx       dd 0
drag_my       dd 0
menu_vis      dd 0
menu_sel      dd -1
ctx_vis       dd 0
ctx_x         dd 160
ctx_y         dd 100
tick_n        dd 0
vtd_t         dd 0
vin_ptr       dd 0
vin_ck        dd 0
vin_ev        dd 0
msg_head      dd 0
msg_tail      dd 0
msg_count     dd 0
drag_bx       dd 0
drag_by       dd 0
clk_h         db 0
clk_m         db 0
clk_str       db "00:00",0
tb_x          dd 0
prev_lb       db 0
prev_rb       db 0
evt_hnd       dd -1
evt_msg       dw 0
evt_wp        dw 0
evt_lp        dw 0

; --- keyboard state ---
kbd_sc        db 0
kbd_ascii     db 0
kbd_shift     db 0
kbd_caps      db 0
kbd_break     db 0
kbd_focus     dd -1
kbd_have      db 0
; --- Notepad state ---
note_cur_col  db 0
note_cur_row  db 0
note_dirty    db 1
note_len      dw 0
note_blink    db 0
; --- File browser state ---
fs_cur_dir    db 255    ; current folder index (255 = root)
fs_sel        db 255    ; selected file index
fs_dirty      db 1
; --- Net state ---
net_hnd       dd -1     ; network neighbor handle
net_tick      dw 0      ; last broadcast tick
; --- Browser state ---
br_page       db 0      ; 0=idle, 1=ludashi, 2=google, 3=report
br_dl_click   db 0      ; download button clicked?
; --- Phase B: hover / dbl-click / downloaded bytecode ---
hover_btn     db 0      ; 0=none, B_CL/B_MX/B_MN = hovered title button
dbl_tick      dd 0      ; tick of last title-bar click
dbl_hwnd      db 0      ; window ID of last title-bar click
dbl_x         dd 0      ; x of last title-bar click (for proximity check)
dbl_y         dd 0      ; y of last title-bar click
dl_valid      db 0      ; 0 = none, 1 = dl_code raw, 2 = installed to file_table
; --- EXE contents pool: 16 x 1KB chunks, statically mapped by file index ---
;   file_contents_pool + i*EXE_CONTENT_CHUNK  <==>  content_off = i*EXE_CONTENT_CHUNK
file_contents_pool times FS_MAX_CONTENTS*EXE_CONTENT_CHUNK db 0
file_contents_used db 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0  ; 1 = chunk occupied
; --- Installer state ---
ins_prog      db 0      ; 0..100
ins_state     db 0      ; 0=idle,1=dl,2=install,3=done
ins_prog_tick dw 0
redraw_fs     db 0      ; 1 = file_table changed; force File Explorer repaint next tick
; --- Runner state ---
run_prog      db 0          ; which exe (file index)
; --- EXE VM state ---
exe_pc        dw 0          ; bytecode program counter
exe_sp        dw 0          ; stack pointer (index)
exe_flags     db 0          ; ZF
exe_done      db 0          ; 1 = VM halted
; --- NIC state ---
nic_base      dd -1         ; NIC MMIO base
nic_type      db 0          ; 0=none,1=e1000
nic_ioport    dw 0          ; E1000 I/O port base (BAR1) for reliable register access
nic_mac_lo    dd 0          ; MAC[0..3]
nic_mac_hi    dw 0          ; MAC[4..5]
pci_dbg_val   dd 0          ; temp for PCI debug output

ALIGN 4
wnd_table     times MAXW*WSZ db 0
ALIGN 4
msg_queue     times MAXM*MSZ db 0
; --- Notepad text buffer (512 bytes) ---
note_text     times 512 db 0
; --- File table (64 entries × 32 bytes = 2KB) ---
; Each entry: name[16], type(1), size(4), flags(1), parent(1), pad(7)
file_table    times FS_MAXF*FS_SZ db 0
; --- Network host table (8 entries × 32 bytes = 256 bytes) ---
net_hosts     times NET_MAXH*NET_SZ db 0
; --- EXE VM: code + data + stack buffers ---
exe_stack     times 16 dd 0     ; 64 bytes value stack
exe_cstack    times 8 dd 0      ; 32 bytes call stack
exe_csp       db 0
exe_zf        db 0
exe_code      times EXE_CONTENT_CHUNK db 0     ; bytecode buffer (now 1KB)
exe_data      times 32 db 0     ; static data (strings/vars for program)
exe_out       times 64 db 0     ; VM console output
exe_out_len   dw 0
exe_delay     dw 0              ; remaining delay ticks
exe_running   db 0              ; 1 = VM active
exe_prog_name times 17 db 0     ; exe name copy
; --- ARP state ---
arp_cache     times 2 dd 0      ; 2 MACs (24 bytes)
arp_state     db 0              ; 0=idle,1=req_sent,2=timeout,4=reply,0x40=fail
arp_target_ip times 4 db 0      ; 4 bytes IP
arp_reply_mac times 6 db 0
arp_reply_ip  times 4 db 0      ; replied gateway IP (for display)
arp_timeout   dd 0              ; vtd_t when ARP request was sent
; --- Network protocol stack ---
net_tx_buf     times 128 db 0    ; outbound Ethernet frame buffer
net_tx_len     dw 0
net_send_state db 0              ; 1=sent, 2=no NIC
udp_sport      dw 0
udp_dport      dw 0
udp_len        dw 0
udp_dst_ip     times 4 db 0    ; UDP destination IP (network-order bytes)
udp_rx_state   db 0
UDP_RX_CAP     equ 256
udp_rx_buf     times UDP_RX_CAP db 0  ; DNS response storage (typ. < 120 bytes)
udp_rx_dbg_cnt db 0            ; one-shot counter for udp_rx arrival logs (cap 4)
udp_tx_buf     times 256 db 0  ; DNS query build area (12 hdr + up to 240 name)
tcp_state      db 0              ; 0=closed,1=SYN_SENT,2=ESTABLISHED
tcp_tx_pending_logged db 0       ; 1 = already printed "TX pending" this session (avoid flood)
eth_rx_dbg_logged  db 0          ; 1 = already printed eth_rx no-pkt debug
eth_rx_adv_cnt     db 0          ; counter: how many CAPR-advance events we've logged
tcp_seq        dd 1
tcp_ack        dd 0
tcp_sport      dw 0
tcp_dport      dw 0
tcp_psh        db 0
tcp_rx_buf     times 32 db 0
tcp_tx_buf     times 32 db 0
tx_tail        db 0          ; next TX descriptor index (0-7)
tcp_rx_state   db 0           ; 0=idle,1=data received
tcp_rx_len     dw 0           ; received payload length
nd_tcp_checked db 0           ; one-time TDH debug check flag
nd_last_logged_state db 0xFF ; last net_dl_state value printed (0xFF = forces first log)
; --- NIC ring buffers (RTL8139 TX buffer + 8K RX ring) ---
; NOTE: QEMU RTL8139 model masks TSAD0 to 64-byte alignment (low 6 bits clear)
; after TSD0 size write.  NASM's ALIGN directive only aligns within the
; current section output alignment (usually 16-byte); for guaranteed 256-byte
; alignment we pad explicitly.
ALIGN 256
db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ALIGN 256
rtl8139_tx_buf times 1792 db 0  ; RTL8139 TX buffer (256-byte aligned for QEMU mask safety)
ALIGN 256
db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
ALIGN 256
rtl8139_rx_buf times 8192 db 0  ; RTL8139 RX buffer (256-byte aligned, 8KB = RBLEN=00 min size)
ALIGN 16
nic_rx_data times 1600 db 0; received frame buffer (full MTU 1514 + slack)
; --- TCP state ---
tcp_dst_ip    times 4 db 0   ; destination IP
tcp_timeout   dd 0           ; vtd_t when SYN sent (32-bit, matches dword vtd_t)
; --- P1.5 TCP robustness: retransmission buffer + graceful-close state ---
tcp_retries   db 0           ; consecutive send retries (cap = 3, then abort)
tcp_fin_state db 0           ; 0=none,1=FIN_SENT,2=FIN_WAIT_ACK,3=CLOSED
tcp_last_tx_len dw 0         ; length of last transmitted frame snapshot (<=128 for GET/SYN/FIN)
tcp_last_tx_snap times 128 db 0 ; last TX frame snapshot (eth+ip+tcp+payload, for retransmit)
; --- DNS state ---
dns_state     db 0           ; 0=idle,1=querying,2=resolved,3=timeout
dns_ip        times 4 db 0   ; resolved IP (network-order bytes)
dns_server_ip dd 0x050505DF   ; DNS resolver (memory bytes DF 05 05 05 = 223.5.5.5)
dns_timeout   dd 0           ; vtd_t when query sent (32-bit, matches dword vtd_t)
nd_dns_retries db 0          ; consecutive DNS resolution failures (cap = 3)
udp_state     db 0           ; 0=idle,1=sending
; --- HTTP state ---
http_buf      times 256 db 0 ; HTTP request/TX buffer
http_len      dw 0
http_body     dd 0           ; pointer to body start (in http_rx_buf)
http_body_len dw 0
; --- HTTP RX accumulation (separate from TX http_buf) ---
http_rx_buf   times 4096 db 0 ; HTTP response accumulation buffer
http_rx_len   dw 0           ; accumulated bytes in http_rx_buf
http_rx_state db 0           ; 0=idle,1=accumulating,2=complete(headers done),3=body_done
http_hdr_end  dw 0           ; offset in http_rx_buf where body starts (after \r\n\r\n)
http_content_len dd 0        ; Content-Length from HTTP headers (0 = unknown)
; --- PE state ---
pe_state      db 0           ; 0=unparsed,1=valid
pe_entry      dd 0           ; entry point RVA
pe_sections   dd 0           ; section count
pe_optional_size dd 0
pe_section_name times 8 db 0
pe_vsize      dd 0
pe_vaddr      dd 0
pe_rawsize    dd 0
pe_rawoff     dd 0
pe_pCOFF_off      dd 0             ; COFF header offset in PE file (= e_lfanew + 4)
pe_coff_machine   dw 0             ; COFF Machine field
pe_baseofcode     dd 0             ; Optional+20
pe_baseofdata     dd 0             ; Optional+24 (PE32 only)
pe_imagebase      dd 0             ; Optional+28, PE preferred load base
pe_sectionalign   dd 0             ; Optional+32
pe_filealign      dd 0             ; Optional+36
pe_datadir_off    dd 0             ; DataDirectory offset in PE file (= pe_pCOFF_off + 116)
pe_sectable_off   dd 0             ; Section Table offset in PE file
pe_load_base      dd 0             ; actual load base (may != ImageBase)
pe_reloc_delta    dd 0             ; pe_load_base - pe_imagebase
pe_rva_end        dd 0             ; pe_load_base + code_size + data_size, safety bound
pe_import_resolved db 0            ; 1=imports resolved
pe_running        db 0             ; 0=stopped, 1=running
pe_sleep_ticks    dw 0             ; Sleep() pending tick count
pe_exit_code      dd 0             ; ExitProcess return code
pe_file_index     db 0             ; file_table index for current PE
; --- P0.3 PE extension state / arenas ---
pe_default_exename   db "inet_dl.exe", 0  ; for GetModuleFileNameA
pe_default_cmdline   db "hello.exe", 0    ; for GetCommandLineA
; Bump allocators (per-boot, never freed — PE programs use one-shot allocs)
pe_heap_off      dd 0             ; next allocation offset in pe_heap_bss
pe_vmem_off      dd 0             ; next allocation offset in pe_vmem_bss
; File cursor positions for fs_read/write via CreateFileA handles (per file slot)
pe_fpos          times FS_MAXF dd 0
; P1.6 double-click runner pending flag  (1 = mou_handle armed run_prog/pe_state,
; main_loop dispatches exe_load next tick)
pe_pending_run   db 0
sys_tick          dd 0             ; global system tick counter (100Hz)
ml_debug_cnt      dd 0             ; main_loop iteration counter (debug)
; --- Download orchestration ---
net_dl_state  db 0           ; 0=idle,1=arp,2=dns,3=tcp,4=http,5=got,6=done
; URL to download (null-terminated ASCII string).
; May be "http://host/path" with host = dotted-quad IP or DNS hostname.
; Modify this in RAM (e.g. via debugger/script) to download arbitrary URLs.
; DL_TEST_DNS build switches the default URL to a real-internet hostname so
; the DNS path (net_dl state 2) is exercised end-to-end (see build_net.ps1
; -DnsTest and run_real_inet_test.ps1 -DnsTest).
%ifdef DL_TEST_DNS
dl_url_str    db "http://httpbin.org/bytes/256", 0
%else
dl_url_str    db "http://10.0.2.2:8080/a4.exe", 0
%endif
; DNS-path validation (already proven, see _real_inet_test.pcap):
;   dl_url_str was temporarily set to "http://httpbin.org/bytes/64" and the
;   full chain  DNS(223.5.5.5) -> A=98.88.229.31 -> TCP -> GET /bytes/64 ->
;   HTTP 200 (real internet payload) was captured on the wire.
; Saved hostname ptr extracted from dl_url_str (used by DNS phase + Host header)
dl_hostname   dd 0
dl_hostlen    dd 0            ; bytes in hostname (0 = not set)
; Saved tcp_dst_port override (0 = default 80).  If URL has ":port", filled here.
dl_dst_port   dw 0
; Scratch buffers for dl_parse_url / DNS phase
nd_parsed_ip    dd 0        ; result of literal IP parse (0 = need DNS)
nd_host_scratch times 65 db 0 ; NUL-terminated hostname copy for dns_resolve (max 64 label)
; --- Local MAC ---
eth_myt_mac   times 6 db 0  ; filled by net_init
; --- Default bytecode programs (inline null-terminated strings) ---
app_code:
    db 0x03, "app running.", 0       ; PRINT
    db 0x00                            ; HALT
ludashi_code:
    db 0x03, "Scanning...", 0        ; PRINT
    db 0x10, 30                       ; DELAY 30 ticks
    db 0x03, "System is clean.", 0   ; PRINT
    db 0x00                            ; HALT
; --- Phase B: downloaded bytecode buffer (filled by net_download), now 1KB ---
dl_code       times EXE_CONTENT_CHUNK db 0

; --- PE download buffer: 64KB, 可容纳小至中等 PE ---
ALIGN 4
pe_download_buf   times PE_DOWNLOAD_MAX db 0
pe_download_len   dd 0                ; 实际下载长度（字节）

; --- P0.3 PE stub memory arenas ---
ALIGN 4
pe_heap_bss       times PE_HEAP_SIZE db 0   ; 32KB bump heap for HeapAlloc
pe_vmem_bss       times PE_VMEM_SIZE db 0   ; 64KB page-aligned pool for VirtualAlloc

; --- NET_TEST: canned HTTP response with 0xA4 magic + test bytecode ---
%ifdef NET_TEST
test_http_resp:
    db "HTTP/1.1 200 OK", 0x0D, 0x0A
    db "Content-Length: 19", 0x0D, 0x0A
    db 0x0D, 0x0A
test_bc_body:
    db BC_MAGIC                              ; 0xA4 magic header
    db 0x03, "DL:OK", 0x00                   ; PRINT "DL:OK"
    db 0x10, 0x10                            ; DELAY 16 ticks
    db 0x03, " VM OK", 0x00                  ; PRINT " VM OK"
    db 0x00                                  ; HALT
test_bc_body_len equ $ - test_bc_body
test_http_resp_len equ $ - test_http_resp
%endif
; --- Browser URL buffer ---
br_url        times BR_ADDR db 0

; --- strings ---
title_t       db "MS-DOS", 0
start_t       db "START", 0
mnu_t1        equ title_t        ; alias: "MS-DOS"
mnu_t2        db "Notepad", 0
mnu_t3        db "File Explorer", 0
mnu_t4        db "Network", 0
mnu_t5        db "Recycle Bin", 0
mnu_t6        db "New File", 0
mnu_t7        db "Shut Down", 0
ctx_t1        db "Refresh", 0
ctx_t2        db "Properties", 0
ctx_t3        db "Exit", 0
title_dos_t   equ title_t        ; alias: "MS-DOS"
title_note_t  equ mnu_t2         ; alias: "Notepad"
title_about_t db "About", 0
title_win_t   db "Windows", 0
note_t1       db "Untitled", 0
icon_pc_t     db "My Computer", 0
icon_rc_t     db "Recycle Bin", 0
btn_close_c   db "X", 0
btn_min_c     db "-", 0
net_hdr_t     db "Network Neighbors", 0
net_ip_t      db "10.0.2.1", 0
fl_hdr_t      equ mnu_t3         ; alias: "File Explorer"
; Browser
br_addr_t     db "https://www.ludashi.com/pc/download/getDownloadUrl?type=2", 0
br_goog_t     db "https://www.google.com/search?q=download", 0
br_rep_t      db "about:report", 0
br_dlbtn_t    db "Download", 0
br_inst_t     db "Installation Complete", 0
br_report_t   db "System Report", 0
br_ver_t      db "Version: 1.0.0.1", 0
br_files_t    db "Files: 7 registered", 0
br_mem_t      db "Kernel: 32KB, RAM FS: 2KB", 0
br_net_t      db "Network: SLIRP Guest", 0
br_status_t   db "Status: Running", 0
br_google_t   db "Google Search Results", 0
br_lud_t      db "Ludashi Download Page", 0
br_dl_prog_t  db "Downloading...", 0
br_inst_prog_t db "Installing...", 0
br_done_t     db "Installation Complete!", 0
br_run_t      db "Ludashi Antivirus", 0
br_run_stat_t db "Scanning...", 0
br_run_ok_t   db "System is clean.", 0
arp_stat_t    db "ARP: Pending...", 0
arp_ok_t      db "ARP: Reply OK", 0
arp_fail_t    db "ARP: No NIC", 0
arp_tout_t    db "ARP: Timeout", 0
newfn_t       db "newfile.txt", 0
fl_trsh_t     equ icon_rc_t      ; alias: "Recycle Bin"

; --- DOS command output strings (stub, no longer used) ---
dos_out_ver   db "", 0
dos_out_bad   db "", 0
dos_prom_t    db "", 0

; --- Real AT Set 1 scan code table (unshifted) ---
kbd_at1:
db 0,27,'1','2','3','4','5','6'
db '7','8','9','0','-',8,9,0
db 'q','w','e','r','t','y','u','i'
db 'o','p','[',']',13,0
db 'a','s','d','f','g','h','j','k'
db 'l',';',39,96,0,92
db 'z','x','c','v','b','n','m',44
db 46,47,0,0,32,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0

; --- AT Set 1 scan code table (shifted) ---
kbd_at2:
db 0,27,'!','@','#','$','%','^'
db '&','*','(',')','_','+',8,9
db 'Q','W','E','R','T','Y','U','I'
db 'O','P','{','}',13,0
db 'A','S','D','F','G','H','J','K'
db 'L',':',34,126,0,124
db 'Z','X','C','V','B','N','M',60
db 62,63,0,0,32,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0
db 0,0,0,0,0,0,0,0

; --- VIN script ---
; Packed 12-byte event: dw delay, db type, dw x, dw y, db data, db pad[4]
;   (delay@0, type@2, x@3, y@5, data@7, pad@8..11) — matches VINSZ=12
%macro VINEV 5
    dw      %1
    db      %2
    dw      %3
    dw      %4
    db      %5, 0, 0, 0, 0
%endmacro
ALIGN 4
vin_scr:
    VINEV 3,   VIN_MM, 40,  186, 0
    VINEV 0,   VIN_LD, 40,  186, 0
    VINEV 0,   VIN_LU, 40,  186, 0
    VINEV 8,   VIN_WT, 0,   0,   0
    VINEV 0,   VIN_MM, 50,  130, 0
    VINEV 0,   VIN_LD, 50,  130, 0
    VINEV 0,   VIN_LU, 50,  130, 0
    VINEV 3,   VIN_WT, 0,   0,   0
    VINEV 0,   VIN_MM, 160, 15,  0
    VINEV 0,   VIN_LD, 160, 15,  0
    VINEV 0,   VIN_MM, 180, 40,  0
    VINEV 0,   VIN_LU, 180, 40,  0
    VINEV 3,   VIN_WT, 0,   0,   0
    VINEV 0,   VIN_MM, 160, 100, 0
    VINEV 0,   VIN_RD, 160, 100, 0
    VINEV 0,   VIN_RU, 160, 100, 0
    VINEV 3,   VIN_WT, 0,   0,   0
    VINEV 0,   VIN_MM, 219, 19,  0
    VINEV 0,   VIN_LD, 219, 19,  0
    VINEV 0,   VIN_LU, 219, 19,  0
    VINEV 6,   VIN_WT, 0,   0,   0
    VINEV 0,   VIN_EN, 0,   0,   0

; ============================================================================
; GDT + IDT
; ============================================================================
ALIGN 8
gdt_data:
    gdt_entry 0, 0, 0, 0                              ; null  (0x00)
    gdt_entry 0, 0xFFFFF, ACCESS_RING0_CODE, FLAG_4K_32BIT  ; code  (0x08)
    gdt_entry 0, 0xFFFFF, ACCESS_RING0_DATA, FLAG_4K_32BIT  ; data  (0x10)
    gdt_entry 0xA0000, 0xFFFFF, ACCESS_RING0_DATA, FLAG_4K_32BIT ; VGA   (0x18)
gdt_data_end_local:
gdt_desc_local:
    dw      gdt_data_end_local - gdt_data - 1
    dd      gdt_data

ALIGN 4
idt_table     times 0x30*8 db 0    ; 48 entries (vectors 0-0x2F, covers IRQ0-15 remapped)
idt_desc_local:
    dw      0x30*8 - 1
    dd      idt_table

; palette source table (64 entries * 3 bytes RGB, 0-63 each)
pal_src:
    ; 0 black
    db 0,0,0
    ; 1 white
    db 63,63,63
    ; 2 gray
    db 44,44,44
    ; 3 navy 0
    db 5,5,30
    ; 4 navy 1
    db 10,12,45
    ; 5 client
    db 58,58,58
    ; 6 dark
    db 20,20,20
    ; 7 light
    db 50,50,50
    ; 8 red close
    db 50,8,8
    ; 9 green max
    db 8,40,8
    ; 10 yellow min
    db 40,35,5
    ; 11 menu bg
    db 48,48,48
    ; 12-31 gray 40
    times 20*3 db 40
    ; 32-63 blue gradient (top deep blue -> bottom bright blue/cyan)
%assign _j 0
%rep 32
    db 0, (_j*50/31), (30 + _j*33/31)
%assign _j _j+1
%endrep

; font
%include "common/font8x8.inc"

; Buffer for sgdt output during boot diagnostics (placed at end to avoid
; shifting global_start away from the 0x100000 entry point)
ALIGN 4
gdtr_dump:    times 6 db 0
gs_load_tmp:  times 2 db 0