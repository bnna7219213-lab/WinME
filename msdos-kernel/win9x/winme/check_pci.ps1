# check_pci.ps1 — Check what PCI devices QEMU creates
$qemu = "C:\qemu\qemu-system-i386.exe"
$mon = 4513

$p = Start-Process -FilePath $qemu -PassThru -NoNewWindow -ArgumentList @(
    "-display","none","-no-reboot","-m","16",
    "-device","e1000,netdev=net0",
    "-netdev","user,id=net0",
    "-monitor","tcp:127.0.0.1:$mon,server,nowait"
)
Start-Sleep -Milliseconds 2000

try {
    $sock = New-Object System.Net.Sockets.TcpClient("127.0.0.1",$mon)
    $s = $sock.GetStream()
    $w = New-Object System.IO.StreamWriter($s); $w.AutoFlush = $true
    Start-Sleep -Milliseconds 300
    $w.WriteLine("info pci")
    Start-Sleep -Milliseconds 800
    $buf = New-Object byte[] 8192
    $n = $s.Read($buf, 0, 8192)
    $output = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
    Write-Output $output
    $w.WriteLine("quit")
    Start-Sleep -Milliseconds 200
    $sock.Close()
} catch { Write-Output "Error: $_" }

Start-Sleep -Milliseconds 300
Get-Process qemu* -ErrorAction SilentlyContinue | Stop-Process -Force
