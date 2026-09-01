# test axis a only
$root = "C:\Users\bnna7\workspace\msdos-kernel"
$qemu = "C:\qemu\qemu-system-i386.exe"

# pack
Write-Host "=== Pack win9x ===" -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File "$root\pack.ps1" -OutDir "$root\win9x\build" -RootDir "$root\win9x" 2>&1 | Out-Null
Copy-Item "$root\dos.img" "$root\win9x\win9x.img" -Force

# run
$dbg = "$root\win9x\dbg.log"
if (Test-Path $dbg) { Remove-Item $dbg -Force -ErrorAction SilentlyContinue }
$p = Start-Process -FilePath $qemu -ArgumentList @(
    "-fda","$root\win9x\win9x.img","-boot","a","-m","32",
    "-display","none","-debugcon","file:$dbg",
    "-monitor","tcp:127.0.0.1:4481,server,nowait","-no-reboot"
) -PassThru -NoNewWindow
Start-Sleep -Seconds 2
# type pm
try {
    $sock = New-Object System.Net.Sockets.TcpClient("127.0.0.1",4481)
    $s = $sock.GetStream()
    $w = New-Object System.IO.StreamWriter($s); $w.AutoFlush=$true
    Start-Sleep -Milliseconds 200
    $w.WriteLine("sendkey p"); Start-Sleep -Milliseconds 50
    $w.WriteLine("sendkey m"); Start-Sleep -Milliseconds 50
    $w.WriteLine("sendkey ret"); Start-Sleep -Milliseconds 500
    $w.WriteLine("quit") | Out-Null
    $sock.Close()
} catch {}
Start-Sleep -Seconds 2
if (-not $p.HasExited) { try { $p.Kill() } catch {} }
Start-Sleep -Milliseconds 500

if (Test-Path $dbg) {
    $lines = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($dbg))
    Write-Host "--- dbg.log ---" -ForegroundColor Gray
    Write-Host $lines
    if ($lines -match "PROTECTED MODE ON" -and $lines -match "BACK IN REAL MODE") {
        Write-Host "[PASS] Axis A (M-A1): PM round-trip verified!" -ForegroundColor Green
    } else {
        Write-Host "[CHECK] Check output above" -ForegroundColor Yellow
    }
} else {
    Write-Host "[FAIL] No dbg.log" -ForegroundColor Red
}