# pack.ps1 - pack boot.bin + kernel.bin into a 1.44MB floppy image (dos.img)
param(
    [string]$OutDir = ".",
    [string]$RootDir = "."
)
$b = [System.IO.File]::ReadAllBytes((Join-Path $OutDir "boot.bin"))
$k = [System.IO.File]::ReadAllBytes((Join-Path $OutDir "kernel.bin"))

if ($b.Length -ne 512) { Write-Error "boot.bin must be 512 bytes, got $($b.Length)"; exit 1 }
if ($k.Length -gt 16*512) { Write-Error "kernel.bin exceeds 16 sectors"; exit 1 }

$img = New-Object byte[] 1474560
[System.Array]::Copy($b, $img, 512)
# kernel is loaded by the bootloader from floppy sector 2 (1-based), which is
# byte offset 512 in the raw image (sector 1 = boot at offset 0).
[System.Array]::Copy($k, 0, $img, 512, $k.Length)
$dest = Join-Path $PSScriptRoot "dos.img"
[System.IO.File]::WriteAllBytes($dest, $img)
Write-Host ("built " + $dest + "  (kernel " + $k.Length + " bytes, " + [math]::Ceiling($k.Length/512) + " sectors)")
