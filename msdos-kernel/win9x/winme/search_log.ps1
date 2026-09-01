# search_log.ps1 — Search debug log for network-related messages
$log = "C:\Users\bnna7\workspace\msdos-kernel\win9x\winme\_net_test.log"
$patterns = @("TCP", "tcp", "SYN", "ARP", "arp", "net_dl", "NIC", "nic", "E1000", "e1000", "PCI", "pci", "MMIO", "mmio", "TX", "tx_", "RX", "rx_", "eth_", "send", "connect", "A4X", "DL:", "VM ", "gateway", "MAC")
$lines = Get-Content $log -Encoding ASCII
$matched = @()
foreach ($line in $lines) {
    foreach ($p in $patterns) {
        if ($line -match $p) {
            $matched += $line
            break
        }
    }
}
Write-Output "=== Matched lines ($($matched.Count) of $($lines.Count) total) ==="
$matched | Select-Object -First 80 | ForEach-Object { Write-Output $_ }
