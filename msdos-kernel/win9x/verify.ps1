# win9x/verify.ps1 — Headless verification of M-A1 (PM switch round-trip)
$ErrorActionPreference = "Stop"
$root   = $PSScriptRoot
$qemu   = "C:\qemu\qemu-system-i386.exe"
$img    = Join-Path $root "win9x.img"
$dbg    = Join-Path $root "dbg.log"
$port   = 4471

if (Test-Path $dbg) { Remove-Item $dbg -ErrorAction SilentlyContinue }

$p = Start-Process -FilePath $qemu -ArgumentList @(
    "-fda",$img,"-boot","a",
    "-display","none","-debugcon","file:$dbg",
    "-monitor","tcp:127.0.0.1:$port,server,nowait","-no-reboot"
) -PassThru -NoNewWindow

Write-Host "[*] qemu pid = $($p.Id)"

$sock = $null
function Open-Mon { $script:sock = New-Object System.Net.Sockets.TcpClient("127.0.0.1",$port) }
function Mon ($line) {
    $s = $script:sock.GetStream()
    $w = New-Object System.IO.StreamWriter($s); $w.AutoFlush=$true
    Start-Sleep -Milliseconds 120; $w.WriteLine($line); Start-Sleep -Milliseconds 200; $w.Flush()
}
function Type ($text) {
    foreach ($c in $text.ToCharArray()) { Mon "sendkey $c"; Start-Sleep -Milliseconds 50 }
    Mon "sendkey ret"; Start-Sleep -Milliseconds 300
}

for ($i=0; $i -lt 15; $i++) {
    try { Open-Mon; break } catch { Start-Sleep -Milliseconds 300 }
}
if ($null -eq $sock) { Write-Host "[!] monitor never opened"; exit 1 }
Write-Host "[*] monitor up"

Start-Sleep -Seconds 1
Type "pm"
Type "ver"
Type "help"

Mon "quit" | Out-Null
Start-Sleep -Seconds 1
if (-not $p.HasExited) { try { $p.Kill() } catch {} }

Write-Host "===== dbg.log (0xE9 output) ====="
$b = [System.IO.File]::ReadAllBytes($dbg)
$lines = [System.Text.Encoding]::ASCII.GetString($b)
Write-Host $lines

# --- Verify expectations ---
$ok = $true
if ($lines -notmatch "PROTECTED MODE ON")  { Write-Host "[FAIL] PM entry not detected"; $ok = $false }
if ($lines -notmatch "BACK IN REAL MODE")   { Write-Host "[FAIL] RM return not detected"; $ok = $false }
if ($lines -notmatch "CR0=")                { Write-Host "[FAIL] CR0 dump not detected"; $ok = $false }

if ($ok) { Write-Host "`n[PASS] M-A1 PM round-trip verified." -ForegroundColor Green }
else     { Write-Host "`n[FAIL] M-A1 verification failed." -ForegroundColor Red }
