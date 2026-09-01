# Test M-A4+ (Win9x enhanced GUI): QEMU run + debug log assertions + PPM screenshot checks
$ErrorActionPreference = "Continue"
$root = "C:\Users\bnna7\workspace\msdos-kernel"
$qemu = "C:\qemu\qemu-system-i386.exe"
$img  = "$root\win9x\win9x.img"
$dbg  = "$root\win9x\a4x_dbg.log"
$ppm  = "$root\win9x\_a4x.ppm"
$runlog = "$root\win9x\_a4x_run.log"
$mon  = 4486

function Log($s) {
    Write-Output $s
    Add-Content -Path $runlog -Value $s
}
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

Log "========== M-A4+ QEMU run =========="
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

# poll debug log for [A4X] DONE
$deadline = (Get-Date).AddSeconds(20)
$seen = $false
$log = ""
$iter = 0
while ((Get-Date) -lt $deadline) {
    $log = ReadShared $dbg
    if ($log -match "\[A4X\] DONE") { $seen = $true; break }
    $iter++
    if ($iter % 5 -eq 0) { Log ("  waiting " + $iter + "x200ms") }
    Start-Sleep -Milliseconds 200
}
Log ("[A4X] DONE seen=" + $seen)

# capture screenshot via QEMU monitor
$ppmPath = "C:/Users/bnna7/workspace/msdos-kernel/win9x/_a4x.ppm"
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

Start-Sleep -Milliseconds 400
Get-Process qemu* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$log = ReadShared $dbg

Log "`n========== M-A4+ debug log =========="
Log $log

# ---- assertions on debug log ----
$fail = 0
function Check($name, $cond) {
    if ($cond) { Log ("[PASS] " + $name) }
    else { Log ("[FAIL] " + $name); $global:fail++ }
}
Check "init probe A123456789:;<" ($log -match "A123456789:;<")
Check "CreateWindow x6"       ($log -match "CreateWindow x6")
Check "VIN script loaded"     ($log -match "VIN script loaded")
Check "menu show"             ($log -match "menu show")
Check "window moved"          ($log -match "window moved")
Check "context menu"          ($log -match "context menu")
Check "window closed"         ($log -match "window closed")
Check "A4X DONE"              ($log -match "\[A4X\] DONE")

# ---- PPM assertions ----
Log "`n========== M-A4+ screenshot (_a4x.ppm) =========="
if (-not (Test-Path $ppm)) {
    Check "PPM screenshot produced" $false
} else {
    $bytes = [System.IO.File]::ReadAllBytes($ppm)
    $isWs = { param($b) ($b -eq 32) -or ($b -eq 9) -or ($b -eq 10) -or ($b -eq 13) }
    $pos = 0
    $toks = @()
    while (($toks.Count -lt 4) -and ($pos -lt 128)) {
        while (($pos -lt $bytes.Length) -and (& $isWs $bytes[$pos])) { $pos++ }
        if ($bytes[$pos] -eq 35) {
            while (($pos -lt $bytes.Length) -and ($bytes[$pos] -ne 10)) { $pos++ }
            continue
        }
        $sb = New-Object System.Text.StringBuilder
        while (($pos -lt $bytes.Length) -and (-not (& $isWs $bytes[$pos]))) {
            [void]$sb.Append([char]$bytes[$pos]); $pos++
        }
        $toks += $sb.ToString()
    }
    $pos++
    $m  = $toks[0]
    $w  = [int]$toks[1]
    $h  = [int]$toks[2]
    $mx = [int]$toks[3]
    Log ("PPM: magic=$m size=${w}x${h} maxval=$mx ($($bytes.Length) bytes)")

    Check "PPM screenshot produced" $true
    $sx = [int]($w / 320)
    $sy = [int]($h / 200)
    Check "PPM is P6, 320x200 aspect" (($m -eq "P6") -and ($sx -ge 1) -and ($sy -ge 1) -and ($sx*320 -eq $w) -and ($sy*200 -eq $h))
    Log ("scale = ${sx}x${sy}")

    function Pix($x, $y) {
        $px = $x * $sx; $py = $y * $sy
        $off = $pos + ($py * $w + $px) * 3
        return @($bytes[$off], $bytes[$off+1], $bytes[$off+2])
    }
    $d  = Pix 5 70
    $tb = Pix 160 190
    $sb = Pix 60 195
    $ti = Pix 120 33
    $cl = Pix 180 109
    $tx = Pix 47 15
    $me = Pix 50 130
    Log ("desktop(5,70)=$d taskbar(160,190)=$tb startbtn(60,195)=$sb")
    Log ("title(120,33)=$ti client(180,109)=$cl titletext(47,15)=$tx menu(50,130)=$me")

    Check "desktop gradient blue" (($d[2] -ge 60) -and ($d[2] -le 180) -and ($d[1] -gt 0) -and ($d[1] -lt 80))
    Check "taskbar gray"      (($tb[0] -ge 160) -and ($tb[1] -ge 160) -and ($tb[2] -ge 160))
    Check "start button gray" (($sb[0] -ge 160) -and ($sb[1] -ge 160) -and ($sb[2] -ge 160))
    Check "title bar navy"    (($ti[2] -ge 80) -and ($ti[0] -lt 60) -and ($ti[1] -lt 60))
    Check "client area"       (($cl[0] -ge 200) -and ($cl[1] -ge 200) -and ($cl[2] -ge 200))

    # count distinct colours
    $seenCol = @{}
    for ($y = 0; $y -lt 200; $y += 2) {
        $rowBase = $pos + ($y * $sy) * $w * 3
        for ($x = 0; $x -lt 320; $x += 4) {
            $o = $rowBase + ($x * $sx) * 3
            $seenCol[[int]$bytes[$o] * 65536 + [int]$bytes[$o+1] * 256 + [int]$bytes[$o+2]] = 1
        }
    }
    Log ("distinct colours = " + $seenCol.Count)
    Check "scene uses >=8 palette entries" ($seenCol.Count -ge 8)
}

Log "`n========== M-A4+ SUMMARY =========="
if ($fail -eq 0) { Log "ALL PASS - M-A4+ Win9x GUI verified" }
else { Log ("$fail CHECK(S) FAILED") }
exit $fail