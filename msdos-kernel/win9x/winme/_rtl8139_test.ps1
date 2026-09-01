$ErrorActionPreference = 'SilentlyContinue'
Stop-Process -Name qemu-system-i386 -Force -ErrorAction SilentlyContinue
Stop-Process -Name python -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 700
Set-Location "C:\Users\bnna7\workspace\msdos-kernel\win9x\winme"
$dbgFile = "debug_rtl.txt"
# Forcefully remove old debug file
1..3 | ForEach-Object {
    if (Test-Path $dbgFile) {
        try { [System.IO.File]::Delete((Resolve-Path $dbgFile).Path) } catch {}
        Start-Sleep -Milliseconds 150
    }
}
Write-Host "Removed old $dbgFile (Exists=$(Test-Path $dbgFile))"

# Start HTTP server (serve_a4.py serves 0xA4 EXE on host 8080)
$py = Start-Process -FilePath "python" -NoNewWindow -ArgumentList @("serve_a4.py") -PassThru
Start-Sleep -Milliseconds 900
Write-Host "HTTP server PID=$($py.Id)"

# Start QEMU with RTL8139 + winme_net.img
# NOTE: guest user-mode SLIRP can reach host services at 10.0.2.2:<port>
#       so serve_a4.py on host:8080 is reachable by guest TCP → 10.0.2.2:8080
$qemuArgs = @(
    "-drive","file=winme_net.img,if=floppy,format=raw,index=0",
    "-boot","a","-m","16",
    "-display","none","-no-reboot","-no-shutdown",
    "-netdev","user,id=net0",
    "-device","rtl8139,netdev=net0",
    "-debugcon","file:$dbgFile",
    "-serial","null"
)
$p = Start-Process -FilePath "C:\qemu\qemu-system-i386.exe" -NoNewWindow -PassThru -ArgumentList $qemuArgs
Write-Host "QEMU started PID=$($p.Id). Waiting 12s for TCP+SYN+SYN-ACK..."
Start-Sleep -Seconds 12

Write-Host "QEMU EXITED=$($p.HasExited). Killing..."
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
Stop-Process -Id $py.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

Write-Host ""
Write-Host "=== $dbgFile stats ==="
if (Test-Path $dbgFile) {
    $fi = Get-Item $dbgFile
    Write-Host ("Size=" + $fi.Length + " bytes")
    $content = [System.IO.File]::ReadAllText($fi.FullName)
    function CountMark($pat) {
        $m = ([regex]$pat).Matches($content)
        return $m.Count
    }
    Write-Host ("boot32            : " + (CountMark "boot32"))
    Write-Host ("kernel at 1MB     : " + (CountMark "kernel at 1MB"))
    Write-Host ("net_init PCI scan : " + (CountMark "scanning PCI"))
    Write-Host ("NIC found (type=1): " + (CountMark "net_ifound"))
    Write-Host ("no NIC found msg  : " + (CountMark "no RTL8139 NIC found"))
    Write-Host ("RTL8139 init CR=  : " + (CountMark "RTL8139 init CR="))
    Write-Host ("TSAD0 addr print  : " + (CountMark "TSAD0="))
    Write-Host ("demo:start        : " + (CountMark "demo:start"))
    Write-Host ("ARP: skipped SLIRP: " + (CountMark "skipped \(SLIRP\)"))
    Write-Host ("net_dl state=0    : " + (CountMark "net_dl state=0"))
    Write-Host ("net_dl state=1    : " + (CountMark "net_dl state=1"))
    Write-Host ("net_dl state=3    : " + (CountMark "net_dl state=3"))
    Write-Host ("TCP: SYN sent     : " + (CountMark "TCP: SYN sent"))
    Write-Host ("tcp_check TX DONE : " + (CountMark "tcp_check TX DONE"))
    Write-Host ("tcp_check TX pend : " + (CountMark "tcp_check TX pending"))
    Write-Host ("TCP SYN TIMEOUT   : " + (CountMark "SYN TIMEOUT"))
    Write-Host ("TCP: SYN-ACK recv : " + (CountMark "SYN-ACK received"))
    Write-Host ("TCP: data sent    : " + (CountMark "TCP: data sent"))
    Write-Host ("TCP: data received: " + (CountMark "data received"))
    Write-Host ("eth_send len=     : " + (CountMark "eth_send len="))
    Write-Host ("eth_rx CBR!=CAPR  : " + (CountMark "CBR!=CAPR"))
    Write-Host ("eth_rx HDR status : " + (CountMark "eth_rx HDR"))
    Write-Host ("eth_rx BADPKT     : " + (CountMark "BADPKT"))
    Write-Host ("DL:OK             : " + (CountMark "DL:OK"))
    Write-Host ("VM OK             : " + (CountMark "VM OK"))
    Write-Host ("DONE              : " + (CountMark "DONE"))
    Write-Host ("kernel halt       : " + (CountMark "kernel halt"))

    Write-Host ""
    Write-Host "=== First 120 non-empty lines ==="
    $lines = $content -split "`r?`n"
    $nonEmpty = $lines | Where-Object { $_ -match '\S' }
    $nonEmpty | Select-Object -First 120 | ForEach-Object { Write-Host $_ }
    if ($nonEmpty.Count -gt 120) {
        Write-Host ""
        Write-Host ("=== ..." + ($nonEmpty.Count - 120) + " more lines. Last 80: ===")
        $nonEmpty | Select-Object -Last 80 | ForEach-Object { Write-Host $_ }
    }
} else {
    Write-Host "$dbgFile NOT FOUND"
}
