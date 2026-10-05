#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Verify outer UDP and inner TCP checksums of VXLAN frames in a pcap.

Counts are on the wire as seen by the receiver capture, independent of RX offload.
"""
import struct
import sys
from collections import Counter


def csum(data):
    if len(data) % 2:
        data += b"\0"
    s = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return s


def l4_ok(ip, proto, l4):
    pseudo = ip[12:20] + struct.pack("!BBH", 0, proto, len(l4))
    return csum(pseudo + l4) == 0xFFFF


def frames(path):
    with open(path, "rb") as f:
        magic = f.read(24)[:4]
        endian = "<" if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1") else ">"
        while hdr := f.read(16):
            _, _, incl, _ = struct.unpack(endian + "IIII", hdr)
            yield f.read(incl)


def ipv4(frame, off):
    """Return (ip header, payload, proto) for an IPv4 packet behind Ethernet[/VLAN]."""
    etype = struct.unpack("!H", frame[off + 12:off + 14])[0]
    off += 14
    while etype == 0x8100:
        etype = struct.unpack("!H", frame[off + 2:off + 4])[0]
        off += 4
    if etype != 0x0800:
        return None
    ihl = (frame[off] & 0xF) * 4
    total = struct.unpack("!H", frame[off + 2:off + 4])[0]
    return frame[off:off + ihl], frame[off + ihl:off + total], frame[off + 9]


def main():
    # --src A.B.C.D: only frames from that outer source (e.g. the sender 198.51.100.1);
    # frames the capturing host sends itself are seen before TX checksum offload.
    args = sys.argv[1:]
    src = None
    if args[:1] == ["--src"]:
        src, args = bytes(int(x) for x in args[1].split(".")), args[2:]
    for path in args:
        c = Counter()
        sizes = Counter()
        for frame in frames(path):
            outer = ipv4(frame, 0)
            if not outer or outer[2] != 17:
                continue
            oip, udp, _ = outer
            if src and oip[12:16] != src:
                continue
            if struct.unpack("!H", udp[2:4])[0] != 4789:
                continue
            c["vxlan"] += 1
            if udp[6:8] == b"\0\0":
                c["outer_udp_zero"] += 1
            elif l4_ok(oip, 17, udp):
                c["outer_udp_ok"] += 1
            else:
                c["outer_udp_bad"] += 1
                sizes[len(udp)] += 1
            inner = ipv4(udp[16:], 0)
            if inner and inner[2] == 6:
                c["inner_tcp_ok" if l4_ok(inner[0], 6, inner[1]) else "inner_tcp_bad"] += 1
        print(path)
        for k in ["vxlan", "outer_udp_ok", "outer_udp_bad", "outer_udp_zero", "inner_tcp_ok", "inner_tcp_bad"]:
            print(f"  {k:16} {c[k]}")
        if sizes:
            print("  bad outer UDP lengths:", ", ".join(f"{k}x{v}" for k, v in sizes.most_common(5)))


if __name__ == "__main__":
    main()
