# Probe: does this QEMU build still expose HMP mouse_move / mouse_button ?
$ErrorActionPreference = "Continue"
$qemu = "C:\qemu\qemu-system-i386.exe"
$mon  = 4499
Get-Process qemu* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$p = Start-Process -FilePath $qemu -PassThru -NoNewWindow -ArgumentList @(
    "-m","16","-display","none","-no-reboot",
    "-monitor","tcp:127.0.0.1:$mon,server,nowait"
)
Start-Sleep -Milliseconds 1200

function Drain($stream) {
    $buf = New-Object byte[] 65536
    $out = ""
    for ($i=0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 60
        while ($stream.DataAvailable) {
            $n = $stream.Read($buf,0,$buf.Length)
            if ($n -le 0) { break }
            $out += [Text.Encoding]::ASCII.GetString($buf,0,$n)
        }
    }
    return $out
}

try {
    $sock = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $mon)
    $s = $sock.GetStream()
    $w = New-Object System.IO.StreamWriter($s); $w.AutoFlush = $true
    Write-Output "=== greet ==="
    Write-Output (Drain $s)
    foreach ($cmd in @("help mouse_move","help mouse_button","info mice","info version")) {
        $w.WriteLine($cmd)
        Write-Output ("=== " + $cmd + " ===")
        Write-Output (Drain $s)
    }
    $w.WriteLine("quit")
    Start-Sleep -Milliseconds 200
    $sock.Close()
} catch { Write-Output ("probe failed: " + $_) }
Get-Process qemu* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
