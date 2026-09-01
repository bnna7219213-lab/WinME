# _qemu_test.ps1 — Pack and QEMU-test all four axes (v3)
$root = "C:\Users\bnna7\workspace\msdos-kernel"
$qemu = "C:\qemu\qemu-system-i386.exe"

# ---- Helper: run QEMU, wait for exit, capture debug log ----
function Run-Qemu([string]$img, [string]$dbgLog, [int]$waitSec = 4) {
    if (Test-Path $dbgLog) { try { Remove-Item $dbgLog -Force -ErrorAction SilentlyContinue } catch {} }
    $p = Start-Process -FilePath $qemu -ArgumentList @(
        "-fda",$img,"-boot","a","-m","32",
        "-display","none","-debugcon","file:$dbgLog",
        "-no-reboot"
    ) -PassThru -NoNewWindow
    Write-Host "  qemu pid=$($p.Id) waiting ${waitSec}s..."
    Start-Sleep -Seconds $waitSec
    if (-not $p.HasExited) { try { $p.Kill() } catch {} }
    Start-Sleep -Milliseconds 500
    if (Test-Path $dbgLog) {
        for ($i=0; $i -lt 5; $i++) {
            try {
                $b = [System.IO.File]::ReadAllBytes($dbgLog)
                return [System.Text.Encoding]::ASCII.GetString($b)
            } catch {
                Start-Sleep -Milliseconds 200
            }
        }
    }
    return ""
}

# ========== AXIS A: Win9x (M-A1 + A2 in win95/, A3 in win98/, A4 in winme/) ==========
Write-Host "`n========== AXIS A: Win9x (win95: M-A1 PM round-trip) ==========" -ForegroundColor Cyan
# Build the win95 generation image (M0 real-mode boot + A1/A2 kernel) via its own build.bat
& cmd /c "$root\win9x\win95\build.bat" 2>&1 | Out-Null
$imgA = "$root\win9x\win95\win95.img"
$dbgA = "$root\win9x\win95\dbg.log"
Write-Host "  win95.img: $(Get-Item $imgA -ErrorAction SilentlyContinue | ForEach-Object Length) bytes"

# Run with monitor to type "pm"
if (Test-Path $dbgA) { Remove-Item $dbgA -Force -ErrorAction SilentlyContinue }
$pA = Start-Process -FilePath $qemu -ArgumentList @(
    "-fda",$imgA,"-boot","a","-m","32",
    "-display","none","-debugcon","file:$dbgA",
    "-monitor","tcp:127.0.0.1:4481,server,nowait","-no-reboot"
) -PassThru -NoNewWindow
Start-Sleep -Seconds 2
if (-not $pA.HasExited) {
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
    } catch { Write-Host "  [warn] monitor connect failed" }
}
Start-Sleep -Seconds 2
if (-not $pA.HasExited) { try { $pA.Kill() } catch {} }
Start-Sleep -Milliseconds 500

$linesA = ""
if (Test-Path $dbgA) {
    for ($i=0; $i -lt 5; $i++) {
        try { $linesA = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($dbgA)); break }
        catch { Start-Sleep -Milliseconds 200 }
    }
}
Write-Host "--- dbg.log ---" -ForegroundColor Gray
Write-Host $linesA
if ($linesA -match "M-A1" -and $linesA -match "PROTECTED MODE ON") {
    Write-Host "[PASS] Axis A (win95 M-A1): PM switch OK" -ForegroundColor Green
} else {
    Write-Host "[CHECK] Axis A: see output above" -ForegroundColor Yellow
}

# ========== AXIS B: WinNT (M-B1) ==========
Write-Host "`n========== AXIS B: WinNT (M-B1, 32-bit + paging) ==========" -ForegroundColor Cyan
$imgB = "$root\winnt\winnt.img"
$dbgB = "$root\winnt\dbg.log"
& powershell -NoProfile -ExecutionPolicy Bypass -File "$root\common\pack32.ps1" `
    -Boot "$root\common\build\boot32.bin" -Kernel "$root\winnt\build\kernel32.bin" `
    -OutImage $imgB 2>&1
$linesB = Run-Qemu $imgB $dbgB 4
Write-Host "--- dbg.log ---" -ForegroundColor Gray
Write-Host $linesB
if ($linesB -match "NT-LIKE 32BIT KERNEL" -and $linesB -match "M-B1 kernel halt") {
    Write-Host "[PASS] Axis B (M-B1): 32-bit kernel + paging OK" -ForegroundColor Green
} else {
    Write-Host "[CHECK] Axis B: see output above" -ForegroundColor Yellow
}

# ========== AXIS C: Win2K (M-C1) ==========
Write-Host "`n========== AXIS C: Win2K (M-C1, version structure) ==========" -ForegroundColor Cyan
$imgC = "$root\win2k\win2k.img"
$dbgC = "$root\win2k\dbg.log"
& powershell -NoProfile -ExecutionPolicy Bypass -File "$root\common\pack32.ps1" `
    -Boot "$root\common\build\boot32.bin" -Kernel "$root\win2k\build\kernel32.bin" `
    -OutImage $imgC 2>&1
$linesC = Run-Qemu $imgC $dbgC 4
Write-Host "--- dbg.log ---" -ForegroundColor Gray
Write-Host $linesC
if ($linesC -match "Windows 2000" -and $linesC -match "v5.0.2195" -and $linesC -match "M-C1 kernel halt") {
    Write-Host "[PASS] Axis C (M-C1): version structure OK" -ForegroundColor Green
} else {
    Write-Host "[CHECK] Axis C: see output above" -ForegroundColor Yellow
}

# ========== AXIS D: WinXP (M-D1) ==========
Write-Host "`n========== AXIS D: WinXP (M-D1, NT5.1 + LPC) ==========" -ForegroundColor Cyan
# M-D1 and M-D2 keep separate images/intermediates (see winxp/README.md), so
# this smoke test must use the D1-specific names.
$imgD = "$root\winxp\winxp_d1.img"
$dbgD = "$root\winxp\dbg_d1.log"
& powershell -NoProfile -ExecutionPolicy Bypass -File "$root\common\pack32.ps1" `
    -Boot "$root\winxp\build\boot32_d1.bin" -Kernel "$root\winxp\build\kernel32_d1.bin" `
    -OutImage $imgD 2>&1
$linesD = Run-Qemu $imgD $dbgD 4
Write-Host "--- dbg.log ---" -ForegroundColor Gray
Write-Host $linesD
if ($linesD -match "Windows XP" -and $linesD -match "v5.1.2600" -and $linesD -match "LPC" -and $linesD -match "M-D1 kernel halt") {
    Write-Host "[PASS] Axis D (M-D1): NT 5.1 + LPC OK" -ForegroundColor Green
} else {
    Write-Host "[CHECK] Axis D: see output above" -ForegroundColor Yellow
}

# ---- Summary ----
Write-Host "`n========== SUMMARY ==========" -ForegroundColor Yellow
$all = @(
    @("Axis A (Win9x M-A1)", $linesA),
    @("Axis B (WinNT M-B1)", $linesB),
    @("Axis C (Win2K  M-C1)", $linesC),
    @("Axis D (WinXP  M-D1)", $linesD)
)
$passed = 0; $failed = 0
foreach ($r in $all) {
    $has = if ($r[1] -and $r[1].Length -gt 0) { "has output ($($r[1].Length) chars)" } else { "NO output" }
    Write-Host "  $($r[0]): $has"
    if ($r[1] -and $r[1].Length -gt 0) { $passed++ } else { $failed++ }
}
Write-Host "Passed: $passed / 4" -ForegroundColor $(if ($passed -eq 4) { "Green" } else { "Yellow" })