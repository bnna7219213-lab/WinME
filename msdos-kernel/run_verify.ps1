# run_verify.ps1 — boot the toy MS-DOS kernel in QEMU and exercise its shell.
# Output: QEMU debug port 0xE9 -> dbg.log ; keyboard injected via monitor.
$ErrorActionPreference = "Stop"
$root   = $PSScriptRoot
$qemu   = "C:\qemu\qemu-system-i386.exe"
$img    = Join-Path $root "dos.img"
$dbg    = Join-Path $root "dbg.log"
$port   = 4466

if (Test-Path $dbg) { try { Remove-Item $dbg -ErrorAction SilentlyContinue } catch {} }

$p = Start-Process -FilePath $qemu -ArgumentList @(
    "-fda",$img,"-boot","a","-drive","file=$img,format=raw,if=floppy",
    "-display","none","-debugcon","file:$dbg",
    "-monitor","tcp:127.0.0.1:$port,server,nowait","-no-reboot"
) -PassThru -NoNewWindow
Write-Host "[*] qemu pid = $($p.Id)"

# connect once, reuse for all monitor commands
$sock = $null
function Open-Mon {
    $script:sock = New-Object System.Net.Sockets.TcpClient("127.0.0.1",$port)
}
function Mon ($line) {
    $s = $script:sock.GetStream()
    $w = New-Object System.IO.StreamWriter($s); $w.AutoFlush=$true
    Start-Sleep -Milliseconds 120
    $w.WriteLine($line)
    Start-Sleep -Milliseconds 200
    $w.Flush()
}
function Type ($text) {
    foreach ($c in $text.ToCharArray()) { Mon "sendkey $c"; Start-Sleep -Milliseconds 50 }
    Mon "sendkey ret"; Start-Sleep -Milliseconds 300
}

# wait for monitor port
for ($i=0; $i -lt 15; $i++) {
    try { Open-Mon; break } catch { Start-Sleep -Milliseconds 300 }
}
if ($null -eq $sock) { Write-Host "[!] monitor never opened"; exit 1 }
Write-Host "[*] monitor up"

Start-Sleep -Seconds 1
Type "ver"
Type "help"
Type "echo hello-from-dos"
Type "cls"
Type "echo verified-ok"
Type "boguscmd"

Mon "quit" | Out-Null
Start-Sleep -Seconds 1
if (-not $p.HasExited) { try { $p.Kill() } catch {} }

Write-Host "===== dbg.log (kernel output via 0xE9) ====="
$b = [System.IO.File]::ReadAllBytes($dbg)
Write-Host ([System.Text.Encoding]::ASCII.GetString($b))
