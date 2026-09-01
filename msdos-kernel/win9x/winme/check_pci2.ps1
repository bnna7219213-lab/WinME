$qemu = "C:\qemu\qemu-system-i386.exe"
$mon = 4599

$p = Start-Process -FilePath $qemu -PassThru -NoNewWindow -ArgumentList @(
    "-display","none","-no-reboot",
    "-device","e1000,netdev=net0",
    "-netdev","user,id=net0",
    "-monitor","tcp:127.0.0.1:$mon,server,nowait"
)

Start-Sleep -Milliseconds 1500

try {
    $sock = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $mon)
    $s = $sock.GetStream()
    $w = New-Object System.IO.StreamWriter($s)
    $w.AutoFlush = $true
    Start-Sleep -Milliseconds 300
    $buf = New-Object byte[] 4096
    if ($s.DataAvailable) { $n = $s.Read($buf, 0, 4096); Write-Output ([System.Text.Encoding]::ASCII.GetString($buf, 0, $n)) }
    $w.WriteLine("info pci")
    Start-Sleep -Milliseconds 800
    $buf = New-Object byte[] 8192
    $n = $s.Read($buf, 0, 8192)
    Write-Output ([System.Text.Encoding]::ASCII.GetString($buf, 0, $n))
    $w.WriteLine("quit")
    Start-Sleep -Milliseconds 200
    $sock.Close()
} catch {
    Write-Output "Monitor error: $_"
}

Start-Sleep -Milliseconds 500
$p | Stop-Process -Force -ErrorAction SilentlyContinue
