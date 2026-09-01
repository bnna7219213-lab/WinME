; ============================================================================
; gdt.inc — GDT (Global Descriptor Table) macros for 32-bit protected mode
; ----------------------------------------------------------------------------
;  Usage:  %include "common/gdt.inc"
;
;  Provides:
;    gdt_entry  base, limit, flags, access  — build one 8-byte descriptor
;    gdt_load   label                       — lgdt from a gdt_descriptor
;
;  Standard descriptor sets are provided as macros:
;    GDT_FLAT    — null + flat code + flat data (4GB each)
;    GDT_RING3   — flat + ring3 code + ring3 data (adds two entries)
; ============================================================================

; --- Descriptor field layout (x86 GDT entry, 8 bytes) ---
;   bits  0-15  : limit  low
;   bits 16-39  : base   low/mid
;   bits 40-47  : access byte
;   bits 48-51  : limit  high (bits 16-19)
;   bits 52-55  : flags   (Granularity, Size, L, Reserved)
;   bits 56-63  : base   high

struc gdt_entry_t
    .limit_lo   resw 1
    .base_lo    resw 1
    .base_mid   resb 1
    .access     resb 1
    .flags_lim  resb 1
    .base_hi    resb 1
endstruc

; Access byte bits:
;   7 Present | 6-5 DPL | 4 S(1=code/data) | 3 E/DT | 2 DC | 1 R/W | 0 A
ACCESS_RING0_CODE  equ 0x9A   ; Present, ring0, code, executable, read
ACCESS_RING0_DATA  equ 0x92   ; Present, ring0, data, writable
ACCESS_RING3_CODE  equ 0xFA   ; Present, ring3, code, executable, read
ACCESS_RING3_DATA  equ 0xF2   ; Present, ring3, data, writable

; Flags nibble (bits 52-55):
;   7 Granularity (1=4K) | 6 D/B (1=32-bit) | 5 L (64-bit, keep 0) | 4 Reserved
FLAG_4K_32BIT      equ 0xCF   ; G=1, D=1, L=0, 0

; --- gdt_entry : emit one 8-byte descriptor --------------------------------
;  %1=base(32)  %2=limit(20)  %3=access  %4=flags
%macro gdt_entry 4
    dw      (%2) & 0xFFFF                       ; limit 0-15
    dw      (%1) & 0xFFFF                       ; base  0-15
    db      ((%1) >> 16) & 0xFF                  ; base 16-23
    db      (%3) & 0xFF                          ; access
    db      (((%2) >> 16) & 0x0F) | ((%4) & 0xF0) ; flags + limit 16-19
    db      ((%1) >> 24) & 0xFF                  ; base 24-31
%endmacro

; --- GDT descriptor (pseudo-descriptor for lgdt) ----------------------------
struc gdt_desc_t
    .limit   resw 1
    .base    resd 1
endstruc

; --- gdt_load : lgdt from a named descriptor -------------------------------
%macro gdt_load 1
    lgdt    [%1]
%endmacro

; ============================================================================
; Standard GDT sets
; ============================================================================

; --- GDT_FLAT : null + ring0 code (4GB) + ring0 data (4GB) ------------------
;  Use after entering 32-bit mode. Selector 0x08 = code, 0x10 = data.
%macro GDT_FLAT 0
ALIGN 8
gdt_data:
    gdt_entry 0, 0, 0, 0                       ; null descriptor (selector 0x00)
    gdt_entry 0, 0xFFFFF, ACCESS_RING0_CODE, FLAG_4K_32BIT  ; code  (selector 0x08)
    gdt_entry 0, 0xFFFFF, ACCESS_RING0_DATA, FLAG_4K_32BIT  ; data  (selector 0x10)
gdt_descriptor:
    dw      gdt_data_end - gdt_data - 1
    dd      gdt_data
gdt_data_end:
%endmacro

; --- GDT_RING3 : GDT_FLAT + ring3 code + ring3 data + TSS -------------------
;  Selector 0x08 = ring0 code, 0x10 = ring0 data,
;  0x18 = ring3 code, 0x20 = ring3 data, 0x28 = TSS
%macro GDT_RING3 0
ALIGN 8
gdt_data:
    gdt_entry 0, 0, 0, 0                       ; null     (0x00)
    gdt_entry 0, 0xFFFFF, ACCESS_RING0_CODE, FLAG_4K_32BIT  ; ring0 code (0x08)
    gdt_entry 0, 0xFFFFF, ACCESS_RING0_DATA, FLAG_4K_32BIT  ; ring0 data (0x10)
    gdt_entry 0, 0xFFFFF, ACCESS_RING3_CODE, FLAG_4K_32BIT  ; ring3 code (0x18)
    gdt_entry 0, 0xFFFFF, ACCESS_RING3_DATA, FLAG_4K_32BIT  ; ring3 data (0x20)
    ; TSS descriptor (placeholder, 104 bytes minimum)
    gdt_entry 0, 0x67, 0x89, 0x40               ; TSS      (0x28) — present, ring0, 32-bit
gdt_descriptor:
    dw      gdt_data_end - gdt_data - 1
    dd      gdt_data
gdt_data_end:
%endmacro

; --- Selector constants (for convenience) -----------------------------------
SEL_CODE0    equ 0x08
SEL_DATA0    equ 0x10
SEL_CODE3    equ 0x18
SEL_DATA3    equ 0x20
SEL_TSS      equ 0x28
