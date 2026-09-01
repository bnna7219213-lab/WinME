; ============================================================================
; a3_vmm.asm - M-A3: VMM + VxD (VTD virtual timer, System VM / DOS VM)
; ----------------------------------------------------------------------------
;  Tribute to Win95's VMM32.VXD:
;    - VMM      : virtual machine manager, round-robin scheduler over VM_CB list
;    - VM_CB    : VM control block (Win95 calls this the "VM Control Block")
;    - VTD      : Virtual Timer Device, a VxD bound to PIT IRQ0
;    - Sys VM   : the "system virtual machine" (where Windows itself runs)
;    - DOS VM   : a "DOS box" virtual machine
;
;  Context switch model (the part that must be exactly right):
;    On an IRQ the CPU has ALREADY pushed EFLAGS/CS/EIP onto the current stack.
;    'pushad' then pushes 32 more bytes. At that instant ESP alone fully
;    describes the interrupted context, so a task switch is simply:
;
;        mov [old_vm + VM_ESP], esp      ; save
;        mov esp, [new_vm + VM_ESP]      ; restore
;        popad
;        iretd
;
;    There is deliberately NO separate EIP/EFLAGS/ESP field in the VM_CB.
;    Storing those separately is what forces hand-rebuilt stack frames and
;    causes the classic 4-byte misalignment crashes.
;
;    Note: 'pushad' pushes 8 registers = 32 bytes, and that DOES include an
;    ESP slot (which popad discards). Frame math below depends on this.
;
;  A VM that has never run has no interrupt frame to return through, so it is
;  bootstrapped with a SYNTHETIC frame identical to what an IRQ would leave:
;
;        [top-4]  EFLAGS  (IF=1 so the VM is preemptible)
;        [top-8]  CS      (SEL_CODE0)
;        [top-12] EIP     (VM entry point)
;        [top-44] 8 x GPR (pushad image, all zero)
;                 ^-- VM_ESP points here
;
;  All VMs run at ring0 (CPL=0). VM isolation here is scheduling-level, which
;  is enough to demonstrate the VMM/VxD structure without dragging in TSS
;  privilege transitions.
; ============================================================================
BITS 16
ORG 0x0000

%include "common/debug.inc"
%include "common/gdt.inc"

KBASE           equ 0x10000     ; physical load address of this kernel

; --- VM control block layout ---
VM_ESP          equ 0           ; saved ESP (the whole context handle)
VM_STATE        equ 4           ; 0=free 1=ready 2=running
VM_ID           equ 8           ; VM id
VM_TICKS        equ 12          ; ticks consumed by this VM
VM_NAME         equ 16          ; 4-byte tag
VM_CB_SIZE      equ 20

VM_STATE_FREE   equ 0
VM_STATE_READY  equ 1
VM_STATE_RUN    equ 2

MAX_VMS         equ 2
VM_STACK_SIZE   equ 1024

; how many timer ticks each VM gets before the VMM preempts it
VM_QUANTUM      equ 2
; stop after this many total ticks so the demo terminates deterministically
MAX_TICKS       equ 24

start:
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x9000
    mov     si, banner
    call    puts
    mov     si, auto_msg
    call    puts
    call    enter_pm

after_pm_ret:
    mov     si, back_msg
    call    puts
.cmdloop:
    mov     si, prompt
    call    puts
    call    readline
    call    dispatch
    jmp     .cmdloop

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
    jmp     0x08:pm32_entry

; ============================================================================
; 32-bit protected mode. Everything from here to rm_16 is BITS 32.
; ============================================================================
BITS 32
pm32_entry:
    mov     ax, 0x10
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    mov     ss, ax
    mov     esp, 0x20000

    mov     esi, pm_banner
    call    dbg32_puts

    call    build_idt
    lidt    [idt_descriptor]

    call    vmm_init
    call    vtd_init

    mov     esi, sched_msg
    call    dbg32_puts

    ; Hand control to the first VM. From here on the PIT drives everything.
    call    vmm_start
    ; vmm_start does not return; the VMM exits via vmm_shutdown -> back to RM

; ============================================================================
; VMM - virtual machine manager
; ============================================================================
vmm_init:
    mov     esi, vmm_init_msg
    call    dbg32_puts

    ; --- System VM (id 0) ---
    mov     edi, vm_table + 0*VM_CB_SIZE
    mov     dword [edi + VM_ID],    0
    mov     dword [edi + VM_STATE], VM_STATE_READY
    mov     dword [edi + VM_TICKS], 0
    mov     dword [edi + VM_NAME],  'SYS '
    mov     eax, sysvm_stack_top + KBASE
    mov     ebx, sysvm_entry
    call    vm_bootstrap_frame

    ; --- DOS VM (id 1) ---
    mov     edi, vm_table + 1*VM_CB_SIZE
    mov     dword [edi + VM_ID],    1
    mov     dword [edi + VM_STATE], VM_STATE_READY
    mov     dword [edi + VM_TICKS], 0
    mov     dword [edi + VM_NAME],  'DOS '
    mov     eax, dosvm_stack_top + KBASE
    mov     ebx, dosvm_entry
    call    vm_bootstrap_frame

    mov     dword [current_vm], 0
    mov     dword [total_ticks], 0
    mov     dword [quantum_left], VM_QUANTUM

    mov     esi, vmm_ready_msg
    call    dbg32_puts
    ret

; --- vm_bootstrap_frame -----------------------------------------------------
;  Build the synthetic interrupt frame for a VM that has never run.
;  EDI = VM_CB, EAX = stack top (linear), EBX = entry EIP
;  Note: the GDT is flat with base=KBASE, so a "linear" stack address must be
;  written as a segment-relative offset. We keep stacks inside the kernel image
;  and pass base-relative values, so subtract KBASE back off here.
vm_bootstrap_frame:
    push    edi
    sub     eax, KBASE          ; convert to segment-relative offset
    mov     edi, eax

    ; iretd frame (pushed high-to-low: EFLAGS, CS, EIP)
    sub     edi, 4
    mov     dword [edi], 0x0202     ; EFLAGS: IF=1, bit1 reserved=1
    sub     edi, 4
    mov     dword [edi], 0x08       ; CS = SEL_CODE0
    sub     edi, 4
    mov     [edi], ebx              ; EIP = VM entry

    ; pushad image: EAX ECX EDX EBX ESP EBP ESI EDI (8 dwords, all zero)
    mov     ecx, 8
.zero:
    sub     edi, 4
    mov     dword [edi], 0
    loop    .zero

    mov     eax, edi
    pop     edi
    mov     [edi + VM_ESP], eax
    ret

; --- vmm_start : switch into the first VM -----------------------------------
vmm_start:
    mov     eax, [current_vm]
    imul    eax, VM_CB_SIZE
    add     eax, vm_table
    mov     dword [eax + VM_STATE], VM_STATE_RUN
    mov     esp, [eax + VM_ESP]
    popad
    iretd

; --- vmm_schedule : pick the next READY VM, round-robin ---------------------
;  Called from the VTD interrupt handler with the outgoing context already
;  saved. Returns with ESP pointing at the incoming VM's frame.
vmm_schedule:
    ; mark current VM ready again
    mov     eax, [current_vm]
    imul    eax, VM_CB_SIZE
    add     eax, vm_table
    mov     dword [eax + VM_STATE], VM_STATE_READY

    ; advance round-robin
    mov     eax, [current_vm]
    inc     eax
    cmp     eax, MAX_VMS
    jb      .store
    xor     eax, eax
.store:
    mov     [current_vm], eax
    mov     dword [quantum_left], VM_QUANTUM

    ; mark the new VM running
    imul    eax, VM_CB_SIZE
    add     eax, vm_table
    mov     dword [eax + VM_STATE], VM_STATE_RUN
    ret

; --- vmm_shutdown : leave PM and return to the real-mode shell --------------
vmm_shutdown:
    cli
    mov     esi, stats_hdr
    call    dbg32_puts

    ; per-VM tick statistics
    xor     ebx, ebx
.loop:
    cmp     ebx, MAX_VMS
    jae     .done
    mov     esi, stat_pre
    call    dbg32_puts
    mov     eax, ebx
    imul    eax, VM_CB_SIZE
    add     eax, vm_table
    push    eax
    ; name tag (4 chars)
    mov     esi, eax
    add     esi, VM_NAME
    mov     ecx, 4
.name:
    lodsb
    out     0xE9, al
    loop    .name
    mov     esi, stat_mid
    call    dbg32_puts
    pop     eax
    mov     eax, [eax + VM_TICKS]
    call    dbg32_dec
    mov     esi, nl
    call    dbg32_puts
    inc     ebx
    jmp     .loop
.done:
    mov     esi, total_pre
    call    dbg32_puts
    mov     eax, [total_ticks]
    call    dbg32_dec
    mov     esi, nl
    call    dbg32_puts

    ; mask the PIT again so real mode is not flooded
    mov     al, 0xFF
    out     0x21, al

    ; restore the real-mode IVT before clearing PE
    lidt    [rm_idt_descriptor]
    jmp     0x28:rm_16

; ============================================================================
; VTD - Virtual Timer Device (a VxD bound to PIT IRQ0)
; ============================================================================
vtd_init:
    mov     esi, vtd_init_msg
    call    dbg32_puts

    ; --- remap the 8259 PICs so IRQ0..7 -> vectors 0x20..0x27 ---
    ; (in PM, vector 8 would otherwise collide with #DF)
    mov     al, 0x11            ; ICW1: init + ICW4
    out     0x20, al
    out     0xA0, al
    mov     al, 0x20            ; ICW2 master: base vector 0x20
    out     0x21, al
    mov     al, 0x28            ; ICW2 slave: base vector 0x28
    out     0xA1, al
    mov     al, 0x04            ; ICW3 master: slave on IRQ2
    out     0x21, al
    mov     al, 0x02            ; ICW3 slave: cascade identity
    out     0xA1, al
    mov     al, 0x01            ; ICW4: 8086 mode
    out     0x21, al
    out     0xA1, al

    ; unmask IRQ0 only
    mov     al, 0xFE
    out     0x21, al
    mov     al, 0xFF
    out     0xA1, al

    ; --- program the PIT: channel 0, mode 3, ~100 Hz ---
    mov     al, 0x36
    out     0x43, al
    mov     ax, 11932           ; 1193182 / 100
    out     0x40, al
    mov     al, ah
    out     0x40, al

    mov     dword [vtd_ticks], 0
    mov     esi, vtd_ready_msg
    call    dbg32_puts
    ret

; --- VTD interrupt service routine (vector 0x20 = IRQ0) ---------------------
;  This is the heart of the VMM: it is both the VxD's tick source and the
;  scheduler's preemption point.
vtd_isr:
    pushad

    ; count the tick
    inc     dword [vtd_ticks]
    inc     dword [total_ticks]

    ; charge the tick to the running VM
    mov     eax, [current_vm]
    imul    eax, VM_CB_SIZE
    add     eax, vm_table
    inc     dword [eax + VM_TICKS]

    ; EOI to the master PIC (must happen before any switch)
    mov     al, 0x20
    out     0x20, al

    ; terminate the demo after MAX_TICKS
    mov     eax, [total_ticks]
    cmp     eax, MAX_TICKS
    jb      .no_exit
    ; unwind to a known-good stack, then shut the VMM down
    mov     esp, 0x20000
    jmp     vmm_shutdown
.no_exit:

    ; preempt when the quantum expires
    dec     dword [quantum_left]
    cmp     dword [quantum_left], 0
    jg      .no_switch

    ; --- context switch ---
    mov     eax, [current_vm]
    imul    eax, VM_CB_SIZE
    add     eax, vm_table
    mov     [eax + VM_ESP], esp     ; save outgoing context

    call    vmm_schedule            ; pick incoming VM

    mov     eax, [current_vm]
    imul    eax, VM_CB_SIZE
    add     eax, vm_table
    mov     esp, [eax + VM_ESP]     ; restore incoming context

.no_switch:
    popad
    iretd

; ============================================================================
; Guest VMs. Each runs an endless loop and is preempted by the VTD.
; ============================================================================
sysvm_entry:
    sti
.loop:
    mov     esi, sysvm_msg
    call    dbg32_puts
    mov     eax, [vtd_ticks]
    call    dbg32_dec
    mov     esi, nl
    call    dbg32_puts
    call    vm_delay
    jmp     .loop

dosvm_entry:
    sti
.loop:
    mov     esi, dosvm_msg
    call    dbg32_puts
    mov     eax, [vtd_ticks]
    call    dbg32_dec
    mov     esi, nl
    call    dbg32_puts
    call    vm_delay
    jmp     .loop

; busy-wait long enough that each VM prints roughly once per quantum
vm_delay:
    push    ecx
    mov     ecx, 0x000A0000
.d: dec     ecx
    jnz     .d
    pop     ecx
    ret

; ============================================================================
; IDT
; ============================================================================
build_idt:
    ; zero the table
    mov     edi, idt_table
    mov     ecx, 256 * 2
    xor     eax, eax
    rep     stosd

    ; CPU exception handlers (DPL=0 interrupt gates)
    ; NOTE: EAX carries the handler offset into set_idt_entry - never clobber
    ; AL between loading it and the call (an 'out 0xE9,al' marker here was a
    ; real bug during M-A2 bring-up).
    mov     eax, idt_default_handler
    mov     ebx, eax
    shr     ebx, 16
    mov     ecx, 0x08
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
    mov     ecx, 0x08
    mov     edx, 0x8E
    mov     esi, 0x20
    call    set_idt_entry
    ret

; --- set_idt_entry ----------------------------------------------------------
;  EAX = handler offset, EBX = handler>>16, ECX = selector,
;  DL  = access byte, ESI = vector.
;
;  32-bit interrupt gate layout (getting this wrong cost a full debug cycle
;  in M-A2: the access byte belongs at +5, NOT +4):
;    +0 word  offset[15:0]
;    +2 word  selector
;    +4 byte  reserved (0)
;    +5 byte  access (P|DPL|type)
;    +6 word  offset[31:16]
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

; ============================================================================
; Return to real mode
; ============================================================================
BITS 16
rm_16:
    ; load 16-bit data descriptors before clearing PE so the cached segment
    ; attributes are real-mode compatible
    mov     ax, 0x38
    mov     ds, ax
    mov     es, ax
    mov     fs, ax
    mov     gs, ax
    mov     ss, ax
    mov     eax, cr0
    and     eax, 0xFFFFFFFE
    mov     cr0, eax
    jmp     KBASE >> 4:rm_back

rm_back:
    mov     ax, KBASE >> 4
    mov     ds, ax
    mov     es, ax
    mov     ss, ax
    mov     sp, 0x9000
    sti
    jmp     after_pm_ret

; ============================================================================
; 16-bit shell helpers
; ============================================================================
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

readline:
    mov     si, buf
.l: mov     ah, 0x00
    int     0x16
    cmp     al, 0x0D
    je      .done
    cmp     al, 0x08
    je      .bs
    cmp     si, buf+64
    jae     .l
    mov     [si], al
    inc     si
    mov     ah, 0x0E
    xor     bx, bx
    int     0x10
    jmp     .l
.bs:cmp     si, buf
    je      .l
    dec     si
    mov     ah, 0x0E
    mov     al, 0x08
    int     0x10
    mov     al, ' '
    int     0x10
    mov     al, 0x08
    int     0x10
    jmp     .l
.done:
    mov     byte [si], 0
    ret

dispatch:
    mov     si, buf
    mov     di, cmd_help
    call    cmd_match
    jc      .help
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
.halt:
    cli
    hlt

cmd_match:
    push    si
    push    di
.l: mov     al, [di]
    or      al, al
    jz      .end
    cmp     al, [si]
    jne     .no
    inc     si
    inc     di
    jmp     .l
.end:
    mov     al, [si]
    cmp     al, 0x20
    je      .yes
    or      al, al
    jz      .yes
.no:pop     di
    pop     si
    clc
    ret
.yes:
    pop     di
    pop     si
    stc
    ret

; ============================================================================
; Data
; ============================================================================
banner        db "Win9x Axis - M-A3 (VMM/VxD demo)", 13, 10, 0
auto_msg      db "[AUTO] VMM + VTD scheduling demo...", 13, 10, 0
pm_banner     db "[M-A3] PM ON - VMM32 starting", 13, 10, 0
vmm_init_msg  db "[VMM] init: creating virtual machines", 13, 10, 0
vmm_ready_msg db "[VMM] Sys VM + DOS VM created, state=READY", 13, 10, 0
vtd_init_msg  db "[VTD] init: PIC remap + PIT 100Hz", 13, 10, 0
vtd_ready_msg db "[VTD] virtual timer device armed on IRQ0", 13, 10, 0
sched_msg     db "[VMM] scheduler start (round-robin, quantum=2)", 13, 10, 0
sysvm_msg     db "  [Sys VM] running, tick=", 0
dosvm_msg     db "  [DOS VM] running, tick=", 0
stats_hdr     db "[VMM] shutdown - VM statistics:", 13, 10, 0
stat_pre      db "  VM ", 0
stat_mid      db " ticks=", 0
total_pre     db "[VTD] total ticks=", 0
fault_msg     db "[FAULT] unhandled exception", 13, 10, 0
nl            db 13, 10, 0
back_msg      db "BACK IN REAL MODE - VMM demo complete", 13, 10, 0
prompt        db "C:\>", 0
help_txt      db "commands: help, halt", 13, 10, 0
msg_unknown   db "?", 13, 10, 0
cmd_help      db "help", 0
cmd_halt      db "halt", 0

ALIGN 4
current_vm    dd 0
total_ticks   dd 0
quantum_left  dd 0
vtd_ticks     dd 0

ALIGN 4
vm_table      times MAX_VMS*VM_CB_SIZE db 0

buf           times 65 db 0

ALIGN 16
sysvm_stack     times VM_STACK_SIZE db 0
sysvm_stack_top equ $
ALIGN 16
dosvm_stack     times VM_STACK_SIZE db 0
dosvm_stack_top equ $

; ============================================================================
; GDT
; ============================================================================
ALIGN 8
gdt_data:
    gdt_entry 0, 0, 0, 0                                            ; 0x00 null
    gdt_entry KBASE, 0xFFFFF, ACCESS_RING0_CODE, FLAG_4K_32BIT      ; 0x08 code
    gdt_entry KBASE, 0xFFFFF, ACCESS_RING0_DATA, FLAG_4K_32BIT      ; 0x10 data
    gdt_entry KBASE, 0xFFFFF, ACCESS_RING3_CODE, FLAG_4K_32BIT      ; 0x18 code3
    gdt_entry KBASE, 0xFFFFF, ACCESS_RING3_DATA, FLAG_4K_32BIT      ; 0x20 data3
    gdt_entry KBASE, 0x0FFFF, ACCESS_RING0_CODE, 0x00               ; 0x28 code16
    gdt_entry 0, 0, 0, 0                                            ; 0x30 TSS slot
    gdt_entry KBASE, 0x0FFFF, ACCESS_RING0_DATA, 0x00               ; 0x38 data16
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

; real-mode IVT pseudo-descriptor, reloaded before leaving PM
rm_idt_descriptor:
    dw      0x3FF
    dd      0
