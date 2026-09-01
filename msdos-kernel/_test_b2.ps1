# _test_b2.ps1 — QEMU test for M-B2
$root = "C:\Users\bnna7\workspace\msdos-kernel"
$qemu = "C:\qemu\qemu-system-i386.exe"
$img  = Join-Path $root "winnt\winnt_b2.img"
$dbg  = Join-Path $root "winnt\b2_dbg.log"

# Rebuild kernel
& "C:\mingw64\mingw64\bin\nasm.exe" -f bin -I $root `
    (Join-Path $root "winnt\src\b2_iomgr.asm") `
    -o (Join-Path $root "winnt\build\b2-kernel.bin") | Out-Null

# Re-pack
& "powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "common\pack32.ps1") `
    -Boot (Join-Path $root "common\build\boot32.bin") `
    -Kernel (Join-Path $root "winnt\build\b2-kernel.bin") `
    -OutImage $img | Out-Null

if (Test-Path $dbg) { Remove-Item $dbg -Force -ErrorAction SilentlyContinue }

$p = Start-Process -FilePath $qemu -ArgumentList @(
    "-fda",$img,"-boot","a","-m","32",
    "-display","none","-debugcon","file:$dbg",
    "-no-reboot"
) -PassThru -NoNewWindow

Write-Host "qemu pid=$($p.Id)"
Start-Sleep -Seconds 10

if (-not $p.HasExited) { try { $p.Kill() } catch {} }
Start-Sleep -Milliseconds 500

if (Test-Path $dbg) {
    $b = [System.IO.File]::ReadAllBytes($dbg)
    $text = [System.Text.Encoding]::ASCII.GetString($b)
    Write-Host "===== output ($($b.Length) bytes) ====="
    Write-Host $text
} else { Write-Host "NO LOG" }