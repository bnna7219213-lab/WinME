$lines = [System.IO.File]::ReadAllLines('C:\Users\bnna7\workspace\msdos-kernel\win9x\winme\_net_test.log')
Write-Output "Total lines: $($lines.Count)"
for($i = 75; $i -lt [Math]::Min(130, $lines.Count); $i++) {
    Write-Output "$i : $($lines[$i])"
}