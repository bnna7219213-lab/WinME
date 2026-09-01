# run axis A and dump registers via monitor
$root = "C:\Users\bnna7\workspace\msdos-kernel"
$qemu = "C:\qemu\qemu-system-i386.exe"
$dbg = "$root\win9x\dbg.log"
if (Test-Path $dbg) { Remove-Item $dbg -Force -ErrorAction SilentlyContinue }

$p = Start-Process -FilePath $qemu -ArgumentList @(
    "-fda","$root\win9x\win9x.img","-boot","a","-m","32",
    "-display","none","-debugcon","file:$dbg",
    "-monitor","tcp:127.0.0.1:4490,server,nowait","-no-reboot"
) -PassThru -NoNewWindow
Start-Sleep -Seconds 3

# dump registers
try {
    $sock = New-Object System.Net.Sockets.TcpClient("127.0.0.1",4490)
    $s = $sock.GetStream()
    $w = New-Object System.IO.StreamWriter($s); $w.AutoFlush=$true
    Start-Sleep -Milliseconds 200
    $w.WriteLine("info registers") | Out-Null
    Start-Sleep -Milliseconds 500
    # read response
    Start-Sleep -Milliseconds 300
    $sock.Close()
    Write-Host "monitor commands sent"
} catch { Write-Host "monitor failed: $_" }

Start-Sleep -Seconds 2
if (-not $p.HasExited) { try { $p.Kill() } catch {} }
Start-Sleep -Milliseconds 500

Write-Host "--- dbg.log ---"
if (Test-Path $dbg) {
    $lines = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($dbg))
    Write-Host $lines
} else {
    Write-Host "[FAIL] No dbg.log"
}