$pcap = 'c:\Users\bnna7\workspace\msdos-kernel\win9x\winme\_net.pcap'
if (-not (Test-Path $pcap)) { Write-Output "NO PCAP"; exit }
$bytes = [System.IO.File]::ReadAllBytes($pcap)
Write-Output ("pcap size: {0} bytes" -f $bytes.Length)
$off = 24
$i = 0
while ($off -lt $bytes.Length) {
    $ts_sec = [BitConverter]::ToUInt32($bytes, $off)
    $ts_usec = [BitConverter]::ToUInt32($bytes, $off + 4)
    $inc = [BitConverter]::ToUInt32($bytes, $off + 8)
    $orig = [BitConverter]::ToUInt32($bytes, $off + 12)
    $off += 16
    if ($off + $inc -gt $bytes.Length) { break }
    $pkt = $bytes[$off..($off + $inc - 1)]
    $off += $inc
    $i++
    Write-Output ("=== packet {0}: {1} bytes ===" -f $i, $inc)
    if ($inc -lt 14) { continue }
    $ethDst = ($pkt[0..5] | ForEach-Object { '{0:x2}' -f $_ }) -join ':'
    $ethSrc = ($pkt[6..11] | ForEach-Object { '{0:x2}' -f $_ }) -join ':'
    $ethType = '{0:x4}' -f (($pkt[12] -shl 8) -bor $pkt[13])
    Write-Output ("  Eth dst={0} src={1} type=0x{2}" -f $ethDst, $ethSrc, $ethType)
    if ($pkt[12] -eq 0x08 -and $pkt[13] -eq 0x00) {
        $ip = $pkt[14..($pkt.Length - 1)]
        $ipProto = $ip[9]
        $ipSrc = "{0}.{1}.{2}.{3}" -f $ip[12], $ip[13], $ip[14], $ip[15]
        $ipDst = "{0}.{1}.{2}.{3}" -f $ip[16], $ip[17], $ip[18], $ip[19]
        Write-Output ("  IP proto={0} src={1} dst={2}" -f $ipProto, $ipSrc, $ipDst)
        if ($ipProto -eq 6 -and $ip.Length -ge 40) {
            $tcp = $ip[20..($ip.Length - 1)]
            $tcpSrcPort = ($tcp[0] -shl 8) -bor $tcp[1]
            $tcpDstPort = ($tcp[2] -shl 8) -bor $tcp[3]
            $tcpFlags = $tcp[13]
            Write-Output ("  TCP sport={0} dport={1} flags=0x{2:x2} SYN={3} ACK={4}" -f $tcpSrcPort, $tcpDstPort, $tcpFlags, [bool]($tcpFlags -band 2), [bool]($tcpFlags -band 0x10))
        }
    } elseif ($pkt[12] -eq 0x08 -and $pkt[13] -eq 0x06) {
        $arp = $pkt[14..($pkt.Length - 1)]
        $op = ($arp[6] -shl 8) -bor $arp[7]
        $arpSha = ($arp[8..13] | ForEach-Object { '{0:x2}' -f $_ }) -join ':'
        $arpSpa = "{0}.{1}.{2}.{3}" -f $arp[14], $arp[15], $arp[16], $arp[17]
        $arpTha = ($arp[18..23] | ForEach-Object { '{0:x2}' -f $_ }) -join ':'
        $arpTpa = "{0}.{1}.{2}.{3}" -f $arp[24], $arp[25], $arp[26], $arp[27]
        Write-Output ("  ARP op={0} sha={1} spa={2} tha={3} tpa={4}" -f $(if($op -eq 1){"REQUEST"}elseif($op -eq 2){"REPLY"}else{$op}), $arpSha, $arpSpa, $arpTha, $arpTpa)
    }
}
