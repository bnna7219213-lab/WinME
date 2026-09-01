# Build M-A3 (VMM + VxD/VTD) and stage the floppy image
$ErrorActionPreference = "Continue"
$root = $PSScriptRoot

nasm -f bin -I "$root\" -o "$root\win9x\build\kernel.bin" "$root\win9x\src\a3_vmm.asm"
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAILED"; exit 1 }

$len = (Get-Item "$root\win9x\build\kernel.bin").Length
$sectors = [math]::Ceiling($len / 512)
Write-Host "kernel.bin: $len bytes ($sectors sectors)"
# src/boot.asm reads KERNEL_SECTORS=16 sectors; anything larger is truncated.
if ($sectors -gt 16) { Write-Host "KERNEL TOO LARGE (boot.asm reads 16 sectors)"; exit 1 }

& "$root\pack.ps1" -OutDir "win9x\build" -RootDir "win9x"
if ($LASTEXITCODE -ne 0) { Write-Host "PACK FAILED"; exit 1 }

Copy-Item "$root\dos.img" "$root\win9x\win9x.img" -Force
Write-Host "Image ready: $root\win9x\win9x.img"
