# Test M-A4 (Win9x VDD + GUI): QEMU run + screenshot assertion
$ErrorActionPreference = "Continue"
$root = "C:\Users\bnna7\workspace\msdos-kernel"
$qemu = "C:\qemu\qemu-system-i386.exe"
$img  = "$root\win9x\win9x_a4.img"
$dbg  = "$root\win9x\dbg_a4.log"
$ppm  = "$root\win9x\_a4.ppm"
$runlog = "$root\win9x\_a4_run.log"
$mon  = 4484

function Log($s) {
    Write-Output $s
    Add-Content -Path $runlog -Value $s
}
# QEMU keeps dbg.log open for writing, so a plain ReadAllText fails with a
# sharing violation while the guest is still running -> read with FileShare.
function ReadShared($path) {
    if (-not (Test-Path $path)) { return "" }
    try {
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open,
              [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs)
        $t = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
        return $t
    } catch { return "" }
}
Remove-Item $runlog, $dbg, $ppm -Force -ErrorAction SilentlyContinue

Log "========== M-A4 QEMU run =========="
if (-not (Test-Path $img))   { Log ("[FAIL] image missing: " + $img);   exit 1 }
if (-not (Test-Path $qemu))  { Log ("[FAIL] qemu missing: " + $qemu);  exit 1 }

Get-Process qemu* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$p = Start-Process -FilePath $qemu -PassThru -NoNewWindow -ArgumentList @(
    "-fda", $img, "-boot", "a",
    "-m", "16",
    "-display", "none",
    "-no-reboot",
    "-debugcon", "file:$dbg",
    "-monitor", "tcp:127.0.0.1:$mon,server,nowait"
)
Log ("QEMU started pid=" + $p.Id)

# poll debug log until the self-check result appears
$deadline = (Get-Date).AddSeconds(12)
$seen = $false
$log = ""
$iter = 0
while ((Get-Date) -lt $deadline) {
    $log = ReadShared $dbg
    if ($log -match "DTSWC") { $seen = $true; break }
    $iter++
    if ($iter % 5 -eq 0) { Log ("  waiting " + $iter + "x200ms") }
    Start-Sleep -Milliseconds 200
}
Log ("self-check seen=" + $seen)
# let the VTD animation run to completion ([A4] DONE) before the screenshot
$deadline2 = (Get-Date).AddSeconds(8)
while ((Get-Date) -lt $deadline2) {
    $log = ReadShared $dbg
    if ($log -match "\[A4\] DONE") { break }
    Start-Sleep -Milliseconds 200
}
Log ("demo finished=" + ($log -match "\[A4\] DONE"))

# capture the screenshot via QEMU monitor (synchronous screendump)
$ppmPath = "C:/Users/bnna7/workspace/msdos-kernel/win9x/_a4.ppm"
try {
    $sock = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $mon)
    $s = $sock.GetStream()
    $w = New-Object System.IO.StreamWriter($s); $w.AutoFlush = $true
    Start-Sleep -Milliseconds 150
    $w.WriteLine("screendump $ppmPath")
    Start-Sleep -Milliseconds 500
    $w.WriteLine("quit")
    Start-Sleep -Milliseconds 200
    $sock.Close()
    Log "monitor: screendump + quit sent"
} catch {
    Log ("[warn] monitor screendump failed: " + $_)
}

# ensure QEMU is gone
Start-Sleep -Milliseconds 400
Get-Process qemu* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$log = ReadShared $dbg

Log "`n========== M-A4 debug log =========="
Log $log

# ---- assertions on debug log ----
$fail = 0
function Check($name, $cond) {
    if ($cond) { Log ("[PASS] " + $name) }
    else { Log ("[FAIL] " + $name); $global:fail++ }
}
Check "mode 13h set"            ($log -match "mode 13h")
Check "protected mode ON"       ($log -match "protected mode ON")
Check "DAC palette programmed"  ($log -match "DAC palette")
Check "framebuffer self-check V" ($log -match "DTSWCV")
Check "VMM+VTD armed"           ($log -match "VMM \+ VTD armed")
Check "demo DONE"               ($log -match "\[A4\] DONE")
Check "VTD drove the System VM" ($log -match "VM SYS  ticks=([1-9]\d*)")

# ---- parse the PPM screenshot and assert colors ----
Log "`n========== M-A4 screenshot (_a4.ppm) =========="
if (-not (Test-Path $ppm)) {
    Check "PPM screenshot produced" $false
} else {
    $bytes = [System.IO.File]::ReadAllBytes($ppm)
    # NOTE: compare raw byte VALUES here.  Using a '\s' regex would stringify the
    # byte (32 -> "32") and never match, which spins forever.
    $isWs = { param($b) ($b -eq 32) -or ($b -eq 9) -or ($b -eq 10) -or ($b -eq 13) }
    $pos = 0
    $toks = @()
    while (($toks.Count -lt 4) -and ($pos -lt 128)) {
        while (($pos -lt $bytes.Length) -and (& $isWs $bytes[$pos])) { $pos++ }
        if ($bytes[$pos] -eq 35) {                       # '#' comment line
            while (($pos -lt $bytes.Length) -and ($bytes[$pos] -ne 10)) { $pos++ }
            continue
        }
        $sb = New-Object System.Text.StringBuilder
        while (($pos -lt $bytes.Length) -and (-not (& $isWs $bytes[$pos]))) {
            [void]$sb.Append([char]$bytes[$pos]); $pos++
        }
        $toks += $sb.ToString()
    }
    $pos++                                               # single ws after maxval
    $m  = $toks[0]
    $w  = [int]$toks[1]
    $h  = [int]$toks[2]
    $mx = [int]$toks[3]
    Log ("PPM: magic=$m size=${w}x${h} maxval=$mx ($($bytes.Length) bytes)")

    Check "PPM screenshot produced" $true
    # QEMU renders mode 13h through the VGA double-scan path, so the dump may be
    # an integer multiple of 320x200 - accept that and scale the sample points.
    $sx = [int]($w / 320)
    $sy = [int]($h / 200)
    Check "PPM is P6, 320x200 aspect" (($m -eq "P6") -and ($sx -ge 1) -and ($sy -ge 1) -and ($sx*320 -eq $w) -and ($sy*200 -eq $h))
    Log ("scale = ${sx}x${sy}")

    function Pix($x, $y) {
        $px = $x * $sx; $py = $y * $sy
        $off = $pos + ($py * $w + $px) * 3
        return @($bytes[$off], $bytes[$off+1], $bytes[$off+2])
    }
    $d  = Pix 5 5
    $tb = Pix 160 190
    $sb = Pix 60 195
    $ti = Pix 120 39
    $cl = Pix 120 110
    $tx = Pix 47 36
    Log ("desktop(5,5)=$d taskbar(160,190)=$tb startbtn(60,195)=$sb")
    Log ("title(120,39)=$ti client(120,110)=$cl titletext(47,36)=$tx")
    Check "desktop teal"      (($d[0] -lt 40) -and ($d[1] -ge 100) -and ($d[1] -le 160) -and ($d[2] -ge 100) -and ($d[2] -le 160))
    Check "taskbar gray"      (($tb[0] -ge 170) -and ($tb[1] -ge 170) -and ($tb[2] -ge 170))
    Check "start button gray" (($sb[0] -ge 170) -and ($sb[1] -ge 170) -and ($sb[2] -ge 170))
    Check "title bar navy"    (($ti[0] -lt 40) -and ($ti[1] -lt 40) -and ($ti[2] -ge 100) -and ($ti[2] -le 160))
    Check "client white"      (($cl[0] -ge 240) -and ($cl[1] -ge 240) -and ($cl[2] -ge 240))
    Check "title text white"  (($tx[0] -ge 240) -and ($tx[1] -ge 240) -and ($tx[2] -ge 240))

    # count distinct colours - a real GUI scene must use the whole palette
    $seenCol = @{}
    for ($y = 0; $y -lt 200; $y += 2) {
        $rowBase = $pos + ($y * $sy) * $w * 3
        for ($x = 0; $x -lt 320; $x += 4) {
            $o = $rowBase + ($x * $sx) * 3
            $seenCol[[int]$bytes[$o] * 65536 + [int]$bytes[$o+1] * 256 + [int]$bytes[$o+2]] = 1
        }
    }
    Log ("distinct colours = " + $seenCol.Count)
    Check "scene uses >=5 palette entries" ($seenCol.Count -ge 5)
}

Log "`n========== M-A4 SUMMARY =========="
if ($fail -eq 0) { Log "ALL PASS - M-A4 Win9x VDD+GUI verified" }
else { Log ("$fail CHECK(S) FAILED") }
exit $fail
