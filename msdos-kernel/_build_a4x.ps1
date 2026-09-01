# Build M-A4+ (Win9x enhanced GUI) using the boot32 + VIDEO_MODE=0x13 pipeline
# (verified working by M-D2). boot32.asm loads kernel at sector 2, copies to
# 0x100000, jumps to 0x100000.
$ErrorActionPreference = "Stop"
$root   = "C:\Users\bnna7\workspace\msdos-kernel"
$nasm   = "C:\mingw64\mingw64\bin\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm.exe" }

$boot   = "$root\win9x\winme\build\boot32.bin"
$kernel = "$root\win9x\winme\build\a4x_kernel.bin"
$img    = "$root\win9x\winme\winme_a4x.img"

if (-not (Test-Path "$root\win9x\build")) { New-Item -ItemType Directory -Path "$root\win9x\build" | Out-Null }

Write-Host "=== [A4X] assemble boot32.asm (-DVIDEO_MODE=0x0013) ==="
& $nasm -f bin -DVIDEO_MODE=0x0013 -i "$root" "$root\common\boot32.asm" -o $boot
if ($LASTEXITCODE -ne 0) { exit 1 }
$b = [System.IO.File]::ReadAllBytes($boot)
Write-Host ("   boot32.bin: " + $b.Length + " bytes")

Write-Host "=== [A4X] assemble a4x_gui.asm ==="
& $nasm -f bin -i "$root" "$root\win9x\winme\a4_gui.asm" -o $kernel
if ($LASTEXITCODE -ne 0) { exit 1 }
$k = [System.IO.File]::ReadAllBytes($kernel)
Write-Host ("   a4x_kernel.bin: " + $k.Length + " bytes (" + ([Math]::Ceiling($k.Length / 512.0)) + " sectors)")
if ($k.Length -gt (64 * 512)) {
    Write-Host ("   [WARN] kernel exceeds 32KB (64 sectors): " + $k.Length + " bytes") -ForegroundColor Yellow
    exit 1
}

Write-Host "=== [A4X] pack 1.44MB image ==="
$img_bytes = New-Object byte[] 1474560
[System.Array]::Copy($b, 0, $img_bytes, 0, $b.Length)
[System.Array]::Copy($k, 0, $img_bytes, 1024, $k.Length)
[System.IO.File]::WriteAllBytes($img, $img_bytes)
Write-Host ("   win9x.img: " + $img_bytes.Length + " bytes")

Write-Host "=== M-A4+ BUILD OK ===" -ForegroundColor Green