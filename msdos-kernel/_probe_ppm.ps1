$ppm = "C:\Users\bnna7\workspace\msdos-kernel\win9x\_a4.ppm"
if (-not (Test-Path $ppm)) { Write-Output "NO PPM FILE"; exit }
$bytes = [System.IO.File]::ReadAllBytes($ppm)
Write-Output ("size=" + $bytes.Length + " bytes")
$pos = 0
function RdTok($b, [ref]$p) { while ($b[$p.Value] -match '\s') { $p.Value++ }; $s=""; while ($b[$p.Value] -notmatch '\s') { $s += [char]$b[$p.Value]; $p.Value++ }; return $s }
$m = RdTok $bytes ([ref]$pos); $w=[int](RdTok $bytes ([ref]$pos)); $h=[int](RdTok $bytes ([ref]$pos)); $mx=[int](RdTok $bytes ([ref]$pos)); $pos++
Write-Output ("magic=$m ${w}x${h} max=$mx")
# sample corners + center
function Pix($x,$y){ $o=$pos+($y*$w+$x)*3; return ($bytes[$o].ToString()+","+$bytes[$o+1]+","+$bytes[$o+2]) }
Write-Output ("(0,0)=" + (Pix 0 0) + " (5,5)=" + (Pix 5 5) + " (160,190)=" + (Pix 160 190) + " (120,39)=" + (Pix 120 39) + " (120,110)=" + (Pix 120 110))
# count distinct colors
$set = @{}
for ($i=0; $i -lt $w*$h; $i++) { $o=$pos+$i*3; $k=$bytes[$o].ToString()+","+$bytes[$o+1]+","+$bytes[$o+2]; $set[$k]=1 }
Write-Output ("distinct colors=" + $set.Count)
$set.Keys | Select-Object -First 20 | ForEach-Object { Write-Output ("  color " + $_) }
