$ErrorActionPreference = 'SilentlyContinue'
Stop-Process -Name qemu-system-i386 -ErrorAction SilentlyContinue
Stop-Process -Name python -ErrorAction SilentlyContinue
Start-Sleep 1
Set-Location "C:\Users\bnna7\workspace\msdos-kernel\win9x\winme"
Remove-Item debug2.txt -ErrorAction SilentlyContinue
Remove-Item out2.txt -ErrorAction SilentlyContinue

# Start HTTP server serving A4-EXE payload on port 8080
$py = Start-Process -FilePath "python" -NoNewWindow -ArgumentList @("a4_server.py")
Start-Sleep 1
Write-Host "Python HTTP server PID=$($py.Id)"

# Start QEMU with network backend
$p = Start-Process -FilePath "C:\qemu\qemu-system-i386.exe" -NoNewWindow -ArgumentList @(
    "-drive","file=winme.img,format=raw,index=0,media=disk",
    "-m","32",
    "-netdev","user,id=net0,hostfwd=tcp::8080-:8080",
    "-device","e1000,netdev=net0,addr=0x1a",
    "-debugcon","file:debug2.txt",
    "-serial","null",
    "-no-reboot","-no-shutdown"
)
Start-Sleep 25
Write-Host "QEMU PID=$($p.Id) EXITED=$($p.HasExited)"

if (Test-Path debug2.txt) {
    Write-Host "=== FIRST 40 ==="
    Get-Content debug2.txt | Select-Object -First 40
    Write-Host "=== LAST 40 ==="
    Get-Content debug2.txt | Select-Object -Last 40
    Write-Host "=== PF COUNT ==="
    $pf = Select-String -Path debug2.txt -Pattern "PF"
    Write-Host $pf.Count
    Write-Host "=== DONE COUNT ==="
    $done = Select-String -Path debug2.txt -Pattern "DONE"
    Write-Host $done.Count
    Write-Host "=== DL:OK COUNT ==="
    $dl = Select-String -Path debug2.txt -Pattern "DL:OK"
    Write-Host $dl.Count
    Write-Host "=== VM OK COUNT ==="
    $vm = Select-String -Path debug2.txt -Pattern "VM OK"
    Write-Host $vm.Count
    Write-Host "=== SYN-ACK COUNT ==="
    $syn = Select-String -Path debug2.txt -Pattern "SYN-ACK"
    Write-Host $syn.Count
    Write-Host "=== TCTL COUNT ==="
    $tctl = Select-String -Path debug2.txt -Pattern "TCTL fixed"
    Write-Host $tctl.Count
    Write-Host "=== RX COUNT ==="
    $rx = Select-String -Path debug2.txt -Pattern "RX:"
    Write-Host $rx.Count
    Write-Host "=== dl_valid COUNT ==="
    $dv = Select-String -Path debug2.txt -Pattern "dl_valid"
    Write-Host $dv.Count
    Write-Host "=== TCP data COUNT ==="
    $td = Select-String -Path debug2.txt -Pattern "TCP: data"
    Write-Host $td.Count
} else {
    Write-Host "NO debug2.txt"
}
$p.Kill()
$py.Kill()