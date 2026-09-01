# Probe: can we drive the QEMU monitor over stdio and get a screendump?
$ErrorActionPreference = "Continue"
$root = $PSScriptRoot
$qemu = "C:\qemu\qemu-system-i386.exe"
$img  = "$root\win9x\win9x.img"
$shot = "$root\_probe.ppm"

Remove-Item $shot -Force -ErrorAction SilentlyContinue

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName  = $qemu
$psi.Arguments = "-drive file=$img,format=raw,if=floppy -boot a -display none -monitor stdio -m 16M -no-reboot"
$psi.RedirectStandardInput  = $true
$psi.RedirectStandardOutput = $true
$psi.UseShellExecute = $false

$psi.RedirectStandardError = $true
$p = [System.Diagnostics.Process]::Start($psi)
Start-Sleep -Seconds 8
$p.StandardInput.WriteLine("screendump $shot")
$p.StandardInput.Flush()
Start-Sleep -Seconds 3
$p.StandardInput.WriteLine("quit")
$p.StandardInput.Flush()
Start-Sleep -Seconds 2
if (-not $p.HasExited) { $p.Kill() }
Write-Host "--- monitor stdout ---"
Write-Host $p.StandardOutput.ReadToEnd()
Write-Host "--- stderr ---"
Write-Host $p.StandardError.ReadToEnd()

if (Test-Path $shot) {
    $len = (Get-Item $shot).Length
    Write-Host "SCREENDUMP OK: $len bytes"
    # PPM header is ASCII: P6\n<w> <h>\n255\n
    $bytes = [System.IO.File]::ReadAllBytes($shot)
    $hdr = [System.Text.Encoding]::ASCII.GetString($bytes[0..19])
    Write-Host "HEADER: $($hdr -replace "`n", '|')"
} else {
    Write-Host "SCREENDUMP FAILED (no file)"
}
