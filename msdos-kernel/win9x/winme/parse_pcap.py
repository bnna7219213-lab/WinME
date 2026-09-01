import struct, sys
pcap = sys.argv[1] if len(sys.argv) > 1 else 'c:/Users/bnna7/workspace/msdos-kernel/win9x/winme/_net.pcap'
with open(pcap, 'rb') as f:
    data = f.read()
print('pcap len', len(data))
magic, ver1, ver2, tz, sig, snap, link = struct.unpack('<IHHiIII', data[:24])
print('magic=%08x linktype=%d' % (magic, link))
off = 24
i = 0
while off < len(data):
    ts_sec, ts_usec, inc, orig = struct.unpack('<IIII', data[off:off+16])
    off += 16
    pkt = data[off:off+inc]
    off += inc
    i += 1
    print('--- packet %d: %d bytes ---' % (i, inc))
    dst = pkt[0:6]; src = pkt[6:12]; etype = pkt[12:14]
    print('  eth dst=%s src=%s type=0x%02x%02x' % (
        ':'.join('%02x' % b for b in dst),
        ':'.join('%02x' % b for b in src), etype[0], etype[1]))
    if etype[0] == 0x08 and etype[1] == 0x00:
        ip = pkt[14:]
        ihl = (ip[0] & 0x0f) * 4
        proto = ip[9]
        sip = '.'.join(str(b) for b in ip[12:16])
        dip = '.'.join(str(b) for b in ip[16:20])
        ttl = ip[8]
        tos = ip[1]
        total_len = struct.unpack('>H', ip[2:4])[0]
        ident = struct.unpack('>H', ip[4:6])[0]
        frag = struct.unpack('>H', ip[6:8])[0]
        chksum = struct.unpack('>H', ip[10:12])[0]
        print('  ip src=%s dst=%s proto=%d ihl=%d ttl=%d tos=0x%02x totlen=%d id=%d frag=0x%04x cksum=0x%04x' % (
            sip, dip, proto, ihl, ttl, tos, total_len, ident, frag, chksum))
        # IP checksum verify
        s = 0
        for j in range(0, ihl, 2):
            s += struct.unpack('>H', ip[j:j+2])[0]
        while s >> 16:
            s = (s & 0xffff) + (s >> 16)
        print('  ip cksum verify: 0x%04x (0xffff=OK)' % (~s & 0xffff))
        if proto == 6:
            tcp = ip[ihl:]
            sport, dport, seq, ack, off_flags = struct.unpack('>HHIIH', tcp[:14])
            doff = (off_flags >> 12) * 4
            flags = tcp[13]
            tcp_cksum = struct.unpack('>H', tcp[16:18])[0]
            print('  tcp sport=%d dport=%d seq=%d ack=%d doff=%d flags=0x%02x (SYN=%d ACK=%d) cksum=0x%04x' % (
                sport, dport, seq, ack, doff, flags, (flags >> 1) & 1, (flags >> 4) & 1, tcp_cksum))
            win = struct.unpack('>H', tcp[14:16])[0]
            urg = struct.unpack('>H', tcp[18:20])[0]
            print('  tcp window=%d urgptr=%d' % (win, urg))
