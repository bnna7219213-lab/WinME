section .text
    org 0x0000

; Test 1: BITS 16 far jump
BITS 16
    jmp far word 0x08:target16

; Test 2: explicit encoding
    db 0xEA
    dw target16, 0x08

    times 100 db 0

BITS 32
target16:
    nop