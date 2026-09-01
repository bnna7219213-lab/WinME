$bin = [System.IO.File]::ReadAllBytes('c:\Users\bnna7\workspace\msdos-kernel\win9x\winme\build\kernel32.bin')
# lgdt at offset 0x1A: 0F 01 15 <4-byte addr>
$addr = [uint32]$bin[0x1C] -bor (([uint32]$bin[0x1D] -shl 8)) -bor (([uint32]$bin[0x1E] -shl 16)) -bor (([uint32]$bin[0x1F] -shl 24))
Write-Output ("winme lgdt operand: 0x{0:X8}" -f $addr)

# Also check winxp
$xbin = [System.IO.File]::ReadAllBytes('c:\Users\bnna7\workspace\msdos-kernel\winxp\build\kernel32_d2.bin')
# lgdt at offset 0x12: 0F 01 15 <4-byte addr>
$xaddr = [uint32]$xbin[0x14] -bor (([uint32]$xbin[0x15] -shl 8)) -bor (([uint32]$xbin[0x16] -shl 16)) -bor (([uint32]$xbin[0x17] -shl 24))
Write-Output ("winxp lgdt operand: 0x{0:X8}" -f $xaddr)

# Check dd gdt_data in winme (at offset 0x1E8C2)
$gbase = [uint32]$bin[0x1E8C2] -bor (([uint32]$bin[0x1E8C3] -shl 8)) -bor (([uint32]$bin[0x1E8C4] -shl 16)) -bor (([uint32]$bin[0x1E8C5] -shl 24))
Write-Output ("winme dd gdt_data: 0x{0:X8}" -f $gbase)

# Check dd gdt_data in winxp (at offset 0x253A)
$xgbase = [uint32]$xbin[0x253A] -bor (([uint32]$xbin[0x253B] -shl 8)) -bor (([uint32]$xbin[0x253C] -shl 16)) -bor (([uint32]$xbin[0x253D] -shl 24))
Write-Output ("winxp dd gdt_data: 0x{0:X8}" -f $xgbase)

Write-Output ("`nwinxp bin size: {0} (0x{0:X})" -f $xbin.Length)
Write-Output ("winme bin size: {0} (0x{0:X})" -f $bin.Length)
