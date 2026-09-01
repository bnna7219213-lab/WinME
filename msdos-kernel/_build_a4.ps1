# Build M-A4 (Win9x VDD + GUI) — the verified teal real-mode milestone.
# The source now lives in win9x/winme/ (generational landing, A.5 reorg):
#   boot loader  : win9x/winme/boot.asm      (M0 real-mode loader)
#   kernel       : win9x/winme/a4_gui_realmode.asm
# Uses an isolated build_a4/ staging dir so it never clobbers the A1 build.
$ErrorActionPreference = "Stop"
$root   = "C:\Users\bnna7\workspace\msdos-kernel"
$nasm   = "C:\mingw64\mingw64\bin\nasm.exe"
if (-not (Test-Path $nasm)) { $nasm = "nasm.exe" }

$boot   = "$root\win9x\build_a4\boot.bin"
$kernel = "$root\win9x\build_a4\kernel.bin"
$img    = "$root\win9x\win9x_a4.img"

if (-not (Test-Path "$root\win9x\build_a4")) { New-Item -ItemType Directory -Path "$root\win9x\build_a4" | Out-Null }

Write-Host "=== [A4] assemble bootloader (win9x/winme/boot.asm) ==="
& $nasm -f bin "$root\win9x\winme\boot.asm" -o $boot
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host ("   boot.bin: " + [IO.File]::ReadAllBytes($boot).Length + " bytes")

Write-Host "=== [A4] assemble kernel (win9x/winme/a4_gui_realmode.asm) ==="
& $nasm -f bin -i "$root\" "$root\win9x\winme\a4_gui_realmode.asm" -o $kernel
if ($LASTEXITCODE -ne 0) { exit 1 }
Write-Host ("   kernel.bin: " + [IO.File]::ReadAllBytes($kernel).Length + " bytes")

Write-Host "=== [A4] pack 1.44MB image (pack.ps1) ==="
& powershell -NoProfile -ExecutionPolicy Bypass -File "$root\pack.ps1" -OutDir "$root\win9x\build_a4" -RootDir "$root\win9x"
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "=== [A4] stage image -> win9x/win9x_a4.img ==="
Copy-Item "$root\dos.img" $img -Force
Write-Host ("   win9x_a4.img: " + [IO.File]::ReadAllBytes($img).Length + " bytes")

Write-Host "=== M-A4 BUILD OK ===" -ForegroundColor Green
