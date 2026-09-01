# check pm32_entry bytes in kernel.bin
$b = [System.IO.File]::ReadAllBytes('C:\Users\bnna7\workspace\msdos-kernel\win9x\build\kernel.bin')
# find "PMO" pattern in hex
for ($i=0; $i -lt $b.Length-3; $i++) {
    if ($b[$i] -eq 0x50 -and $b[$i+1] -eq 0x4D -and $b[$i+2] -eq 0x4F) {
        Write-Host ("'PMO' found at offset " + $i)
        # dump 20 bytes before and after
        $start = [Math]::Max(0, $i-20)
        $end = [Math]::Min($b.Length-1, $i+20)
        for ($j=$start; $j -le $end; $j++) {
            $c = if ($b[$j] -ge 0x20 -and $b[$j] -le 0x7E) { [char]$b[$j] } else { '.' }
            Write-Host ("  " + $j.ToString("X4") + ": " + $b[$j].ToString("X2") + "   " + $c)
        }
        break
    }
}
# find "PMO" in the data section (pm_on_msg string)
for ($i=0; $i -lt $b.Length-3; $i++) {
    if ($b[$i] -eq 0x50 -and $b[$i+1] -eq 0x4D -and $b[$i+2] -eq 0x4F) { continue }  # skip code
    if ($b[$i] -eq 0x50 -and $b[$i+1] -eq 0x4D -and $b[$i+2] -eq 0x4F) {
        Write-Host ("'PMO' in data at offset " + $i)
    }
}
# Find the 'K' byte (0x4B) - is it in the code?
$kcount = 0
for ($i=0; $i -lt $b.Length; $i++) { if ($b[$i] -eq 0x4B) { $kcount++ } }
Write-Host ("Total 0x4B ('K') bytes in file: " + $kcount)