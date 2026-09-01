<#
.SYNOPSIS
    Parses a pcap file and dumps each packet's contents in hex, decoding
    Ethernet / ARP / IP / TCP / UDP headers.

.DESCRIPTION
    The classic libpcap file format is assumed:
      - Global header: 24 bytes
      - For each packet: 16-byte packet header + incl_len bytes of packet data

.PARAMETER PcapPath
    Path to the .pcap file to dump.

.EXAMPLE
    .\_dump_pcap.ps1 -PcapPath .\_net.pcap
#>
param(
    [string]$PcapPath = "c:\Users\bnna7\workspace\msdos-kernel\win9x\winme\_net.pcap"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Convert-HexDump {
    # Produces a classic hex+ASCII dump for a byte array (offset | hex | ascii).
    param(
        [byte[]]$Data,
        [int]$MaxBytes = 64
    )

    $len = [Math]::Min($Data.Length, $MaxBytes)
    $sb = New-Object System.Text.StringBuilder
    for ($off = 0; $off -lt $len; $off += 16) {
        $lineLen = [Math]::Min(16, $len - $off)
        $hexPart = ""
        $asciiPart = ""
        for ($i = 0; $i -lt 16; $i++) {
            if ($i -lt $lineLen) {
                $b = $Data[$off + $i]
                $hexPart += $b.ToString("x2") + " "
                if ($b -ge 0x20 -and $b -le 0x7e) {
                    $asciiPart += [char]$b
                } else {
                    $asciiPart += "."
                }
            } else {
                $hexPart += "   "
            }
            if ($i -eq 7) { $hexPart += " " }
        }
        [void]$sb.AppendLine(("{0,6:X4}  {1} {2}" -f $off, $hexPart, $asciiPart))
    }
    return $sb.ToString()
}

function Get-String {
    # Read ASCII bytes [start..end) from a byte array as a printable string.
    param([byte[]]$Data, [int]$Start, [int]$Len)
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Len; $i++) {
        $b = $Data[$Start + $i]
        if ($b -ge 0x20 -and $b -le 0x7e) {
            [void]$sb.Append([char]$b)
        } else {
            [void]$sb.Append(".")
        }
    }
    return $sb.ToString()
}

function Format-MAC {
    param([byte[]]$Data, [int]$Start)
    return ("{0:x2}:{1:x2}:{2:x2}:{3:x2}:{4:x2}:{5:x2}" -f `
            $Data[$Start], $Data[$Start+1], $Data[$Start+2], `
            $Data[$Start+3], $Data[$Start+4], $Data[$Start+5])
}

function Format-IPv4 {
    param([byte[]]$Data, [int]$Start)
    return ("{0}.{1}.{2}.{3}" -f `
            $Data[$Start], $Data[$Start+1], $Data[$Start+2], $Data[$Start+3])
}

function Read-UInt16BE {
    param([byte[]]$Data, [int]$Start)
    return ([uint32]$Data[$Start] -shl 8) -bor [uint32]$Data[$Start+1]
}

function Read-UInt32BE {
    param([byte[]]$Data, [int]$Start)
    return ([uint32]$Data[$Start]   -shl 24) -bor `
           ([uint32]$Data[$Start+1] -shl 16) -bor `
           ([uint32]$Data[$Start+2] -shl 8)  -bor `
            [uint32]$Data[$Start+3]
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

if (-not (Test-Path $PcapPath)) {
    Write-Error "File not found: $PcapPath"
    exit 1
}

$bytes = [System.IO.File]::ReadAllBytes($PcapPath)
Write-Host ("Total file size : {0} bytes" -f $bytes.Length)
Write-Host ("PCAP path       : {0}" -f $PcapPath)
Write-Host ""

# ---- Global header (24 bytes) ----
if ($bytes.Length -lt 24) {
    Write-Error "File too small to contain a global header."
    exit 1
}

# Detect endianness by inspecting the raw magic bytes on disk.
#   d4 c3 b2 a1 -> standard libpcap, little-endian, microsecond resolution
#   a1 b2 c3 d4 -> standard libpcap, big-endian,    microsecond resolution
#   4d 3c b2 a1 -> nanosecond variant,             little-endian
#   a1 b2 3c 4d -> nanosecond variant,             big-endian
$m0, $m1, $m2, $m3 = $bytes[0], $bytes[1], $bytes[2], $bytes[3]
$magicLabel = ""
if ($m0 -eq 0xd4 -and $m1 -eq 0xc3 -and $m2 -eq 0xb2 -and $m3 -eq 0xa1) {
    $swapEndian = $true;  $magicLabel = "0xa1b2c3d4 (LE, us)"
} elseif ($m0 -eq 0xa1 -and $m1 -eq 0xb2 -and $m2 -eq 0xc3 -and $m3 -eq 0xd4) {
    $swapEndian = $false; $magicLabel = "0xa1b2c3d4 (BE, us)"
} elseif ($m0 -eq 0x4d -and $m1 -eq 0x3c -and $m2 -eq 0xb2 -and $m3 -eq 0xa1) {
    $swapEndian = $true;  $magicLabel = "0xa1b23c4d (LE, ns)"
} elseif ($m0 -eq 0xa1 -and $m1 -eq 0xb2 -and $m2 -eq 0x3c -and $m3 -eq 0x4d) {
    $swapEndian = $false; $magicLabel = "0xa1b23c4d (BE, ns)"
} else {
    Write-Warning ("Unknown magic bytes {0:x2} {1:x2} {2:x2} {3:x2} - assuming little-endian" -f $m0,$m1,$m2,$m3)
    $swapEndian = $true;  $magicLabel = "unknown"
}

# Read the version (16-bit fields) honoring endianness.
if ($swapEndian) {
    $versionMajor = [BitConverter]::ToUInt16($bytes, 4)
    $versionMinor = [BitConverter]::ToUInt16($bytes, 6)
    $thiszone     = [BitConverter]::ToInt32($bytes, 8)
    $sigfigs      = [BitConverter]::ToUInt32($bytes, 12)
    $snaplen      = [BitConverter]::ToUInt32($bytes, 16)
    $linktype     = [BitConverter]::ToUInt32($bytes, 20)
} else {
    $versionMajor = Read-UInt16BE $bytes 4
    $versionMinor = Read-UInt16BE $bytes 6
    $thiszone     = Read-UInt32BE $bytes 8 -as [int]
    $sigfigs      = Read-UInt32BE $bytes 12
    $snaplen      = Read-UInt32BE $bytes 16
    $linktype     = Read-UInt32BE $bytes 20
}

Write-Host "==== Global Header ===="
Write-Host ("  magic          : {0}" -f $magicLabel)
Write-Host ("  version        : {0}.{1}" -f $versionMajor, $versionMinor)
Write-Host ("  thiszone       : {0}" -f $thiszone)
Write-Host ("  sigfigs        : {0}" -f $sigfigs)
Write-Host ("  snaplen        : {0}" -f $snaplen)
Write-Host ("  linktype       : {0} (1 = Ethernet)" -f $linktype)
Write-Host ""

# ---- Walk packets ----
$offset = 24
$packetNum = 0
while ($offset + 16 -le $bytes.Length) {
    $packetNum++

    # Packet header (16 bytes). libpcap uses little-endian on disk in the
    # common case, but honor endianness of the global header.
    if ($swapEndian) {
        $tsSec   = [BitConverter]::ToUInt32($bytes, $offset)
        $tsUsec  = [BitConverter]::ToUInt32($bytes, $offset + 4)
        $inclLen = [BitConverter]::ToUInt32($bytes, $offset + 8)
        $origLen = [BitConverter]::ToUInt32($bytes, $offset + 12)
    } else {
        $tsSec   = Read-UInt32BE $bytes $offset
        $tsUsec  = Read-UInt32BE $bytes ($offset + 4)
        $inclLen = Read-UInt32BE $bytes ($offset + 8)
        $origLen = Read-UInt32BE $bytes ($offset + 12)
    }

    $dataStart = $offset + 16
    if ($dataStart + $inclLen -gt $bytes.Length) {
        Write-Warning ("Packet {0}: declared incl_len={1} would overrun file (offset={2})" -f $packetNum, $inclLen, $dataStart)
        break
    }

    $packetData = New-Object byte[] $inclLen
    [Array]::Copy($bytes, $dataStart, $packetData, 0, $inclLen)

    # Use DateTimeOffset to avoid the millisecond field defaulting to "now".
    $ts = [DateTimeOffset]::FromUnixTimeSeconds([long]$tsSec).AddMilliseconds($tsUsec / 1000.0).LocalDateTime

    Write-Host ("==== Packet {0} ====" -f $packetNum)
    Write-Host ("  timestamp      : {0:yyyy-MM-dd HH:mm:ss.ffffff} (ts_sec={1}, ts_usec={2})" -f $ts, $tsSec, $tsUsec)
    Write-Host ("  incl_len       : {0} bytes" -f $inclLen)
    Write-Host ("  orig_len       : {0} bytes" -f $origLen)
    Write-Host ("  --- hex dump (first 64 bytes) ---")
    Convert-HexDump -Data $packetData -MaxBytes 64 | ForEach-Object { Write-Host ("    " + $_) }

    # ---- Ethernet (linktype 1) ----
    if ($linktype -eq 1 -and $inclLen -ge 14) {
        $dstMac  = Format-MAC $packetData 0
        $srcMac  = Format-MAC $packetData 6
        $ethType = Read-UInt16BE $packetData 12

        Write-Host ("  --- Ethernet ---")
        Write-Host ("    dst MAC      : {0}" -f $dstMac)
        Write-Host ("    src MAC      : {0}" -f $srcMac)
        Write-Host ("    ethertype    : 0x{0:x4}" -f $ethType)

        switch ($ethType) {
            0x0806 {  # ARP
                Write-Host ("    -> ARP")
                if ($inclLen -ge 42) {
                    $hwType   = Read-UInt16BE $packetData 14
                    $protoType= Read-UInt16BE $packetData 16
                    $hwSize   = $packetData[18]
                    $protoSize= $packetData[19]
                    $opcode   = Read-UInt16BE $packetData 20
                    $senderMac= Format-MAC $packetData 22
                    $senderIp = Format-IPv4 $packetData 28
                    $targetMac= Format-MAC $packetData 32
                    $targetIp = Format-IPv4 $packetData 38
                    Write-Host ("       hw type     : 0x{0:x4} (1=Ethernet)" -f $hwType)
                    Write-Host ("       proto type  : 0x{0:x4} (0x0800=IPv4)" -f $protoType)
                    Write-Host ("       hw/proto len: {0}/{1}" -f $hwSize, $protoSize)
                    Write-Host ("       opcode      : {0} (1=request, 2=reply)" -f $opcode)
                    Write-Host ("       sender MAC  : {0}" -f $senderMac)
                    Write-Host ("       sender IP   : {0}" -f $senderIp)
                    Write-Host ("       target MAC  : {0}" -f $targetMac)
                    Write-Host ("       target IP   : {0}" -f $targetIp)
                } else {
                    Write-Host ("       (ARP packet truncated, < 42 bytes)")
                }
            }
            0x0800 {  # IPv4
                Write-Host ("    -> IPv4")
                if ($inclLen -ge 34) {
                    $ihl      = ($packetData[14] -band 0x0f) * 4
                    $version  = ($packetData[14] -shr 4) -band 0x0f
                    $totalLen = Read-UInt16BE $packetData 16
                    $id       = Read-UInt16BE $packetData 18
                    $flagsFrag= Read-UInt16BE $packetData 20
                    $ttl      = $packetData[22]
                    $proto    = $packetData[23]
                    $checksum = Read-UInt16BE $packetData 24
                    $srcIp    = Format-IPv4 $packetData 26
                    $dstIp    = Format-IPv4 $packetData 30

                    # IP header checksum verification (ones complement of
                    # ones complement sum of header, checksum field zeroed).
                    $ipHdr = New-Object byte[] $ihl
                    [Array]::Copy($packetData, 14, $ipHdr, 0, $ihl)
                    # zero the checksum field
                    $ipHdr[10] = 0; $ipHdr[11] = 0
                    $sum = 0
                    for ($i = 0; $i -lt $ipHdr.Length; $i += 2) {
                        $sum += ([uint32]$ipHdr[$i] -shl 8) -bor [uint32]$ipHdr[$i+1]
                    }
                    while (($sum -shr 16) -ne 0) {
                        $sum = ($sum -band 0xffff) + ($sum -shr 16)
                    }
                    $computedCs = (-bnot [uint32]$sum) -band 0xffff

                    Write-Host ("       version/IHL : {0}/{1} (header {2} bytes)" -f $version, ($packetData[14] -band 0x0f), $ihl)
                    Write-Host ("       total len   : {0}" -f $totalLen)
                    Write-Host ("       id          : 0x{0:x4} ({0})" -f $id)
                    Write-Host ("       flags/frag  : 0x{0:x4}" -f $flagsFrag)
                    Write-Host ("       TTL         : {0}" -f $ttl)
                    Write-Host ("       protocol    : {0} (1=ICMP, 6=TCP, 17=UDP)" -f $proto)
                    Write-Host ("       checksum    : 0x{0:x4} (computed 0x{1:x4} {2})" -f $checksum, $computedCs, $(if ($checksum -eq $computedCs) {'[OK]'} else {'[BAD]'}))
                    Write-Host ("       src IP      : {0}" -f $srcIp)
                    Write-Host ("       dst IP      : {0}" -f $dstIp)

                    if ($proto -eq 6 -and ($dataStart + 14 + $ihl + 20) -le $bytes.Length) {
                        # TCP header starts at 14 + ihl
                        $tcpOff = 14 + $ihl
                        $srcPort    = Read-UInt16BE $packetData $tcpOff
                        $dstPort    = Read-UInt16BE $packetData ($tcpOff + 2)
                        $seqNum     = Read-UInt32BE $packetData ($tcpOff + 4)
                        $ackNum     = Read-UInt32BE $packetData ($tcpOff + 8)
                        $dataOff    = (($packetData[$tcpOff + 12] -shr 4) -band 0x0f) * 4
                        $flagsByte  = $packetData[$tcpOff + 13]
                        $window     = Read-UInt16BE $packetData ($tcpOff + 14)
                        $tcpChecksum= Read-UInt16BE $packetData ($tcpOff + 16)
                        $urgentPtr  = Read-UInt16BE $packetData ($tcpOff + 18)

                        $flagStr = ""
                        if ($flagsByte -band 0x01) { $flagStr += "FIN " }
                        if ($flagsByte -band 0x02) { $flagStr += "SYN " }
                        if ($flagsByte -band 0x04) { $flagStr += "RST " }
                        if ($flagsByte -band 0x08) { $flagStr += "PSH " }
                        if ($flagsByte -band 0x10) { $flagStr += "ACK " }
                        if ($flagsByte -band 0x20) { $flagStr += "URG " }

                        # TCP checksum verification using the IPv4 pseudo-header.
                        $pseudo = New-Object byte[] 12
                        [Array]::Copy($packetData, 26, $pseudo, 0, 8)  # src+dst IP
                        $pseudo[8]  = 0
                        $pseudo[9]  = $proto
                        $tcpLen     = [Math]::Max(0, [int]$totalLen - $ihl)
                        $pseudo[10] = ($tcpLen -shr 8) -band 0xff
                        $pseudo[11] = $tcpLen -band 0xff

                        $tcpSeg = New-Object byte[] $tcpLen
                        if ($tcpLen -gt 0) { [Array]::Copy($packetData, $tcpOff, $tcpSeg, 0, $tcpLen) }
                        # zero the checksum field
                        if ($tcpLen -ge 18) {
                            $tcpSeg[16] = 0; $tcpSeg[17] = 0
                        }
                        $buf = New-Object byte[] ($pseudo.Length + $tcpSeg.Length)
                        [Array]::Copy($pseudo, 0, $buf, 0, $pseudo.Length)
                        [Array]::Copy($tcpSeg, 0, $buf, $pseudo.Length, $tcpSeg.Length)
                        $tsum = 0
                        for ($i = 0; $i -lt $buf.Length; $i += 2) {
                            if ($i + 1 -lt $buf.Length) {
                                $tsum += ([uint32]$buf[$i] -shl 8) -bor [uint32]$buf[$i+1]
                            } else {
                                $tsum += ([uint32]$buf[$i] -shl 8)
                            }
                        }
                        while (($tsum -shr 16) -ne 0) {
                            $tsum = ($tsum -band 0xffff) + ($tsum -shr 16)
                        }
                        $tcpComputedCs = (-bnot [uint32]$tsum) -band 0xffff

                        Write-Host ("       --- TCP ---")
                        Write-Host ("          src port    : {0}" -f $srcPort)
                        Write-Host ("          dst port    : {0}" -f $dstPort)
                        Write-Host ("          seq number  : {0} (0x{0:x8})" -f $seqNum)
                        Write-Host ("          ack number  : {0} (0x{0:x8})" -f $ackNum)
                        Write-Host ("          data offset : {0} bytes (header len)" -f $dataOff)
                        Write-Host ("          flags       : 0x{0:x2} ({1})" -f $flagsByte, $flagStr.Trim())
                        Write-Host ("          window       : {0}" -f $window)
                        Write-Host ("          checksum     : 0x{0:x4} (computed 0x{1:x4} {2})" -f $tcpChecksum, $tcpComputedCs, $(if ($tcpChecksum -eq $tcpComputedCs) {'[OK]'} else {'[BAD]'}))
                        Write-Host ("          urgent ptr   : {0}" -f $urgentPtr)

                        # Dump TCP options if any
                        if ($dataOff -gt 20 -and $dataOff -le $tcpLen) {
                            $optsLen = $dataOff - 20
                            $opts = New-Object byte[] $optsLen
                            [Array]::Copy($packetData, $tcpOff + 20, $opts, 0, $optsLen)
                            $optsHex = ($opts | ForEach-Object { $_.ToString("x2") }) -join " "
                            Write-Host ("          options      : {0}" -f $optsHex)
                        }
                    } elseif ($proto -eq 6) {
                        Write-Host ("       (TCP header truncated)")
                    }
                } else {
                    Write-Host ("       (IP packet truncated, < 34 bytes)")
                }
            }
            0x86DD {
                Write-Host ("    -> IPv6 (not decoded)")
            }
            0x8035 {
                Write-Host ("    -> RARP (not decoded)")
            }
            default {
                if (($ethType -lt 0x0600) -and ($ethType -ge 0)) {
                    Write-Host ("    -> 802.3 length frame (length={0}, not decoded)" -f $ethType)
                } else {
                    Write-Host ("    -> ethertype 0x{0:x4} (not decoded)" -f $ethType)
                }
            }
        }
    }

    Write-Host ""
    $offset = $dataStart + $inclLen
}

Write-Host ("==== End of dump ({0} packets) ====" -f $packetNum)
