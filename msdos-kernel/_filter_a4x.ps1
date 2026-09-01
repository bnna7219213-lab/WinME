$log = 'C:\Users\bnna7\workspace\msdos-kernel\win9x\a4x_dbg.log'
$lines = [System.IO.File]::ReadAllLines($log)
$i = 0
foreach ($l in $lines) {
    if ($l -match '\[A4X\] (demo:|EX|FAULT|paint:|CreateWindow x6|VIN|DONE)') {
        Write-Output $l
        $i++
        if ($i -ge 40) { break }
    }
}
