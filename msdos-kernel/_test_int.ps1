# run QEMU with int logging for axis A
$root = "C:\Users\bnna7\workspace\msdos-kernel"
$qemu = "C:\qemu\qemu-system-i386.exe"
$dbg = "$root\win9x\dbg.log"
$log = "$root\win9x\qemu_int.log"
if (Test-Path $dbg) { Remove-Item $dbg -Force -ErrorAction SilentlyContinue }
if (Test-Path $log) { Remove-Item $log -Force -ErrorAction SilentlyContinue }

$p = Start-Process -FilePath $qemu -ArgumentList @(
    "-fda","$root\win9x\win9x.img","-boot","a","-m","32",
    "-display","none","-debugcon","file:$dbg",
    "-d","int,cpu_reset","-D",$log,
    "-no-reboot"
) -PassThru -NoNewWindow
Start-Sleep -Seconds 3
if (-not $p.HasExited) { try { $p.Kill() } catch {} }
Start-Sleep -Milliseconds 500

Write-Host "--- dbg.log ---"
if (Test-Path $dbg) {
    $lines = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($dbg))
    Write-Host $lines
}
Write-Host "`n--- qemu_int.log (last 60 lines) ---"
if (Test-Path $log) {
    $lines = [System.IO.File]::ReadAllLines($log)
    $start = [Math]::Max(0, $lines.Length - 60)
    for ($i=$start; $i -lt $lines.Length; $i++) { Write-Host $lines[$i] }
} else {
    Write-Host "[FAIL] No int log"
}