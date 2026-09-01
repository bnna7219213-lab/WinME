$ErrorActionPreference = "Continue"
$qemu = "C:\qemu\qemu-system-i386.exe"
$img = "C:\Users\bnna7\workspace\msdos-kernel\win9x\win9x.img"
$dbg = "C:\Users\bnna7\workspace\msdos-kernel\win9x\dbg.log"
Remove-Item $img -Force -ErrorAction SilentlyContinue
Copy-Item "C:\Users\bnna7\workspace\msdos-kernel\dos.img" $img

$log = $dbg
$p = Start-Process -NoNewWindow -PassThru -FilePath $qemu -ArgumentList @(
    "-fda", $img, "-nographic", "-debugcon", "file:$log", "-m", "16M",
    "-no-reboot", "-d", "int,cpu_reset"
)
Start-Sleep -Seconds 8
Stop-Process -Name "qemu-system-i386" -Force -ErrorAction SilentlyContinue

Write-Host "=== Debug Log (last 80 lines) ==="
if (Test-Path $log) {
    Get-Content $log | Select-Object -Last 80
} else {
    Write-Host "[NO LOG]"
}