import struct, sys
pcap = 'c:/Users/bnna7/workspace/msdos-kernel/win9x/winme/_net.pcap'
with open(pcap, 'rb') as f:
    data = f.read()
off = 24
i = 0
while off < len(data):
    ts_sec, ts_usec, inc, orig = struct.unpack('<IIII', data[off:off+16])
    off += 16
    pkt = data[off:off+inc]
    off += inc
    i += 1
    print('=== packet %d: %d bytes ===' % (i, inc))
    print('Full hex:', pkt.hex())
    if inc < 14:
        continue
    print('Eth dst MAC:', ':'.join('%02x' % b for b in pkt[0:6]))
    print('Eth src MAC:', ':'.join('%02x' % b for b in pkt[6:12]))
    print('Eth type: 0x%04x' % struct.unpack('>H', pkt[12:14])[0])
    if pkt[12] == 0x08 and pkt[13] == 0x00:
        ip = pkt[14:]
        print('IP ver/ihl: 0x%02x' % ip[0])
        print('IP total len: %d' % struct.unpack('>H', ip[2:4])[0])
        print('IP protocol: %d' % ip[9])
        print('IP src: %d.%d.%d.%d' % tuple(ip[12:16]))
        print('IP dst: %d.%d.%d.%d' % tuple(ip[16:20]))
        if ip[9] == 6 and len(ip) >= 40:
            tcp = ip[20:]
            print('TCP src port: %d' % struct.unpack('>H', tcp[0:2])[0])
            print('TCP dst port: %d' % struct.unpack('>H', tcp[2:4])[0])
            print('TCP seq: 0x%08x' % struct.unpack('>I', tcp[4:8])[0])
            print('TCP flags: 0x%02x (SYN=%d ACK=%d)' % (tcp[13], bool(tcp[13]&2), bool(tcp[13]&0x10)))
    print()
