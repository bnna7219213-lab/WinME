$bin = [System.IO.File]::ReadAllBytes('c:\Users\bnna7\workspace\msdos-kernel\win9x\winme\build\kernel32.bin')
Write-Output ("kernel32.bin size: {0} bytes (0x{0:X})" -f $bin.Length)
Write-Output ("gdt_desc_local at offset 0x1E8C0:")
Write-Output ("  file size = 0x{0:X}, gdt_desc_local offset = 0x{1:X}" -f $bin.Length, 0x1E8C0)
if(0x1E8C0 -lt $bin.Length){
    for($i=0;$i -lt 8;$i++){
        Write-Output ("  [0x{0:X}] = 0x{1:X2}" -f (0x1E8C0+$i), $bin[0x1E8C0+$i])
    }
}else{
    Write-Output "  OUT OF RANGE — gdt_desc_local is beyond bin file!"
}
