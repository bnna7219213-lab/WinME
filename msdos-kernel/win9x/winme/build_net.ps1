# build_net.ps1 — Build the real network test kernel
#   -DnsTest : build the DNS-path variant (DL_TEST_DNS) into winme_net_dns.img
param([switch]$DnsTest)
$ErrorActionPreference = "Stop"
$root    = "C:\Users\bnna7\workspace\msdos-kernel"
$src     = "$root\win9x\winme"
$out     = "$src\build"
$nasm    = "C:\mingw64\mingw64\bin\nasm.exe"
$imgName = "winme_net.img"
$extra   = @()
if ($DnsTest) { $imgName = "winme_net_dns.img"; $extra = @("-D","DL_TEST_DNS") }

if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out | Out-Null }

Write-Output "[1/3] Assembling boot32..."
& $nasm -f bin -DVIDEO_MODE=0x0013 -I "$root\" "$src\boot32.asm" -o "$out\boot32.bin"
if ($LASTEXITCODE -ne 0) { Write-Output "[FAIL] boot32 assembly"; exit 1 }

Write-Output "[2/3] Assembling kernel32 (real network, NET_QUICK, no NET_TEST)..."
& $nasm -f bin -DNET_QUICK @extra -w-label-redef-late -Wno-number-overflow -I "$root\" "$src\a4_gui.asm" -o "$out\kernel32.bin"
if ($LASTEXITCODE -ne 0) { Write-Output "[FAIL] kernel32 assembly"; exit 1 }

Write-Output "[3/3] Packing $imgName..."
& powershell -NoProfile -ExecutionPolicy Bypass -File "$root\common\pack32.ps1" -Boot "$out\boot32.bin" -Kernel "$out\kernel32.bin" -OutImage "$src\$imgName"
if ($LASTEXITCODE -ne 0) { Write-Output "[FAIL] packing"; exit 1 }

# Show sizes
$b = Get-Item "$out\boot32.bin"
$k = Get-Item "$out\kernel32.bin"
$i = Get-Item "$src\$imgName"
Write-Output ""
Write-Output ("boot32.bin    : {0} bytes" -f $b.Length)
Write-Output ("kernel32.bin  : {0} bytes" -f $k.Length)
Write-Output ("{0,-13} : {1} bytes" -f $imgName, $i.Length)
if ($k.Length -le 512 * 512) {  # KERNEL_SECTORS=512 → 262144 bytes max
    Write-Output "[OK] Kernel within 262KB limit"
} else {
    Write-Output "[WARN] Kernel EXCEEDS 262KB limit!"
}
Write-Output ""
Write-Output "Build complete. Run: run_net_test.ps1"
