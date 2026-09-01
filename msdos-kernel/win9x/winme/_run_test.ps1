$ErrorActionPreference = 'SilentlyContinue'
Stop-Process -Name qemu-system-i386 -ErrorAction SilentlyContinue
Start-Sleep 1
Set-Location "C:\Users\bnna7\workspace\msdos-kernel\win9x\winme"
Remove-Item debug2.txt -ErrorAction SilentlyContinue
Remove-Item out2.txt -ErrorAction SilentlyContinue
$p = Start-Process -FilePath "C:\qemu\qemu-system-i386.exe" -NoNewWindow -ArgumentList @("-drive","file=winme.img,format=raw,index=0,media=disk","-m","32","-debugcon","file:debug2.txt","-serial","null","-netdev","user,id=net0","-device","rtl8139,netdev=net0","-no-reboot","-no-shutdown")
Start-Sleep 20
Write-Host "QEMU PID=$($p.Id) EXITED=$($p.HasExited)"
if (Test-Path debug2.txt) {
    Write-Host "=== FIRST 30 ==="
    Get-Content debug2.txt | Select-Object -First 30
    Write-Host "=== LAST 30 ==="
    Get-Content debug2.txt | Select-Object -Last 30
    Write-Host "=== PF COUNT ==="
    $pf = Select-String -Path debug2.txt -Pattern "PF"
    Write-Host $pf.Count
    Write-Host "=== DONE COUNT ==="
    $done = Select-String -Path debug2.txt -Pattern "DONE"
    Write-Host $done.Count
} else {
    Write-Host "NO debug2.txt"
}
$p.Kill()