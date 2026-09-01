# ============================================================================
# pack32.ps1 — Pack a 32-bit boot image (boot32.bin + kernel32.bin → os.img)
# ----------------------------------------------------------------------------
#  Places the kernel immediately after the boot loader, aligned to the next
#  512-byte sector boundary. This matches boot32.asm stage 1, which reads the
#  kernel from sector (2 + BOOT_SECTORS - 1).
#
#  Usage:
#    powershell -File common/pack32.ps1 -Boot build/boot32.bin `
#                                       -Kernel build/kernel32.bin `
#                                       -OutImage build/os.img
#
#  The output image is a raw 1.44MB floppy.
# ============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$Boot,

    [Parameter(Mandatory=$true)]
    [string]$Kernel,

    [Parameter(Mandatory=$false)]
    [string]$OutImage = "os.img",

    [int]$ImageSize = 1474560   # 1.44MB floppy
)

$ErrorActionPreference = "Stop"

# --- Validate inputs ---
if (-not (Test-Path $Boot)) {
    Write-Error "Boot file not found: $Boot"
    exit 1
}
if (-not (Test-Path $Kernel)) {
    Write-Error "Kernel file not found: $Kernel"
    exit 1
}

$bootBytes = [System.IO.File]::ReadAllBytes($Boot)
$kernelBytes = [System.IO.File]::ReadAllBytes($Kernel)

# Boot signature check (first sector)
#  NOTE: PowerShell gives -bor and -shl the SAME precedence and evaluates them
#  left to right, so "$a -bor $b -shl 8" parses as "($a -bor $b) -shl 8" and a
#  valid 55 AA reported a bogus 0x0055.  Cast and parenthesise explicitly.
$sig = ([int]$bootBytes[510]) -bor (([int]$bootBytes[511]) * 256)
if ($sig -ne 0xAA55) {
    Write-Warning "Boot signature is 0x$($sig.ToString('X4')), expected 0xAA55"
}

# Kernel offset = boot size rounded up to next 512-byte sector boundary
if ($bootBytes.Length -gt 512) {
    $kernelOffset = [Math]::Ceiling($bootBytes.Length / 512.0) * 512
} else {
    $kernelOffset = 512
}

$maxKernelSize = $ImageSize - $kernelOffset
if ($kernelBytes.Length -gt $maxKernelSize) {
    Write-Error "Kernel ($($kernelBytes.Length) bytes) exceeds max ($maxKernelSize bytes) at offset $kernelOffset"
    exit 1
}

# --- Build image ---
$img = New-Object byte[] $ImageSize
[Array]::Copy($bootBytes, 0, $img, 0, $bootBytes.Length)
[Array]::Copy($kernelBytes, 0, $img, $kernelOffset, $kernelBytes.Length)

# Write output
$outPath = if ([System.IO.Path]::IsPathRooted($OutImage)) { $OutImage } else { (Join-Path (Get-Location) $OutImage) }
[System.IO.File]::WriteAllBytes($outPath, $img)

$kernelSectors = [Math]::Ceiling($kernelBytes.Length / 512.0)
Write-Host ("Packed: $outPath (boot=$($bootBytes.Length)B, kernel@$kernelOffset = $($kernelBytes.Length)B = $kernelSectors sectors, total=$ImageSize B)") -ForegroundColor Green