# Author: sunfang1cn@gmail.com
"""Query and observe RAOP multicast DNS packets on the device LAN."""

from __future__ import annotations

import argparse
import socket
import struct
import time


GROUP = "224.0.0.251"
PORT = 5353


def dns_name(value: str) -> bytes:
    return b"".join(bytes((len(label),)) + label.encode("ascii") for label in value.split(".")) + b"\0"


def local_ip_for(device: str) -> str:
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect((device, 80))
        return str(probe.getsockname()[0])
    finally:
        probe.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("device")
    parser.add_argument("--seconds", type=float, default=35.0)
    args = parser.parse_args()

    local_ip = local_ip_for(args.device)
    query = struct.pack("!HHHHHH", 0, 0, 1, 0, 0, 0) + dns_name("_raop._tcp.local") + struct.pack("!HH", 12, 1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", PORT))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, socket.inet_aton(GROUP) + socket.inet_aton(local_ip))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(local_ip))
    sock.settimeout(0.5)
    sock.sendto(query, (GROUP, PORT))

    print(f"local={local_ip}:{PORT} query=_raop._tcp.local duration={args.seconds}s", flush=True)
    deadline = time.monotonic() + args.seconds
    matches = 0
    while time.monotonic() < deadline:
        try:
            packet, source = sock.recvfrom(65535)
        except socket.timeout:
            continue
        if b"_raop" not in packet.lower():
            continue
        matches += 1
        flags = struct.unpack_from("!H", packet, 2)[0] if len(packet) >= 4 else 0
        print(f"raop source={source[0]}:{source[1]} bytes={len(packet)} flags=0x{flags:04x}", flush=True)
    print(f"matches={matches}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
