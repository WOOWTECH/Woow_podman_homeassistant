#!/usr/bin/env python3
"""tests/lib/mdns_query.py: one-shot mDNS query (stdlib only).

    tests/lib/mdns_query.py _hap._tcp.local [--timeout 3]

Prints "<port> <instance>" for every SRV record received for the service type. The query goes
out from an ephemeral port, so responders such as python-zeroconf in Home Assistant answer it
as a legacy unicast query (RFC 6762 section 6.7), straight to this socket. Exit 0 when at least
one SRV record arrived, 1 otherwise. Used by tests/smoke.sh to see the HomeKit bridge advertised.
"""
import argparse
import random
import socket
import struct
import sys
import time

MDNS = ("224.0.0.251", 5353)
T_PTR, T_SRV = 12, 33


def encode_name(name):
    out = b""
    for label in name.rstrip(".").split("."):
        raw = label.encode()
        out += bytes([len(raw)]) + raw
    return out + b"\x00"


def read_name(msg, off, depth=0):
    labels = []
    while True:
        if depth > 16 or off >= len(msg):
            raise ValueError("bad name")
        n = msg[off]
        if n & 0xC0 == 0xC0:
            ptr = struct.unpack_from("!H", msg, off)[0] & 0x3FFF
            rest, _ = read_name(msg, ptr, depth + 1)
            labels.append(rest)
            return ".".join(x for x in labels if x), off + 2
        off += 1
        if n == 0:
            return ".".join(labels), off
        labels.append(msg[off:off + n].decode("utf-8", "replace"))
        off += n


def srv_records(msg):
    _, _, qd, an, ns, ar = struct.unpack_from("!HHHHHH", msg, 0)
    off = 12
    for _ in range(qd):
        _, off = read_name(msg, off)
        off += 4
    out = []
    for _ in range(an + ns + ar):
        name, off = read_name(msg, off)
        rtype, _, _, rdlen = struct.unpack_from("!HHIH", msg, off)
        off += 10
        if rtype == T_SRV:
            port = struct.unpack_from("!HHH", msg, off)[2]
            out.append((name, port))
        off += rdlen
    return out


def main():
    ap = argparse.ArgumentParser(description="one-shot mDNS SRV lookup")
    ap.add_argument("service", help="service type, e.g. _hap._tcp.local")
    ap.add_argument("--timeout", type=float, default=3.0)
    a = ap.parse_args()
    svc = a.service.rstrip(".").lower()
    query = struct.pack("!HHHHHH", random.randint(1, 0xFFFF), 0, 1, 0, 0, 0) + encode_name(svc) + struct.pack("!HH", T_PTR, 1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
    sock.bind(("0.0.0.0", 0))
    sock.settimeout(0.3)
    found = {}
    start = time.monotonic()
    sent = 0
    while time.monotonic() - start < a.timeout:
        if sent < 2 and time.monotonic() - start >= sent * (a.timeout / 2):
            try:
                sock.sendto(query, MDNS)
            except OSError as e:
                print(f"mdns_query: cannot send: {e}", file=sys.stderr)
                return 1
            sent += 1
        try:
            data, _ = sock.recvfrom(9000)
        except socket.timeout:
            continue
        try:
            for name, port in srv_records(data):
                if name.lower().endswith("." + svc):
                    found[name] = port
        except (ValueError, struct.error, IndexError):
            continue
    for name, port in sorted(found.items()):
        print(f"{port} {name}")
    return 0 if found else 1


if __name__ == "__main__":
    sys.exit(main())
