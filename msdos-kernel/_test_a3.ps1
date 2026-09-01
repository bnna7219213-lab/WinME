# Test M-A3 (VMM + VxD/VTD) in QEMU
$ErrorActionPreference = "Continue"
$qemu = "C:\qemu\qemu-system-i386.exe"
$img  = "C:\Users\bnna7\workspace\msdos-kernel\win9x\win9x.img"
$dbg  = "C:\Users\bnna7\workspace\msdos-kernel\win9x\dbg.log"

Remove-Item $dbg -Force -ErrorAction SilentlyContinue

Start-Process -NoNewWindow -FilePath $qemu -ArgumentList @(
    "-drive", "file=$img,format=raw,if=floppy",
    "-boot", "a",
    "-nographic",
    "-debugcon", "file:$dbg",
    "-m", "16M",
    "-no-reboot"
)
Start-Sleep -Seconds 15

Stop-Process -Name "qemu-system-i386" -Force -ErrorAction SilentlyContinue

Write-Host "=== QEMU Debug Log ==="
if (-not (Test-Path $dbg)) {
    Write-Host "[NO LOG]"
    exit 1
}
Get-Content $dbg
$content = Get-Content $dbg -Raw

$pass = $true

# --- required stage markers -------------------------------------------------
$checks = @(
    "[M-A3] PM ON - VMM32 starting",
    "[VMM] init: creating virtual machines",
    "[VMM] Sys VM + DOS VM created, state=READY",
    "[VTD] init: PIC remap + PIT 100Hz",
    "[VTD] virtual timer device armed on IRQ0",
    "[VMM] scheduler start",
    "[Sys VM] running",
    "[DOS VM] running",
    "[VMM] shutdown - VM statistics:",
    "[VTD] total ticks=24",
    "BACK IN REAL MODE - VMM demo complete"
)
Write-Host ""
Write-Host "=== Marker checks ==="
foreach ($c in $checks) {
    if ($content.Contains($c)) {
        Write-Host "[PASS] $c"
    } else {
        Write-Host "[FAIL] $c"
        $pass = $false
    }
}

# --- no unhandled faults ----------------------------------------------------
Write-Host ""
Write-Host "=== Fault check ==="
if ($content.Contains("[FAULT]")) {
    Write-Host "[FAIL] unhandled exception occurred"
    $pass = $false
} else {
    Write-Host "[PASS] no unhandled exceptions"
}

# --- context switching actually alternated between the two VMs --------------
Write-Host ""
Write-Host "=== Scheduler checks ==="
$order = [regex]::Matches($content, '\[(Sys|DOS) VM\] running') | ForEach-Object { $_.Groups[1].Value }
$switches = 0
for ($i = 1; $i -lt $order.Count; $i++) {
    if ($order[$i] -ne $order[$i-1]) { $switches++ }
}
if ($switches -ge 4) {
    Write-Host "[PASS] observed $switches VM context switches"
} else {
    Write-Host "[FAIL] only $switches VM context switches (expected >= 4)"
    $pass = $false
}

# --- round-robin fairness: both VMs must have run and split the ticks -------
$mSys = [regex]::Match($content, 'VM SYS\s+ticks=(\d+)')
$mDos = [regex]::Match($content, 'VM DOS\s+ticks=(\d+)')
if ($mSys.Success -and $mDos.Success) {
    $tSys = [int]$mSys.Groups[1].Value
    $tDos = [int]$mDos.Groups[1].Value
    Write-Host "[INFO] Sys VM ticks=$tSys  DOS VM ticks=$tDos"
    if ($tSys -gt 0 -and $tDos -gt 0) {
        Write-Host "[PASS] both VMs were scheduled"
    } else {
        Write-Host "[FAIL] a VM never ran"
        $pass = $false
    }
    if ($tSys + $tDos -eq 24) {
        Write-Host "[PASS] tick accounting balances ($tSys + $tDos = 24)"
    } else {
        Write-Host "[FAIL] tick accounting mismatch ($tSys + $tDos != 24)"
        $pass = $false
    }
    if ([Math]::Abs($tSys - $tDos) -le 2) {
        Write-Host "[PASS] round-robin fair (delta=$([Math]::Abs($tSys-$tDos)))"
    } else {
        Write-Host "[FAIL] scheduling unfair (delta=$([Math]::Abs($tSys-$tDos)))"
        $pass = $false
    }
} else {
    Write-Host "[FAIL] VM statistics not found"
    $pass = $false
}

# --- the VTD tick counter must advance monotonically across switches --------
$ticks = [regex]::Matches($content, 'running, tick=(\d+)') | ForEach-Object { [int]$_.Groups[1].Value }
if ($ticks.Count -gt 0) {
    $mono = $true
    for ($i = 1; $i -lt $ticks.Count; $i++) {
        if ($ticks[$i] -lt $ticks[$i-1]) { $mono = $false; break }
    }
    if ($mono -and $ticks[-1] -gt $ticks[0]) {
        Write-Host "[PASS] VTD tick advanced monotonically $($ticks[0]) -> $($ticks[-1])"
    } else {
        Write-Host "[FAIL] VTD tick not monotonic"
        $pass = $false
    }
} else {
    Write-Host "[FAIL] no VTD tick samples"
    $pass = $false
}

Write-Host ""
if ($pass) {
    Write-Host "=== ALL PASS ==="
    exit 0
} else {
    Write-Host "=== FAILED ==="
    exit 1
}
