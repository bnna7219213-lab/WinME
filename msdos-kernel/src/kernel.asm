; ============================================================================
; kernel.asm — MS-DOS style 16-bit real-mode kernel
; ----------------------------------------------------------------------------
;  Loaded by boot.asm at 0x1000:0x0000. Provides:
;   * a banner + a tiny command shell (help/ver/cls/echo/halt)
;   * a DOS-style software interrupt 0x20 (ah=0x00 halt, ah=0x01 print $ str)
;  Assemble : nasm -f bin src/kernel.asm -o build/kernel.bin
; ============================================================================
BITS 16
ORG 0x0000

start:
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x9000

    ; install int 0x20 system-call handler into the real-mode IVT (@0x0)
    cli
    xor     ax, ax
    mov     es, ax
    mov     word [0x20*4],   int20_handler      ; offset
    mov     word [0x20*4+2], cs                   ; segment
    mov     es, ax              ; restore es = ds
    sti

    mov     si, banner
    call    puts

    ; demonstrate a kernel system call through the int 0x20 interface
    mov     ah, 0x01
    mov     dx, sc_msg
    int     0x20

    ; ---- headless self-test: exercise each shell command without a keyboard ----
    mov     si, test_hdr
    call    puts
    mov     si, ver_txt       ; "ver"
    call    puts
    mov     si, help_txt      ; "help"
    call    puts
    mov     si, echo_demo     ; "echo hello-from-dos"
    call    puts
    mov     si, unknown_demo  ; an unrecognised command
    call    puts

.cmdloop:
    mov     si, prompt
    call    puts
    call    readline
    call    dispatch
    jmp     .cmdloop

; ---- puts : print NUL-terminated string DS:SI ----------------------------
;  Echoes every character to the VGA console (BIOS int 0x10) and to the QEMU
;  debug port 0xE9 (-debugcon file:...) so the kernel is observable headless.
puts:
    lodsb
    or      al, al
    jz      .d
    push    ax
    mov     ah, 0x0E          ; VGA teletype
    xor     bx, bx
    int     0x10
    pop     ax
    out     0xE9, al          ; QEMU/Bochs debug console
    jmp     puts
.d: ret

; ---- dbg_out : write AL to the QEMU debug port 0xE9 (no init needed) ------
dbg_out:
    out     0xE9, al
    ret

; ---- readline : read a line into buf, echo, support backspace ----------
readline:
    mov     si, buf
.loop:
    mov     ah, 0x00
    int     0x16              ; wait for a keystroke (AL = ASCII)
    cmp     al, 0x0D          ; Enter
    je      .done
    cmp     al, 0x08          ; Backspace
    je      .bs
    cmp     si, buf+64
    jae     .loop             ; buffer full, ignore
    mov     [si], al
    inc     si
    mov     ah, 0x0E
    xor     bx, bx
    int     0x10
    jmp     .loop
.bs:
    cmp     si, buf
    je      .loop
    dec     si
    mov     ah, 0x0E
    mov     al, 0x08          ; backspace
    int     0x10
    mov     al, ' '
    int     0x10
    mov     al, 0x08
    int     0x10
    jmp     .loop
.done:
    mov     byte [si], 0
    mov     ah, 0x0E
    mov     al, 0x0D
    int     0x10
    mov     al, 0x0A
    int     0x10
    ret

; ---- dispatch : match the typed command (prefix match) -------------------
dispatch:
    mov     si, buf
    mov     di, cmd_help
    call    cmd_match
    jc      .help
    mov     si, buf
    mov     di, cmd_ver
    call    cmd_match
    jc      .ver
    mov     si, buf
    mov     di, cmd_cls
    call    cmd_match
    jc      .cls
    mov     si, buf
    mov     di, cmd_echo
    call    cmd_match
    jc      .echo
    mov     si, buf
    mov     di, cmd_halt
    call    cmd_match
    jc      .halt
    mov     si, msg_unknown
    call    puts
    ret
.help:
    mov     si, help_txt
    call    puts
    ret
.ver:
    mov     si, ver_txt
    call    puts
    ret
.cls:
    mov     ah, 0x00
    mov     al, 0x03          ; text mode 80x25
    int     0x10
    ret
.echo:
    mov     si, buf+5         ; skip "echo "
    call    puts
    ret
.halt:
    mov     si, halt_txt
    call    puts
    cli
    hlt

; ---- cmd_match : DS:SI = input, ES:DI = command word ---------------------
;  Matches when the whole command word equals a prefix of the input that is
;  followed by a space or end-of-string. Sets CF on match.
cmd_match:
    push    si
    push    di
.loop:
    mov     al, [di]
    or      al, al
    jz      .cmd_end
    cmp     al, [si]
    jne     .no
    inc     si
    inc     di
    jmp     .loop
.cmd_end:
    mov     al, [si]
    cmp     al, 0x20          ; space
    je      .yes
    or      al, al
    jz      .yes
.no:
    pop     di
    pop     si
    clc
    ret
.yes:
    pop     di
    pop     si
    stc
    ret

; ---- int 0x20 system-call handler (DOS-style) ---------------------------
;  ah = 0x00 -> halt ; ah = 0x01 -> print '$'-terminated string at DS:DX
int20_handler:
    cmp     ah, 0x00
    je      .halt
    cmp     ah, 0x01
    je      .print
    iret
.halt:
    cli
    hlt
.print:
    push    si
    mov     si, dx
    call    puts
    pop     si
    iret

; ---- data ----------------------------------------------------------------
banner     db "MS-DOS Kernel v0.1 (16-bit real mode)", 13, 10
           db "(c) toy kernel project. Type 'help' for commands.", 13, 10, 0
sc_msg     db "[syscall] int 0x20 handled OK", 13, 10, 0
test_hdr   db "--- self-test (headless) ---", 13, 10, 0
echo_demo  db "hello-from-dos (auto echo demo)", 13, 10, 0
unknown_demo db "Bad command or file name.", 13, 10, 0
prompt     db "C:\>", 0
help_txt   db "commands:", 13, 10
           db "  help          show this help", 13, 10
           db "  ver           show version", 13, 10
           db "  cls           clear screen", 13, 10
           db "  echo <text>   print text", 13, 10
           db "  halt          stop the system", 13, 10, 0
ver_txt    db "MS-DOS Kernel v0.1 / NASM 16-bit real mode", 13, 10, 0
halt_txt   db "System halted.", 13, 10, 0
msg_unknown db "Bad command or file name.", 13, 10, 0
cmd_help   db "help", 0
cmd_ver    db "ver", 0
cmd_cls    db "cls", 0
cmd_echo   db "echo", 0
cmd_halt   db "halt", 0
buf        times 65 db 0
