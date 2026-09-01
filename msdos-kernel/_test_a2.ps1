$ErrorActionPreference = "Continue"
$qemu = "C:\qemu\qemu-system-i386.exe"
$img = "C:\Users\bnna7\workspace\msdos-kernel\win9x\win9x.img"
$dbg = "C:\Users\bnna7\workspace\msdos-kernel\win9x\dbg.log"

# Remove old image, copy fresh
Remove-Item $img -Force -ErrorAction SilentlyContinue
Copy-Item "C:\Users\bnna7\workspace\msdos-kernel\dos.img" $img

# QEMU with debugcon to file
$log = $dbg
Start-Process -NoNewWindow -FilePath $qemu -ArgumentList @(
    "-fda", $img,
    "-nographic",
    "-debugcon", "file:$log",
    "-m", "16M"
)
Start-Sleep -Seconds 10

# Stop QEMU
Stop-Process -Name "qemu-system-i386" -Force -ErrorAction SilentlyContinue

# Show log
Write-Host "=== QEMU Debug Log ==="
if (Test-Path $log) {
    Get-Content $log | ForEach-Object { Write-Host $_ }
} else {
    Write-Host "[NO LOG]"
    exit 1
}

# Check for expected markers
$content = Get-Content $log -Raw
# Stage markers emitted by a2_dpmi.asm on port 0xE9:
#   L=lgdt  C=pre-CR0  P=PM entry  S=segments  I=build_idt  D=lidt  T=ltr
$checks = @(
    "LCPSIDT",
    "PM ON",
    "ENTERED RING3",
    "DPMI version: 0x00000103",
    "ring3 wrote buffer",
    "BACK IN RING0",
    "buffer: 'HELLO PM'",
    "match OK",
    "VERIFIED",
    "BACK IN REAL MODE"
)
$pass = $true
foreach ($c in $checks) {
    if ($content.Contains($c)) {
        Write-Host "[PASS] $c"
    } else {
        Write-Host "[FAIL] $c"
        $pass = $false
    }
}
if ($pass) {
    Write-Host "=== ALL PASS ==="
    exit 0
} else {
    Write-Host "=== FAILED ==="
    exit 1
}