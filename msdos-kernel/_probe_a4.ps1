$i = 0
Write-Output ("PROBE START " + (Get-Date))
while ($i -lt 8) {
    Write-Output ("PROBE tick " + $i + " " + (Get-Date).ToString("HH:mm:ss"))
    Start-Sleep -Seconds 1
    $i++
}
Write-Output ("PROBE END " + (Get-Date))
