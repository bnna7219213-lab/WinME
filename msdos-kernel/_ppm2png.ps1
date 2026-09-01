# PPM (P6) -> PNG converter, used to eyeball the QEMU screendump of M-A4.
param(
    [string]$In  = "C:\Users\bnna7\workspace\msdos-kernel\win9x\_a4.ppm",
    [string]$Out = "C:\Users\bnna7\workspace\msdos-kernel\win9x\_a4.png"
)
Add-Type -AssemblyName System.Drawing
$b = [IO.File]::ReadAllBytes($In)

# --- parse the P6 header by raw byte value (never by regex on a byte) ---
$isWs = { param($v) ($v -eq 32) -or ($v -eq 9) -or ($v -eq 10) -or ($v -eq 13) }
$pos = 0; $toks = @()
while (($toks.Count -lt 4) -and ($pos -lt 128)) {
    while (($pos -lt $b.Length) -and (& $isWs $b[$pos])) { $pos++ }
    if ($b[$pos] -eq 35) { while (($pos -lt $b.Length) -and ($b[$pos] -ne 10)) { $pos++ }; continue }
    $sb = New-Object System.Text.StringBuilder
    while (($pos -lt $b.Length) -and (-not (& $isWs $b[$pos]))) { [void]$sb.Append([char]$b[$pos]); $pos++ }
    $toks += $sb.ToString()
}
$pos++
$w = [int]$toks[1]; $h = [int]$toks[2]
Write-Output ("input: " + $toks[0] + " " + $w + "x" + $h)

$bmp = New-Object System.Drawing.Bitmap($w, $h)
$rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
$data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
                      [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$row = New-Object byte[] $data.Stride
for ($y = 0; $y -lt $h; $y++) {
    $src = $pos + $y * $w * 3
    for ($x = 0; $x -lt $w; $x++) {
        $o = $src + $x * 3
        $row[$x * 3]     = $b[$o + 2]   # B
        $row[$x * 3 + 1] = $b[$o + 1]   # G
        $row[$x * 3 + 2] = $b[$o]       # R
    }
    [Runtime.InteropServices.Marshal]::Copy($row, 0, [IntPtr]::Add($data.Scan0, $y * $data.Stride), $data.Stride)
}
$bmp.UnlockBits($data)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output ("saved: " + $Out + " (" + (Get-Item $Out).Length + " bytes)")
