; ============================================================================
; paging.inc — Two-level (x86) page table macros for 32-bit protected mode
; ----------------------------------------------------------------------------
;  Usage:  %include "common/paging.inc"
;
;  x86 32-bit paging uses:
;    - Page Directory (PD): 1024 entries, each 4 bytes, 4KB aligned
;    - Page Table     (PT): 1024 entries, each 4 bytes, 4KB aligned
;    - One PT maps 4MB of virtual memory (1024 * 4KB pages)
;    - One PD maps 4GB total (1024 * 4MB)
;
;  PTE flags (lower 12 bits):
;    P=Present, R/W=Read/Write, U/S=User/Supervisor, PWT, PCD, A, D, PAT, G
; ============================================================================

; --- PTE flag constants -----------------------------------------------------
PTE_PRESENT    equ 1 << 0    ; bit 0: Present
PTE_RW         equ 1 << 1    ; bit 1: Read/Write
PTE_USER       equ 1 << 2    ; bit 2: User/Supervisor (1=user-accessible)
PTE_WRITE_THRU equ 1 << 3    ; bit 3: Page-level write-through
PTE_CACHE_DIS  equ 1 << 4    ; bit 4: Page-level cache disable
PTE_ACCESSED   equ 1 << 5    ; bit 5: Accessed (set by CPU)
PTE_DIRTY      equ 1 << 6    ; bit 6: Dirty (set by CPU on write)
PTE_PAT        equ 1 << 7    ; bit 7: Page Attribute Table
PTE_GLOBAL     equ 1 << 8    ; bit 8: Global (not flushed on CR3 write)
PTE_NX         equ 1 << 63   ; bit 63: No-Execute (PAE mode only, not in standard 32-bit)

; Common combinations
PTE_KERNEL     equ PTE_PRESENT | PTE_RW                          ; ring0, R/W
PTE_USER_RW    equ PTE_PRESENT | PTE_RW | PTE_USER              ; user, R/W
PTE_USER_RO    equ PTE_PRESENT | PTE_USER                        ; user, R/O
PTE_KERNEL_NX  equ PTE_PRESENT | PTE_RW                          ; placeholder for DEP demo

; --- page_table_entry : emit one 4-byte PTE ---------------------------------
;  %1 = physical page frame address (must be 4KB aligned) or 0
;  %2 = flags (PTE_* combination)
%macro pte 2
    dd      (%1) | (%2)
%endmacro

; --- identity_map_4m : identity-map one 4MB region --------------------------
;  %1 = start address (must be 4MB aligned, e.g. 0x00000000)
;  %2 = flags for all 1024 pages in this PT
;  Emits a 4KB-aligned page table with 1024 identity-mapped entries.
%macro identity_map_4m 2
ALIGN 4096
%%pt:
    %assign pgaddr (%1)
    %rep 1024
        pte pgaddr, (%2)
        %assign pgaddr pgaddr + 4096
    %endrep
%endmacro

; --- page_directory : build a PD from up to 1024 PT pointers ----------------
;  Usage: call the macro with pairs of (pt_label, flags)
;  e.g.  page_directory  pt_0, PTE_KERNEL, pt_kernel, PTE_KERNEL
;  This is complex — instead we provide a simpler builder macro below.
%macro page_directory_start 0
ALIGN 4096
%%pd:
%endmacro

; --- pde : emit one page directory entry ------------------------------------
;  %1 = page table physical address | %2 = flags
%macro pde 2
    dd      (%1) | (%2)
%endmacro

; --- build_identity_pd : create a PD that identity-maps first 8MB -----------
;  Emits: 1 PD (4096B) + 2 PTs (4096B each) = 12KB total
;  Entry 0 → PT0 (0x000000-0x3FFFFF, flags)
;  Entry 1 → PT1 (0x400000-0x7FFFFF, flags)
;  After this macro, call: mov eax, %%pd_base / mov cr3, eax
%macro build_identity_pd 1  ; %1 = PTE flags for all entries
ALIGN 4096
%%pd_base:
    dd      (%%pt0 - $$ + 0x100000) | (%1)      ; PDE 0 → PT0
    dd      (%%pt1 - $$ + 0x100000) | (%1)      ; PDE 1 → PT1
    times 1022 dd 0                              ; PDE 2-1023: not present

ALIGN 4096
%%pt0:
    %assign pg 0
    %rep 1024
        pte pg, (%1)
        %assign pg pg + 4096
    %endrep

ALIGN 4096
%%pt1:
    %assign pg 0x400000
    %rep 1024
        pte pg, (%1)
        %assign pg pg + 4096
    %endrep
%endmacro

; --- enable_paging : set CR3, enable CR0.PG (assumes PE is already on) ----
;  %1 = label of page directory (we take its address)
%macro enable_paging 1
    mov     eax, %1
    mov     cr3, eax              ; load page directory base into CR3
    mov     eax, cr0
    or      eax, 0x80000000       ; set PG bit (bit 31)
    mov     cr0, eax             ; enable paging!
%endmacro

; --- disable_paging : clear CR0.PG (dangerous, only for demos) ------------
%macro disable_paging 0
    mov     eax, cr0
    and     eax, 0x7FFFFFFF      ; clear PG bit
    mov     cr0, eax
%endmacro
